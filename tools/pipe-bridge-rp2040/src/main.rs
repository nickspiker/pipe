//! pipe-bridge-rp2040 — USB-CDC ↔ PIPE wire bridge for RP2040-Zero
//!
//! Core split:
//!   Core 0: USB-CDC + VSF cmd/resp dispatch + heartbeat LED. The LED is a USB-activity indicator (TX/RX hold, geiger LFSR otherwise), so it cohabits with USB.
//!   Core 1: PIPE wire. Owns GP0. Phase 1 = idle. Phase 2 = PIO mirror-XOR codec + DPLL clock recovery + cross-core ring buffers to relay wire bytes via USB.
//!
//! Phase 1 (current): VSF Tier 1 protocol over USB-CDC works end-to-end (ping/info/uptime/random/bootsel/reset/flash). No wire traffic yet.
//!
//! Phase 2 (next): PIO program from rtl/codec.v reference. PIO runs at sys_clk (125 MHz default) so the ~20 µs slot rate has ~2500 PIO cycles per slot — plenty of headroom for DPLL phase nudging + crypto framing.
//!
//! Wiring on the RP2040-Zero:
//!   GP0  → 470 Ω series resistor → PIPE wire pin (to ECP5 pipe_pad)
//!   GND  → shared ground reference with the ECP5 board (CRITICAL)
//!   USB-C → host computer
//!
//! Flash workflow:
//!   1. Hold BOOT button on the RP2040-Zero
//!   2. Plug USB-C into host
//!   3. Board enumerates as RPI-RP2 mass-storage device
//!   4. From this directory: `cargo run --release`
//!   5. elf2uf2-rs auto-detects the mount and copies the UF2; board reboots
//!
//! After flashing, the board appears as /dev/ttyACM0 (Linux) or COMx (Windows).
//! Open it in a serial terminal (115200 8N1 — though baud rate is ignored over CDC) and type characters to drive GP0.

#![no_std]
#![no_main]

extern crate alloc;

use alloc::string::ToString;
use alloc::vec;
use core::mem::MaybeUninit;
use core::sync::atomic::{AtomicU8, Ordering};

use embassy_executor::{Executor, Spawner};
use embassy_rp::bind_interrupts;
use embassy_rp::flash::{Blocking, Flash};
use embassy_rp::gpio::{Drive, Flex, Level, Output, Pull};
use embassy_rp::multicore::{Stack, spawn_core1};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use embassy_time::Instant;
use embassy_usb::class::cdc_acm::{CdcAcmClass, State};
use embassy_usb::driver::EndpointError;
use embassy_usb::{Builder, Config};
use embedded_alloc::Heap;
use portable_atomic::{AtomicU64, Ordering as PaOrdering};
use static_cell::StaticCell;
use vsf::file_format::VsfHeader;
use vsf::schema::{pipe_message_schema, SectionBuilder};
use vsf::types::{EtType, VsfType, OSCILLATIONS_PER_SECOND};
use vsf::verification::is_original;
use vsf::vsf_builder::VsfBuilder;
use panic_halt as _;

// ---------------------------------------------------------------------------
// Global heap — 32 KB linked-list-first-fit, initialised at boot.
//
// vsf::vsf_builder::VsfBuilder.build() returns Vec<u8>, and VsfHeader::decode
// allocates Vec<HeaderField>; the unified vsf crate runs no_std + alloc. Bridge
// packets are <1 KB each and at most one is in flight at a time, so 32 KB leaves
// ~30× headroom. Static .bss — no runtime growth, no fragmentation risk.
// ---------------------------------------------------------------------------

const HEAP_SIZE: usize = 32 * 1024;
static mut HEAP_MEM: [MaybeUninit<u8>; HEAP_SIZE] = [MaybeUninit::uninit(); HEAP_SIZE];

#[global_allocator]
static HEAP: Heap = Heap::empty();

/// RP2040-Zero flash size (Boya BY25Q16ES = 2 MiB).
const FLASH_SIZE: usize = 2 * 1024 * 1024;

/// BLAKE3 domain string for the device public ID. Bumping the version invalidates
/// all prior IDs, so treat it as part of the on-the-wire identity contract.
const DEVICE_ID_DOMAIN: &str = "ferros bridge rp2040-zero device id v1";

/// Firmware semantic version. Bump on every flash; `info` reports it.
/// v5: protocol break — every wire packet is now a complete VSF document (magic + header + hp) parseable by `vsfinfo`.
const FW_VERSION: u64 = 5;

/// Action requested by `dispatch()` that must run *after* the response is on the wire.
/// Variants stay unit-sized so `dispatch`'s `(usize, PostAction)` return tuple fits in
/// registers. Earlier we carried `LoadDev { size, hash: [u8;32], id }` inline (~48 bytes)
/// — that ballooned the return to ~56 bytes, forced stack-return on thumbv6m, and the
/// rebuild silently broke at boot (no USB enumeration). Lesson: keep variants small.
#[derive(Clone, Copy)]
enum PostAction {
    None,
    BootSel,
    Reset,
    /// Hot-reload a dev image into SRAM. handle_frames reads size/id/hash from the
    /// LOAD_DEV_* statics, streams `size` raw bytes into SRAM at DEV_IMAGE_DEST,
    /// then BLAKE3-hashes the SRAM range and verifies before jumping.
    LoadDev,
}

/// Max dev-image size that fits in the SRAM region reserved for it (0x20000000..0x2002C000).
/// Matches the `FLASH` LENGTH in `memory-ram.x` (176 KiB = 180224). Anything larger would
/// either trample manager RAM during the stream or overflow the dev linker layout.
const DEV_IMAGE_MAX_BYTES: u32 = 176 * 1024;
/// SRAM destination for the dev image. Must match the `FLASH` ORIGIN in `memory-ram.x`.
const DEV_IMAGE_DEST: u32 = 0x2000_0000;

/// Parameters for the next `load_dev` action — dispatch writes, handle_frames reads.
/// Single-threaded on core 0 so atomic ordering is just for compiler sequencing.
static LOAD_DEV_SIZE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
static LOAD_DEV_ID: AtomicU64 = AtomicU64::new(0);
static mut LOAD_DEV_HASH: [u8; 32] = [0u8; 32];

// Shared LED-state flag between core 0 (USB task) and core 1 (geiger task).
//   STATE_IDLE → geiger runs normally (no USB activity right now)
//   STATE_TX   → core 1 forces LED ON  (bridge transmitting USB response to host)
//   STATE_RX   → core 1 forces LED OFF (bridge receiving USB cmd from host)
const STATE_IDLE: u8 = 0;
const STATE_TX: u8 = 1;
const STATE_RX: u8 = 2;
static USB_STATE: AtomicU8 = AtomicU8::new(STATE_IDLE);

// Cross-core wake-up: core 0 signals on every USB_STATE change so core 1 can
// drop out of `.await` immediately and re-read the atomic. Cheaper than a
// timer-based poll and never starves on changes during LFSR bursts (the atomic
// load inside the LFSR loop catches state changes too).
static WAKE_SIGNAL: Signal<CriticalSectionRawMutex, ()> = Signal::new();


// ---------------------------------------------------------------------------
// Fast wire-trace buffer — tight bit-banged GPIO read at native CPU rate
// (~8-12 MS/s on M0+ @ 125 MHz). Up to TRACE_MAX_SAMPLES bits packed LSB-first
// per byte, byte 0 = earliest samples. Triggered cross-core via TRACE_REQUEST:
//   core 0 (dispatch): store sample count → TRACE_REQUEST
//   core 1 (wire task): sees request, runs fast_capture, posts to TRACE_RESPONSE
//   core 0: polls TRACE_RESPONSE, reads TRACE_FAST_BUF, builds VSF response
//
// TRACE_FAST_BUF is `static mut` rather than `[AtomicU8; N]` because AtomicU8
// fetch_or/fetch_and on Cortex-M0+ uses a critical_section polyfill (no native
// LDREX/STREX). At 8192 iterations that polyfill cost dominates capture time
// and ruins the constant-period sampling. The Release store on TRACE_RESPONSE
// pairs with the Acquire load on core 0 to publish all buffer writes safely.
// ---------------------------------------------------------------------------
const TRACE_MAX_SAMPLES: usize = 8192;
const TRACE_MAX_BYTES: usize = TRACE_MAX_SAMPLES / 8;
static mut TRACE_FAST_BUF: [u8; TRACE_MAX_BYTES] = [0u8; TRACE_MAX_BYTES];

/// Cross-core request: number of samples to capture. 0 = idle, >0 = arm.
/// Core 1 zeroes it after capture completes.
static TRACE_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Cross-core response: number of samples actually captured (set by core 1
/// after fast_capture returns; Release ordering publishes TRACE_FAST_BUF too).
static TRACE_RESPONSE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Measured elapsed time of the last capture, in microseconds. Host divides
/// by sample count to compute actual sample rate (so we don't have to trust
/// the loop's cycle count — the timer tells us what really happened).
static TRACE_ELAPSED_US: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Desired sample period in nanoseconds. 0 = native loop rate (no delay
/// between samples). Set by core 0 before storing TRACE_REQUEST.
static TRACE_PERIOD_NS: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

// ---------------------------------------------------------------------------
// Wire stats — streaming statistics at native sample rate, no buffer. fast_capture maxes out at TRACE_MAX_SAMPLES bits because of BRAM; stats doesn't store samples, so it can run for as long as we want and compute duty cycle / freq / pulse-width distribution over a much larger window.
//
// Per-state accounting:
//   - count of completed runs (toggle ended a HIGH or LOW span)
//   - min, max run length (in samples)
//   - sum, sumsq of completed run lengths → host derives mean + stddev
//
// Plus final_state + final_run for the unclosed trailing run at the end of the window; host folds it into total-sample-count duty math but excludes it from run-length stats (partial-run bias).
//
// Inner loop on M0+ (non-toggle path): LDR + AND + CMP + BEQ + ADD ≈ 5-6 cycles. The toggle path is heavier (one u32×u32 → u64 mul, min/max, two u64 adds with carry) but only runs on actual edges, not on every sample.
// ---------------------------------------------------------------------------
/// log2 histogram bin count per state. Bin i covers run lengths in [2^i, 2^(i+1)). 16 bins covers [1, 65536) samples, which at the ~9 MS/s stats sample rate spans [110 ns, 7 ms] — every realistic pulse width from a single-sample glitch to a multi-slot stretch.
const STATS_HIST_BINS: usize = 16;

#[repr(C)]
#[derive(Clone, Copy)]
struct WireStats {
    elapsed_us: u32,
    samples_taken: u32,
    final_state: u32,
    final_run: u32,
    hi_count: u32,
    hi_min: u32,
    hi_max: u32,
    hi_sum: u64,
    hi_sumsq: u64,
    lo_count: u32,
    lo_min: u32,
    lo_max: u32,
    lo_sum: u64,
    lo_sumsq: u64,
    hi_hist: [u32; STATS_HIST_BINS],
    lo_hist: [u32; STATS_HIST_BINS],
}

static mut STATS_RESULT: WireStats = WireStats {
    elapsed_us: 0,
    samples_taken: 0,
    final_state: 0,
    final_run: 0,
    hi_count: 0,
    hi_min: 0,
    hi_max: 0,
    hi_sum: 0,
    hi_sumsq: 0,
    lo_count: 0,
    lo_min: 0,
    lo_max: 0,
    lo_sum: 0,
    lo_sumsq: 0,
    hi_hist: [0; STATS_HIST_BINS],
    lo_hist: [0; STATS_HIST_BINS],
};

/// Number of samples to collect. 0 = idle, >0 = arm fast_stats.
static STATS_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Set by core 1 to samples_taken after fast_stats completes (Release publishes STATS_RESULT writes to core 0's Acquire load).
static STATS_RESPONSE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

/// Cap stats sample budget to keep wall time bounded. At ~24 MS/s native rate, 2^22 ≈ 175 ms — covers ~350 full periods of a 2 kHz signal so stats are well-converged, and stays under typical USB host timeouts (we're inside interrupt::free for the duration, so USB IRQs starve).
const STATS_MAX_SAMPLES: u32 = 1 << 22;

// ---------------------------------------------------------------------------
// Wire sync — same-polarity acquisition + per-polarity bang-bang drift tracker.
//
// ACQUISITION: 128 rise-to-rise + 128 fall-to-fall inter-edge intervals. On any periodic wire, each same-polarity interval = 2 × slot, so sum = 4 × N × slot. With N = 128, slot = sum >> 9. Single bitshift, no divide. Works on asymmetric duty cycles because same-polarity intervals are 2-slot apart regardless of HIGH/LOW asymmetry. Seeds interval_fp = slot << SYNC_FRAC_BITS.
//
// TRACKING: per-polarity bang-bang. Every rising edge measures iter_since_rise, mod-folds against current slot (interval_fp >> 11), computes phase_err = iter_since_rise − n × slot, and slews interval_fp by ±1 fp unit based on sign (no deadband, no rejection). Every falling edge does the same with iter_since_fall. Both polarities adjust the SAME interval_fp — slot rate is one quantity, and any drift of the ring osc gets nudged into interval_fp continuously.
//
// At FRAC_BITS = 11, ±1 fp unit per edge = slot/2048 per edge. Each integer-iter shift of slot needs 2048 same-sign edges, so the loop is heavily filtered: noise/jitter cancels, slow drift accumulates. That IS the drift tracking.
//
// DIAGNOSTIC: per-polarity phase_err histogram (signed, 1-iter bins, ±128 range) shows where edges land relative to the current slot grid. RC offset measurement uses the OTHER polarity's counter at acceptance time.
//
// LOOP DISCIPLINE: inner loop body must stay constant-time per iter; lives inside interrupt::free.
// ---------------------------------------------------------------------------
/// Same-polarity intervals per polarity during acquisition. Total = 2 × N intervals each scaled by 2 × slot; sum = 4N × slot. slot = sum >> SHIFT where SHIFT = log2(4N) = log2(1024) = 10.
const SYNC_ACQ_PER_POLARITY: u32 = 256;
const SYNC_ACQ_SHIFT: u32 = 10;
/// Default fractional bits in interval_fp if the host doesn't override. ±1 slew per edge = slot/2^FRAC adjustment.
///
/// Picked 13 (slew = slot/8192) from the empirical sweep on the current FPGA wire. Aggressive values (FRAC ≤ 9) converged interval_fp to the centroid of the wire's multimodal edge clusters — which drove mean phase_err to zero but smeared the per-polarity histogram, making the wire's actual cluster structure unreadable. Slow values (FRAC ≥ 13) kept the lock anchored near the acquisition seed, the histogram resolved the wire's discrete clusters cleanly, and slow drift (~hundreds of ppm/sec from chip self-heating) still got tracked correctly over multi-second runs. 13 balances drift-tracking responsiveness against histogram clarity; bumping to 14-15 makes the lock even quieter but slower to follow real drift.
const SYNC_FRAC_BITS_DEFAULT: u32 = 16;
/// Bounds on runtime frac_bits. Upper bound keeps interval_fp from overflowing u32 for typical slot values (~1500 iter × 2^19 ≈ 8×10^8, safe). Lower bound keeps the slew meaningful (FRAC=1 = ±slot/2 per edge = chaos).
const SYNC_FRAC_BITS_MIN: u32 = 2;
const SYNC_FRAC_BITS_MAX: u32 = 19;
/// Hard cap on inner-loop iterations to bound wall time even if the wire is dead. 2^28 ≈ 45-90 s depending on iter rate.
const SYNC_MAX_ITERATIONS: u32 = 1 << 28;
/// Per-polarity histogram bin count for signed phase_err. Centered on zero, covers ±SYNC_HIST_HALF_RANGE cycles at 1-cycle resolution. Edges beyond go to per-polarity overflow counters.
const SYNC_HIST_BINS: usize = 256;
const SYNC_HIST_HALF_RANGE: i32 = (SYNC_HIST_BINS as i32) / 2;

/// EMA filter rate for the P-based lock detector. The running average of phase_err
/// is updated each edge as `ema += (phase_err - ema) >> SYNC_LOCK_EMA_SHIFT`. Alpha
/// = 2^-shift, so shift=10 gives alpha=1/1024 — settles in ~1024 edges (~3 ms at
/// 348 kHz slot rate), EMA std ≈ σ/√2047. With observed per-edge phase_err std of
/// ~70 cyc (a few % outliers around ±128 cyc) the EMA jitters ±1.5 cyc — comfortably
/// inside the lock threshold even on this noisy wire.
const SYNC_LOCK_EMA_SHIFT: u32 = 10;
/// Threshold on |phase_err EMA| (in SYSTICK cycles) for declaring lock. With
/// shift=10 (α=1/1024) the EMA std is ≈1.5 cyc on this wire, so ±16 cyc gives ~10σ
/// margin — basically zero false negatives, but tight enough that genuine wire
/// drift (a slot shift of >16 cyc would mean the CDR is off by 5%+) clears lock.
const SYNC_LOCK_EMA_THRESHOLD_CYC: i32 = 16;
/// (Legacy) Per-edge in/out threshold and consecutive-hold counter, kept for the
/// histogram overflow accounting only. The active lock signal is now EMA-based
/// (SYNC_LOCK_EMA_*). Single-edge consec_in/out_lock counters are no longer used
/// to gate rise_locked/fall_locked.
const SYNC_LOCK_THRESHOLD_CYC: i32 = 8;
const SYNC_LOCK_HOLD_EDGES: u32 = 256;

/// Per-edge slew magnitude limit, in 1/N-of-seed units. Each slew (computed as
/// `phase_err << (frac_bits - p_shift)` in fp units) is clamped to
/// ±(seed_fp / SYNC_SLEW_CLAMP_DENOM) BEFORE being added to `interval_fp_*`.
/// With DENOM=1000, max correction per edge ≈ 0.1% of seed (~5.7 cyc on a
/// 5730-cyc seed). Real ring-osc drift is ~0.3 ppm/sec, so the clamp gives
/// ~5000× headroom for legitimate drift while structurally blocking a single
/// misclassified edge from yanking the loop to the ±30% sanity floor (where it
/// would stick and reinforce wrong-fixed-point lock via the slot-phase filter).
/// The destination ±30% window (seed-relative) remains in place as the ultimate
/// safety net — clamp + window = defense in depth.
const SYNC_SLEW_CLAMP_DENOM: u32 = 1000;

/// Slow EMA on `period_now` for silence-budget prediction. The fast P-controller
/// (interval_fp_period) tracks instantaneous drift edge-by-edge so it has ±1-2 cyc
/// steady-state ringing; the slow EMA averages per-sample noise out over ~1024
/// samples (≈ 47 ms at 22 kHz). Per-sample std ≈ 6 cyc on this wire, so SE-of-mean
/// over the slow EMA's effective window ≈ 6/√1024 ≈ 0.19 cyc ≈ 33 ppm — comfortably
/// under the 61 ppm silence budget. Use this value (not the live P-controller output)
/// as the "predicted period" at the start of any silence stretch.
const SYNC_PERIOD_EMA_SLOW_SHIFT: u32 = 10;

/// Period-tracker diagnostic histogram. 17 bins of width = seed/8 covering [0, 2×seed)
/// with bin 16 catching ≥2×seed as overflow. Bin 8 is the seed bin; bin 4 sits at
/// seed/2 (the "missed-edge" suspect — a dropped rising means the next rising's
/// own_cyc spans only one polarity instead of two, so period_now reads ≈ seed/2).
/// A clean lock shows mass piled in bin 8 with empty neighbours; missed edges show
/// a bimodal spike at bin 4 and bin 8; RC ringing shows a continuous low-side tail.
const PERIOD_HIST_BINS: usize = 17;

#[repr(C)]
#[derive(Clone, Copy)]
struct SyncResult {
    elapsed_us: u32,
    total_iterations: u32,
    /// 0 = locked, 1 = acquisition ran out of iterations, 2 = no edges ever seen.
    status: u32,
    /// FRAC_BITS used for this run (interval_fp has this many fractional bits below integer slot).
    frac_bits: u32,
    /// Proportional shift used for this run. slew_fp = (phase_err << FRAC_BITS) >> p_shift.
    p_shift: u32,
    /// 1 if the tracker held |phase_err| under SYNC_LOCK_THRESHOLD_CYC for at least
    /// SYNC_LOCK_HOLD_EDGES consecutive edges at any point during the run; 0 otherwise.
    /// The tracker keeps slewing either way — this is a state observation, not a control.
    locked: u32,
    /// Cumulative edge count at which lock was first declared. u32::MAX if never locked.
    /// Lets the caller see "how many edges did it take to get there" for tuning purposes.
    edges_to_lock: u32,
    /// Seed slot value computed at end of acquisition (raw cycle units). For the dual
    /// tracker this is `(acq_slot_rise + acq_slot_fall) / 2` — the historical
    /// single-slot view, kept so old host parsers still get a meaningful number.
    /// The polarity-specific seeds are below.
    acquisition_slot_iter: u32,
    /// Final interval_fp at end of run. For the dual tracker this is the AVERAGE of
    /// the two polarities' interval_fps — old host parsers see a sane slot. The
    /// polarity-specific finals are below.
    final_interval_fp: u32,
    /// Per-polarity seed slots and final interval_fps. Rising tracks HIGH width;
    /// falling tracks LOW width. They diverge under RC asymmetry — which is the whole
    /// reason we split: a single slot estimate averaged the two and bled mismatch
    /// into both polarities' phase_err.
    acquisition_slot_cyc_rise: u32,
    acquisition_slot_cyc_fall: u32,
    final_interval_fp_rise: u32,
    final_interval_fp_fall: u32,
    /// Iterations consumed by acquisition vs measurement.
    acquisition_iter_count: u32,
    measurement_iter_count: u32,
    /// Edge counts: each polarity's edges DURING acquisition (these are what built the slot estimate).
    acq_rising: u32,
    acq_falling: u32,
    /// Per-polarity measurement edge counts (after lock, every edge is binned).
    rising_total: u32,
    falling_total: u32,
    /// Edges with phase_err outside the histogram range [-HALF, +HALF), per polarity per sign.
    rising_neg_overflow: u32,
    rising_pos_overflow: u32,
    falling_neg_overflow: u32,
    falling_pos_overflow: u32,
    /// Signed sum of phase_err (iter units) across all measurement edges. With a perfect lock this is zero by construction; drift in the wire shows as nonzero.
    phase_sum: i64,
    /// RC offset measurement. At rising bin, fold iter_since_fall against slot → residual ≈ -Δrc. At falling bin, fold iter_since_rise → residual ≈ +Δrc. Means subtracted give 2*Δrc.
    fall_to_rise_offset_sum: i64,
    rise_to_fall_offset_sum: i64,
    /// Per-polarity signed phase_err histogram. Bin i = phase_err = i - SYNC_HIST_HALF_RANGE iter.
    rising_hist: [u16; SYNC_HIST_BINS],
    falling_hist: [u16; SYNC_HIST_BINS],
    /// RX bit decoder. Each tracked edge contributes n_slots bits (n_slots-1 zeros
    /// from quiet slots since the previous transition, then 1 for this transition's
    /// own slot). bits_buffer holds the most recent 64 bits — LSB = newest,
    /// MSB = oldest. bits_decoded is cumulative since acquisition completed.
    bits_buffer: u64,
    bits_decoded: u32,
    /// Mirror mode only: count of 32-bit TX words pushed into SM1 FIFO during
    /// this run. Each word = 32 host slots = 32 driven bits. 0 outside mirror mode.
    tx_words_consumed: u32,
    /// Final phase_err EMA values (per polarity, in SYSTICK cycles) at end of run.
    /// |EMA| <= SYNC_LOCK_EMA_THRESHOLD_CYC == locked. Surfaces the P-based lock
    /// detector's actual state so we can see if it's marginal (near threshold) or
    /// solidly inside/outside.
    phase_err_ema_rise: i32,
    phase_err_ema_fall: i32,
    /// PERIOD tracker (rise-to-rise = HIGH + LOW). The drift-stable frequency
    /// reference. SM1 clkdiv (mirror mode) = period / 2. Lock detector uses
    /// phase_err_ema_period (below). Per-polarity rise/fall are still computed for
    /// diagnostic / RC asymmetry reporting but aren't on the lock decision path.
    acquisition_slot_cyc_period: u32,
    final_interval_fp_period: u32,
    phase_err_ema_period: i32,
    /// Histogram of `period_now` (rising-to-rising interval, raw cyc) sampled BEFORE
    /// the cascade window check — so rejected glitches and missed-edge artefacts
    /// are visible. Bin width = seed/8. See PERIOD_HIST_BINS doc comment for the
    /// shape-interpretation guide.
    period_hist: [u32; PERIOD_HIST_BINS],
    /// Signed sum of every `period_now` value that fed `period_hist`, in cyc. Lets
    /// the host cross-check the histogram: `period_sum × 8 ns` should equal the
    /// total tracking-phase elapsed time. If it doesn't, the histogram is dropping
    /// samples or measuring the wrong thing.
    period_sum: i64,
    period_sample_count: u32,
    /// Min and max `period_now` value observed (cyc). Together with the sum and
    /// count this fully constrains the distribution shape — if min is near 0 but
    /// max ≫ seed, the wire is bimodal; if min ≈ max ≈ seed, lock is perfect.
    period_min: i32,
    period_max: i32,
    /// Slow EMA on `period_now` (α = 1 / 2^SYNC_PERIOD_EMA_SLOW_SHIFT), reported in
    /// fp form (frac_bits matches `frac_bits` field). This is the "predicted period
    /// for silence" — averages out per-edge noise to ~3-9 ppm SE while still tracking
    /// real frequency drift over its ~47 ms time constant. Seeded from
    /// acquisition_slot_cyc_period at end of acquisition so it's usable immediately.
    period_ema_slow_fp: u32,
    /// Phase 2c: bridge-side decode of FPGA's TX bits per Claim 12.
    /// `fpga_decoded_buffer` is a 32-bit rolling LSB-first accumulator — new bits go
    /// into the MSB, older bits shift right. With FPGA TX_PATTERN repeating every 32
    /// slots, the buffer asymptotically equals a rotation of the FPGA's TX_PATTERN
    /// once enough enclave slots have been observed. Computed per enclave slot as:
    ///   fpga_bit = OWN_IDLE_FPGA(=1) XOR last_bridge_driven_bit XOR observed_wire_state
    /// (the inverse of the Claim 12 encoding rule). Mirror mode only; 0 in wire_sync.
    fpga_decoded_buffer: u32,
    /// Total enclave slots from which a fpga_bit was decoded this run. With slot rate
    /// ~22 kHz × ~750 ms wall time, expect tens of thousands; pre-handshake bits are
    /// all 0 (FPGA in IDLE), post-handshake bits carry TX_PATTERN content.
    fpga_decoded_count: u32,
    /// Mirror-mode edge filter accounting (0 in wire_sync). Each post-acquisition edge
    /// hits exactly one of these three counters, so the sum equals the number of edges
    /// processed by the slot-phase filter. Use the ratios to diagnose decode quality
    /// regressions: a healthy lock has accepted >> rejected; high mid-slot count means
    /// CDR phase drifted away from FPGA slot boundaries; high wrong-polarity count
    /// means the bridge's predicted polarity (slot_phase + last_driven_bit + current
    /// _tx_bit) doesn't match the wire (= slot_phase parity is off, or tx_shift_reg
    /// drifted out of lockstep with SM1's OSR consumption).
    mirror_edges_accepted: u32,
    mirror_edges_rejected_mid_slot: u32,
    mirror_edges_rejected_wrong_polarity: u32,
    /// Claim-12-aware polarity prediction stats (ADVISORY; not yet wired into
    /// accept_for_cdr). Bridge models FPGA's TX bit position + data_mode state
    /// per Claim 12, predicts which slot boundaries SHOULD produce a transition
    /// and in which direction, and compares to the observed edge. If `claim12_match`
    /// dominates over the two mispredict counters, the model is correct and can
    /// replace the old slotted_oled-tuned polarity check in `wrong_polarity` above.
    /// Mispredict categories:
    ///   `_no_edge_observed`: model says no edge expected, but an edge was observed
    ///                        (= our model says wire would have stayed the same; reality
    ///                        produced an edge; either model wrong or a glitch)
    ///   `_wrong_polarity`:   model predicted an edge but in the opposite direction
    mirror_claim12_match: u32,
    mirror_claim12_mispredict_no_edge_observed: u32,
    mirror_claim12_mispredict_wrong_polarity: u32,
    /// Raw wire-state-per-slot-boundary log. Captures the first up-to-256 slot boundaries
    /// after `mirror_started`, one bit per slot, LSB-first within bytes. Slot 0 in the
    /// log = first boundary crossed (= entering host slot 1 from initial enclave slot 0).
    /// Subsequent indices: 1=enclave slot 2, 2=host slot 3, ...
    /// Diagnostic for decode-vs-expected wire pattern: compare on host against the
    /// computed Claim-12 wire signature for (FPGA TX_PATTERN × bridge TX_PATTERN) to
    /// distinguish handshake-fired-DATA-mode (=expected DEADBEEF-driven pattern) from
    /// handshake-never-fired-IDLE-mode (=different pattern), or from slot_phase tracker
    /// drift (=noise). Linear (not ring): captures FIRST 256 slots, not last 256.
    slot_wire_log: [u8; 32],
    /// Number of bits actually written into slot_wire_log (clamps at 256).
    slot_wire_log_count: u32,
    /// First-256 FPGA-decoded bits (linear, not ring). One bit per enclave slot:
    /// LSB of byte 0 = first decoded bit. The bit values are `fpga_bit` from the
    /// decode line `1 ^ last_driven_bit ^ wire_at_slot`. Host-side compares this
    /// against all 256 rotations of FPGA_TX_PATTERN_256 — a 256/256 match proves
    /// Claims 7 + 12 bit-clean for that capture window. Captures FIRST 256 enclave
    /// slots after `mirror_started`, same convention as slot_wire_log.
    fpga_decoded_log: [u8; 32],
    /// Number of bits actually written into fpga_decoded_log (clamps at 256).
    fpga_decoded_log_count: u32,
    /// Diagnostic: per-edge slots_crossed >SLOTS_CROSSED_MAX (= clamp fired). Each
    /// clamp event means slot_phase parity is wrong by however many slots were truncated.
    edges_slots_crossed_capped: u32,
    /// Diagnostic: largest single-edge slots_crossed value observed (pre-clamp). Lets
    /// us see whether the clamp threshold is reasonable for the actual workload.
    max_observed_slots_crossed: u32,
    /// Diagnostic: edges in the parity-ambiguous zone (own_cyc within ±slot_cyc/16 of
    /// (N + 0.5) * slot_cyc) where slot_phase update was skipped. Counting these tells
    /// us whether the filter is firing at all and how often parity-flip-risk events occur.
    edges_parity_ambiguous_skipped: u32,
    /// Raw inter-edge own_cyc_u values for the first up-to-256 edges after `mirror_started`
    /// (or after acquisition_done if not mirror mode). Each entry is the PIO measurement
    /// in sys_clk cycles (2 × (0xFFFFFFFF - X)) for that edge. Host plots histogram and
    /// computes own_cyc / slot_cyc ratios to verify the slot tracker's model of the wire.
    raw_own_cyc_log: [u32; 256],
    /// Number of entries actually written into raw_own_cyc_log (clamps at 256).
    raw_own_cyc_count: u32,
    /// Snapshot of slot_cyc estimate (interval_fp_period >> 1 >> frac_bits) at the moment
    /// raw_own_cyc capture started. Host divides log entries by this to get fractional slots.
    raw_own_cyc_slot_cyc: u32,
    /// Ring buffer of the LAST 256 decoded enclave-slot bits. Written at position
    /// `decode_count % 256` each slot; at end of run, the oldest bit in the ring is at
    /// position `decode_count % 256` (= the write position for the NEXT bit, which
    /// holds the bit from 256 slots ago). Host linearises into slot-index order using
    /// `fpga_decoded_count` to compute the wrap point. Demonstrates sustained bit-clean
    /// decode: if first-256 AND last-256 both match pattern rotations with rotation
    /// delta = (fpga_decoded_count - 256), there's NO drift over the run window.
    fpga_decoded_late_log: [u8; 32],
    /// LATE raw own_cyc ring buffer: most recent 256 edge intervals (post-acquisition,
    /// post-mirror-started, BEFORE deglitch). Written at position
    /// `total_edges_seen % 256`. Host linearises and computes histogram + stats to
    /// compare against the FIRST 256 raw own_cyc capture — drift / artifact diagnosis
    /// over the run window. If late edges have more sub-slot glitches than early ones,
    /// the wire physics is changing; if they look identical but decode is bad, the
    /// slot tracker math is the slip source.
    late_raw_own_cyc_log: [u32; 256],
    late_raw_own_cyc_count: u32,
}

static mut SYNC_RESULT: SyncResult = SyncResult {
    elapsed_us: 0,
    total_iterations: 0,
    status: 0,
    frac_bits: 0,
    p_shift: 0,
    locked: 0,
    edges_to_lock: u32::MAX,
    acquisition_slot_iter: 0,
    acquisition_slot_cyc_rise: 0,
    acquisition_slot_cyc_fall: 0,
    final_interval_fp_rise: 0,
    final_interval_fp_fall: 0,
    final_interval_fp: 0,
    acquisition_iter_count: 0,
    measurement_iter_count: 0,
    acq_rising: 0,
    acq_falling: 0,
    rising_total: 0,
    falling_total: 0,
    rising_neg_overflow: 0,
    rising_pos_overflow: 0,
    falling_neg_overflow: 0,
    falling_pos_overflow: 0,
    phase_sum: 0,
    fall_to_rise_offset_sum: 0,
    rise_to_fall_offset_sum: 0,
    rising_hist: [0; SYNC_HIST_BINS],
    falling_hist: [0; SYNC_HIST_BINS],
    bits_buffer: 0,
    bits_decoded: 0,
    tx_words_consumed: 0,
    phase_err_ema_rise: 0,
    phase_err_ema_fall: 0,
    acquisition_slot_cyc_period: 0,
    final_interval_fp_period: 0,
    phase_err_ema_period: 0,
    period_hist: [0; PERIOD_HIST_BINS],
    period_sum: 0,
    period_sample_count: 0,
    period_min: i32::MAX,
    period_max: i32::MIN,
    period_ema_slow_fp: 0,
    fpga_decoded_buffer: 0,
    fpga_decoded_count: 0,
    mirror_edges_accepted: 0,
    mirror_edges_rejected_mid_slot: 0,
    mirror_edges_rejected_wrong_polarity: 0,
    mirror_claim12_match: 0,
    mirror_claim12_mispredict_no_edge_observed: 0,
    mirror_claim12_mispredict_wrong_polarity: 0,
    slot_wire_log: [0; 32],
    slot_wire_log_count: 0,
    fpga_decoded_log: [0; 32],
    fpga_decoded_log_count: 0,
    edges_slots_crossed_capped: 0,
    max_observed_slots_crossed: 0,
    edges_parity_ambiguous_skipped: 0,
    raw_own_cyc_log: [0; 256],
    raw_own_cyc_count: 0,
    raw_own_cyc_slot_cyc: 0,
    fpga_decoded_late_log: [0; 32],
    late_raw_own_cyc_log: [0; 256],
    late_raw_own_cyc_count: 0,
};

/// max_iter budget. Setting non-zero arms a sync run; core 1 zeroes it after.
static SYNC_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// FRAC_BITS for the run. Set before SYNC_REQUEST goes non-zero.
static SYNC_FRAC_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Settle iterations: slew but skip binning/accumulators for this many inner-loop iters after acquisition completes. Lets the tracker converge from the seed before the histogram captures it.
static SYNC_SETTLE_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Proportional-tracker shift. Per-edge slew_fp = (phase_err << FRAC_BITS) >> p_shift, so
/// effective gain = 1 / 2^p_shift (in iter units per iter of phase error). Bang-bang
/// (slew = sign of phase_err in fp units, the original behaviour) corresponds to a very
/// small slew per edge; the proportional form converges faster on the magnitude of the
/// error. Default of 8 = gain 1/256: one 256-bit exchange = one full iter of slew if
/// phase_err is consistently 1 iter, which converges in roughly one exchange. Larger
/// shifts (10-12) are gentler / more averaging-friendly.
static SYNC_P_SHIFT_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(8);
/// n_slots cascade mode. 0 = force n_slots=1 (clean-toggle data, single-interval
/// wire by protocol — any edge outside ±half-slot of slot estimate is treated as
/// noise and skipped, no slew). 1 = enable n=1..4 cascade for multi-slot data
/// (LFSR / random data with real multi-slot gaps). Default 1 preserves the
/// historical wire_sync behaviour; wire_mirror forces this to 0 because mirror-XOR
/// data is single-interval by construction. Set BEFORE SYNC_REQUEST goes non-zero.
///
/// Background: the cascade has stable fixed points at own_cyc/n for n ∈ {1,2,3,4}.
/// On data where only n=1 is real, a single noisy edge above the n=1 threshold pulls
/// the loop to the own_cyc/2 fixed point, then own_cyc/3, then own_cyc/4 (cascade
/// promotion chain). Result: interval_fp drifts to ~1/8 of true and the cascade
/// rejects everything. Disabling cascade for known-single-interval data eliminates
/// the dynamic entirely. See plan doc + research notes for prior art (USB SerDes,
/// line-coded comms — same fix pattern).
static SYNC_CASCADE_MODE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(1);
static SYNC_RESPONSE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Mirror-XOR mode flag. 0 = normal wire_sync (no SM1 drive). 1 = wire_mirror
/// (after CDR lock, enable SM1 on next rising edge with TX_MIRROR_PATTERN as
/// the bit source). Set BEFORE SYNC_REQUEST goes non-zero.
static SYNC_MIRROR_MODE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// 32-bit TX pattern fed into SM1's FIFO in mirror mode. LSB-first as `out
/// pins, 1` shifts the OSR right (set_out_shiftdir(true)). Pushed once per
/// FIFO-not-full check inside fast_sync's edge loop.
static TX_MIRROR_PATTERN: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
/// Persistent "we have comms with PIPE" indicator. Reflects the locked state of
/// the MOST RECENT fast_sync / wire_mirror call: 1 = both polarities held 256
/// consecutive in-threshold edges (per SYNC_LOCK_HOLD_EDGES), 0 = lost lock or
/// never locked since the most recent sync. Cleared at start of each sync run
/// while the new lock state is being measured. Surfaced via the `info` command
/// as the `pipe` field so the host (or any peer code) can poll comms state
/// without needing to re-run a full sync.
static PIPE_COMMS_LOCKED: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

// ---------------------------------------------------------------------------
// Wire decode — slot-aligned continuous decode, runs after wire_sync acquisition.
//
// fast_decode reuses fast_sync's acquisition (same-polarity 128+128 sum >> 9) to lock slot_iter, then waits for the next rising edge on the wire to anchor phase: per PROTOCOL.md Layer 1, in idle the enclave drives HIGH on its even slots, so a rising edge marks the start of an enclave (even) slot. From there iter_in_slot counts up to slot, then wraps with slot_phase toggling.
//
// On each iter the bang-bang slew continues (every edge feeds it, same logic as fast_sync). Additionally, at iter_in_slot == slot/2 we sample GP0 and call into the codec: codec.rx(sample) during enclave slots, codec.tx(0) during host slots (we don't drive yet, but the codec state needs to advance both directions).
//
// Output: decoded bit count, distribution (ones/zeros), and the last 256 bits packed into [u64; 4]. In a wire emitting protocol idle (1010), decoded bits should all be 0 (idle = no data). Any non-zero pattern is either real data or a wire structure we haven't accounted for.
// ---------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy)]
struct DecodeResult {
    elapsed_us: u32,
    total_iterations: u32,
    /// 0 = OK, 1 = acquisition incomplete, 2 = no edges, 3 = phase anchor not found.
    status: u32,
    frac_bits: u32,
    /// Initial slot_iter from acquisition (raw iter, sum >> 9).
    acquisition_slot_iter: u32,
    /// Final interval_fp after bang-bang CDR tracking (fixed-point, FRAC_BITS frac bits).
    final_interval_fp: u32,
    /// Per-polarity wire-state widths (just-ended phase durations). hi = HIGH width = rising-to-falling. lo = LOW width = falling-to-rising. Independent because RC asymmetry makes them differ. These are diagnostic only — the SLOT timing for decoding comes from interval_fp / 2 (since one HIGH-LOW cycle = 2 slots).
    hi_count: u32,
    hi_sum_iter: u64,
    hi_min_iter: u32,
    hi_max_iter: u32,
    lo_count: u32,
    lo_sum_iter: u64,
    lo_min_iter: u32,
    lo_max_iter: u32,
    /// Slot-clock samples taken (one per slot after phase anchor).
    slots_total: u32,
    /// Decoded bit counts (one per enclave slot).
    bits_decoded: u32,
    ones: u32,
    zeros: u32,
    /// Last 256 decoded bits. Push: new bit shifts into [0] LSB.
    recent_bits: [u64; 4],
}

static mut DECODE_RESULT: DecodeResult = DecodeResult {
    elapsed_us: 0,
    total_iterations: 0,
    status: 0,
    frac_bits: 0,
    acquisition_slot_iter: 0,
    final_interval_fp: 0,
    hi_count: 0,
    hi_sum_iter: 0,
    hi_min_iter: 0,
    hi_max_iter: 0,
    lo_count: 0,
    lo_sum_iter: 0,
    lo_min_iter: 0,
    lo_max_iter: 0,
    slots_total: 0,
    bits_decoded: 0,
    ones: 0,
    zeros: 0,
    recent_bits: [0; 4],
};

static DECODE_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
static DECODE_FRAC_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
static DECODE_RESPONSE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

/// Host-side mirror-XOR codec, byte-identical to host/src/codec.rs. Inlined here to keep the firmware crate self-contained for now; once the codec is stable we'll lift it into a shared `pipe_codec` crate that both host and firmware import.
struct Codec {
    own_idle: u8,
    other_idle: u8,
    own_last: u8,
    other_last: u8,
}

impl Codec {
    const fn host() -> Self {
        Self {
            own_idle: 0,
            other_idle: 1,
            own_last: 0,
            other_last: 0,
        }
    }
    fn tx(&mut self, data: u8) -> u8 {
        let d = data & 1;
        let wire = self.own_idle ^ d ^ self.other_last;
        self.own_last = d;
        wire & 1
    }
    fn rx(&mut self, wire: u8) -> u8 {
        let w = wire & 1;
        let data = w ^ self.other_idle ^ self.own_last;
        self.other_last = data;
        data
    }
}

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

// Core 1 stack + executor for the Geiger LED task.
// 16 KB stack to hold the 8 KB BLAKE3 buffer + the ~1.7 KB BLAKE3 hasher state
// + executor overhead with comfortable headroom.
static mut CORE1_STACK: Stack<16384> = Stack::new();
static EXECUTOR1: StaticCell<Executor> = StaticCell::new();

/// Core 1's dedicated task: Galois LFSR + ROSC TRNG mixing, Geiger LED on GP25.
///
/// Architecture:
///   - Boot: gather 32 raw ROSC bits → BLAKE3 hash → first 4 bytes seed the LFSR
///     (BLAKE3 still validates on the chip; it just doesn't run in the hot loop)
///   - Hot loop: read 1 fresh ROSC bit, XOR into LFSR state, Galois step,
///     threshold-check, GPIO write
///   - No BLAKE3 in the hot path → no bursts, runs at constant ~8 MHz iters
///
/// LFSR polynomial: 0x80200003 = x^32 + x^22 + x^2 + x + 1 (maximal length over
/// GF(2), period 2^32 - 1 = 4,294,967,295). The continuous ROSC XOR-in means
/// the LFSR is reseeded with one fresh hardware-entropy bit per iteration, so
/// the output is strictly better than pure LFSR.
///
/// Iteration cost (cycles, M0+):
///   - ROSC PAC read:        ~4 (AHB bus)
///   - XOR + shift + cond XOR: 3-4
///   - Two 32-bit compares:  2
///   - Conditional GPIO:     1-2
///   Total: ~12-15 cycles → ~8-10 MHz at 125 MHz sys_clk
/// Tight bit-banged GPIO read into TRACE_FAST_BUF. Caller must guarantee
/// `samples ≤ TRACE_MAX_SAMPLES`, that GP0 is in input mode, and that no
/// other code touches the buffer for the duration. Returns measured wall
/// time in microseconds — host uses it to compute the true sample rate.
/// The timer is ground truth; don't trust the loop's nominal cycle count.
///
/// **Native path (period_ns = 0):** 8x-unrolled inner loop reads SIO.gpio_in
/// directly via `read_volatile` (bypassing Flex), shifts bit 0 into position,
/// ORs into a u8 accumulator, stores one byte. Per-sample cost on M0+ is
/// roughly LDR + AND + LSL + ORR ≈ 4-5 cycles → ~25-30 MS/s. The byte-store
/// boundary adds maybe 6-8 cycles, so every 8th sample sees a ~2x stutter —
/// irrelevant for diagnostic use; the *average* period that elapsed_us
/// reports is what matters.
///
/// **Delay path (period_ns > 0):** simple per-sample loop with
/// `cortex_m::asm::delay(cycles)` between reads, cycles = period_ns ×
/// sys_clk_hz / 1e9. Effective period > requested at low values because
/// the read+pack overhead floors it.
fn fast_capture(samples: usize, period_ns: u32) -> u32 {
    let samples = samples.min(TRACE_MAX_SAMPLES);
    if samples == 0 {
        return 0;
    }
    let bytes_used = (samples + 7) >> 3;

    // Zero only the portion we'll write — saves 1 KiB of store traffic on
    // short captures.
    let buf_ptr = &raw mut TRACE_FAST_BUF as *mut u8;
    unsafe {
        for i in 0..bytes_used {
            buf_ptr.add(i).write_volatile(0);
        }
    }

    // SIO.gpio_in(0) is a single u32 mirror of GP0–GP29 input states; GP0 is bit 0.
    // (bank 1 is QSPI pads, irrelevant here.) Hold the pointer so the inner loop
    // is just LDR with no PAC handle marshalling.
    let gpio_in: *const u32 = embassy_rp::pac::SIO.gpio_in(0).as_ptr();

    let sys_clk_hz = embassy_rp::clocks::clk_sys_freq() as u64;
    let delay_cycles: u32 = if period_ns == 0 {
        0
    } else {
        ((period_ns as u64) * sys_clk_hz / 1_000_000_000) as u32
    };

    let start = embassy_time::Instant::now();

    if delay_cycles == 0 {
        // Native rate: 8 samples → 1 byte, no per-sample byte_idx/bit_pos math.
        let whole_bytes = samples >> 3;
        let tail = samples & 7;
        unsafe {
            for byte_idx in 0..whole_bytes {
                let b0 = (gpio_in.read_volatile() & 1) as u8;
                let b1 = (gpio_in.read_volatile() & 1) as u8;
                let b2 = (gpio_in.read_volatile() & 1) as u8;
                let b3 = (gpio_in.read_volatile() & 1) as u8;
                let b4 = (gpio_in.read_volatile() & 1) as u8;
                let b5 = (gpio_in.read_volatile() & 1) as u8;
                let b6 = (gpio_in.read_volatile() & 1) as u8;
                let b7 = (gpio_in.read_volatile() & 1) as u8;
                let byte = b0
                    | (b1 << 1)
                    | (b2 << 2)
                    | (b3 << 3)
                    | (b4 << 4)
                    | (b5 << 5)
                    | (b6 << 6)
                    | (b7 << 7);
                buf_ptr.add(byte_idx).write_volatile(byte);
            }
            // Tail: 0-7 partial bits at the end. Slower per sample but tiny.
            if tail > 0 {
                let mut byte: u8 = 0;
                for bit in 0..tail {
                    byte |= ((gpio_in.read_volatile() & 1) as u8) << bit;
                }
                buf_ptr.add(whole_bytes).write_volatile(byte);
            }
        }
    } else {
        // Delay path: per-sample timing, kept simple. Inter-byte stutter is
        // irrelevant when delay_cycles dominates.
        unsafe {
            for i in 0..samples {
                let bit = (gpio_in.read_volatile() & 1) as u8;
                let byte_idx = i >> 3;
                let bit_pos = (i & 7) as u8;
                let p = buf_ptr.add(byte_idx);
                p.write_volatile(p.read_volatile() | (bit << bit_pos));
                cortex_m::asm::delay(delay_cycles);
            }
        }
    }

    start.elapsed().as_micros() as u32
}

/// Tight bit-banged stats collector. Reads GP0 at native loop rate, tracks per-state run length stats (count, min, max, sum, sumsq) so the host can derive duty cycle, average frequency, and pulse-width stddev from one pass. No buffer — sample budget is the only bound.
///
/// Same disable-IRQs invariant as fast_capture: caller MUST wrap this in `cortex_m::interrupt::free` so the inner loop runs without USB/timer preemption. Returns measured wall time in microseconds; host divides by samples_taken for true sample rate (timer is ground truth).
///
/// Inner loop on M0+, non-toggle path: LDR gpio → AND #1 → CMP prev → BEQ same → ADD cur_run, #1 → branch ≈ 5-6 cycles → matches fast_capture's ~24 MS/s floor.
///
/// Toggle path closes the current run into hi_* or lo_* accumulators: one u32×u32→u32 MULS (M0+ single-cycle), two min/max compares, u64 sum with carry. Only runs on edges, so rare relative to sample count.
fn fast_stats(samples: u32) -> WireStats {
    let samples = samples.min(STATS_MAX_SAMPLES);
    let gpio_in: *const u32 = embassy_rp::pac::SIO.gpio_in(0).as_ptr();

    let mut hi_count: u32 = 0;
    let mut hi_min: u32 = u32::MAX;
    let mut hi_max: u32 = 0;
    let mut hi_sum: u64 = 0;
    let mut hi_sumsq: u64 = 0;
    let mut lo_count: u32 = 0;
    let mut lo_min: u32 = u32::MAX;
    let mut lo_max: u32 = 0;
    let mut lo_sum: u64 = 0;
    let mut lo_sumsq: u64 = 0;
    let mut hi_hist = [0u32; STATS_HIST_BINS];
    let mut lo_hist = [0u32; STATS_HIST_BINS];

    if samples == 0 {
        return WireStats {
            elapsed_us: 0,
            samples_taken: 0,
            final_state: 0,
            final_run: 0,
            hi_count: 0,
            hi_min: 0,
            hi_max: 0,
            hi_sum: 0,
            hi_sumsq: 0,
            lo_count: 0,
            lo_min: 0,
            lo_max: 0,
            lo_sum: 0,
            lo_sumsq: 0,
            hi_hist,
            lo_hist,
        };
    }

    let start = embassy_time::Instant::now();

    // Prime: first sample seeds prev + opens cur_run = 1.
    let mut prev: u32 = unsafe { gpio_in.read_volatile() & 1 };
    let mut cur_run: u32 = 1;

    for _ in 1..samples {
        let cur = unsafe { gpio_in.read_volatile() & 1 };
        if cur == prev {
            cur_run += 1;
        } else {
            // Close out the run we just left. prev is the state that ran.
            let run = cur_run;
            let run64 = run as u64;
            let sq = run64 * run64;
            // log2 bin: floor(log2(run)) clamped to [0, STATS_HIST_BINS-1]. M0+ has no CLZ; leading_zeros lowers to __clzsi2 (~20 cyc), only hit per toggle (rare relative to sample count) so negligible.
            let bin = (31 - run.leading_zeros()) as usize;
            let bin = if bin >= STATS_HIST_BINS { STATS_HIST_BINS - 1 } else { bin };
            if prev == 1 {
                hi_count += 1;
                if run < hi_min {
                    hi_min = run;
                }
                if run > hi_max {
                    hi_max = run;
                }
                hi_sum += run64;
                hi_sumsq += sq;
                hi_hist[bin] += 1;
            } else {
                lo_count += 1;
                if run < lo_min {
                    lo_min = run;
                }
                if run > lo_max {
                    lo_max = run;
                }
                lo_sum += run64;
                lo_sumsq += sq;
                lo_hist[bin] += 1;
            }
            prev = cur;
            cur_run = 1;
        }
    }

    let elapsed_us = start.elapsed().as_micros() as u32;

    // Clean up sentinel mins if no runs of that state were ever closed.
    if hi_count == 0 {
        hi_min = 0;
    }
    if lo_count == 0 {
        lo_min = 0;
    }

    WireStats {
        elapsed_us,
        samples_taken: samples,
        final_state: prev,
        final_run: cur_run,
        hi_count,
        hi_min,
        hi_max,
        hi_sum,
        hi_sumsq,
        lo_count,
        lo_min,
        lo_max,
        lo_sum,
        lo_sumsq,
        hi_hist,
        lo_hist,
    }
}

/// CDR sync loop. Caller MUST run inside `cortex_m::interrupt::free` — the PIO FIFO
/// reads can't tolerate IRQ-driven backlog beyond the 8-deep RX FIFO depth (~1.3 ms
/// @ 6 kHz edge rate, plenty of margin but still need IRQs off for safety).

// ============================================================================
// PIO0 SM0 — cycle-accurate edge timestamping on GP0
// ============================================================================
//
// The polling fast_sync samples GP0 every ~15 sys_clk cycles (~120 ns at 125 MHz),
// which puts a uniform [0, 15] cyc detection-latency on every edge. Across two
// edges the difference is triangular [-15, +15] with std ≈ 6 cyc — that quantization
// noise dominates the per-edge std we measured (8-10 cyc) and the wire-jitter signal
// (which is ~0.02% × 365 cyc ≈ 0.07 cyc) sits 100× below it.
//
// PIO program: a counter (X register) decrements while waiting for the pin's next
// transition; on transition, X is pushed to the RX FIFO. The CPU pops intervals
// at edge rate and feeds them directly into the cross-polarity tracker math.
//
// Resolution: the wait loop is 2 PIO instructions = 2 sys_clk cycles per decrement,
// so X measures intervals in 2-cycle units (16 ns at 125 MHz). Predicted per-edge
// std drops from ~6 cyc to ~0.5 cyc, exposing the wire's actual jitter floor.
//
// FIFO encoding: each u32 word is X at capture time. Interval count in 2-cyc units
// is `0xFFFFFFFF - X = !X`, so cycles = `2 × !X`. Polarity isn't encoded in the
// word — instead the host alternates starting from the OPPOSITE of the initial
// pin state captured before SM enable.
//
// Hand-encoded per RP2040 datasheet 3.4.2 (no proc-macro dep):
//   [15:13]=opcode  [12:8]=delay/SS (=0)  [7:0]=operand
//   jmp pin, addr:   000 _____ 110 aaaaa  → 0x00C0 | addr
//   jmp x--, addr:   000 _____ 010 aaaaa  → 0x0040 | addr
//   jmp addr:        000 _____ 000 aaaaa  → 0x0000 | addr
//   in x, 32:        010 _____ 001 00000  → 0x4020
//   push (block):    100 _____ 0 0 1 00000 → 0x8020
//   mov x, !null:    101 _____ 001 01 011  → 0xA02B
//
// Program layout (addr / instr):
//   0  jmp pin, 6         ; if pin starts HIGH, skip into the top_high half
// .wrap_target = 1
//   1  mov x, !null       ; (top_low: waiting for pin to go HIGH)
//   2  jmp pin, 4
//   3  jmp x--, 2
//   4  in x, 32           ; (caught_high)
//   5  push (block)
//   6  mov x, !null       ; (top_high: waiting for pin to go LOW)
//   7  jmp pin, 9
//   8  jmp 10
//   9  jmp x--, 7
//  10  in x, 32           ; (caught_low)
//  11  push (block)
// .wrap_top = 11 → wraps back to wrap_target = 1
const PIO_EDGE_PROG: [u16; 12] = [
    0x00C0 | 6,    //  0  jmp pin, 6
    0xA02B,        //  1  mov x, !null
    0x00C0 | 4,    //  2  jmp pin, 4
    0x0040 | 2,    //  3  jmp x--, 2
    0x4020,        //  4  in x, 32
    0x8020,        //  5  push (block)
    0xA02B,        //  6  mov x, !null
    0x00C0 | 9,    //  7  jmp pin, 9
    0x0000 | 10,   //  8  jmp 10
    0x0040 | 7,    //  9  jmp x--, 7
    0x4020,        // 10  in x, 32
    0x8020,        // 11  push (block)
];
const PIO_EDGE_SM: usize = 0;
const PIO_EDGE_GPIO: u8 = 0; // GP0
// Bridge-side TX piezo mirror as H-bridge pair (piezo between the two pins, not pin-
// to-GND): doubles the audio swing across the piezo from 3.3 V to 6.6 V. Latched on
// host slot entry, held through enclave slots so the audio is continuous (a stair-
// step at the FPGA-cycle rate, not a chopped per-slot toggle).
const PIEZO_TX_P_GPIO: u8 = 10; // in-phase   leg
const PIEZO_TX_N_GPIO: u8 = 11; // anti-phase leg

/// One-shot load of the program into PIO0 SM0's instruction memory and register setup.
/// Safe to call repeatedly — disables the SM first.
fn pio_edge_init() {
    use embassy_rp::pac::PIO0;
    use embassy_rp::pac::pio::regs::{InstrMem, SmClkdiv};

    // Disable SM0 (clear bit 0 of CTRL.sm_enable, preserve other SMs).
    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur & !(1 << PIO_EDGE_SM));
    });

    // Load 12 instructions into instr_mem[0..12].
    for (i, &word) in PIO_EDGE_PROG.iter().enumerate() {
        PIO0.instr_mem(i).write_value(InstrMem(word as u32));
    }

    // EXECCTRL: wrap_top=11, wrap_bottom=1, jmp_pin=GP0.
    PIO0.sm(PIO_EDGE_SM).execctrl().write(|w| {
        w.set_wrap_top(11);
        w.set_wrap_bottom(1);
        w.set_jmp_pin(PIO_EDGE_GPIO);
    });

    // SHIFTCTRL: explicit push (no autopush), join TX into RX for 8-deep RX FIFO.
    PIO0.sm(PIO_EDGE_SM).shiftctrl().write(|w| {
        w.set_fjoin_rx(true);
        w.set_in_shiftdir(true); // right; doesn't matter for full-word in
        w.set_autopush(false);
    });

    // CLKDIV = 1.0 (full sys_clk). Format: int<<16 | frac<<8.
    PIO0.sm(PIO_EDGE_SM).clkdiv().write_value(SmClkdiv(0x0001_0000));
}

/// Start a capture run. Returns the pin's current logic level so the host knows the
/// polarity of the FIRST edge (which will be the opposite of this value).
fn pio_edge_start() -> u32 {
    use embassy_rp::pac::{PIO0, SIO};
    use embassy_rp::pac::pio::regs::SmInstr;

    // Read pin state via SIO (independent of PIO funcsel — GPIO inputs are always
    // mirrored to all peripherals on RP2040).
    let initial = unsafe { (SIO.gpio_in(0).as_ptr().read_volatile() >> PIO_EDGE_GPIO) & 1 };

    // Drain anything stale in the RX FIFO.
    while (PIO0.fstat().read().rxempty() & (1 << PIO_EDGE_SM)) == 0 {
        let _ = PIO0.rxf(PIO_EDGE_SM).read();
    }

    // SM restart + clkdiv restart. Both are write-1-to-pulse fields in CTRL.
    PIO0.ctrl().modify(|w| {
        w.set_sm_restart(1 << PIO_EDGE_SM);
        w.set_clkdiv_restart(1 << PIO_EDGE_SM);
    });

    // Force PC = 0 by injecting `jmp 0` into SMx_INSTR.
    PIO0.sm(PIO_EDGE_SM).instr().write_value(SmInstr(0x0000));

    // Enable SM0.
    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur | (1 << PIO_EDGE_SM));
    });

    initial
}

fn pio_edge_stop() {
    use embassy_rp::pac::PIO0;
    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur & !(1 << PIO_EDGE_SM));
    });
}

/// Pop the next FIFO word, bounded by a wall-clock deadline. Returns None on timeout.
/// In loopback mode (TX_LOOPBACK_PATTERN nonzero), tops up the TX FIFO with the
/// pattern word while waiting for RX. This lets the dispatch handler turn TX on
/// before triggering fast_sync and have the TX stream stay continuous through the
/// whole capture window without needing a separate refill task.
#[inline(always)]
fn pio_edge_read_until(deadline_us: u64, start: embassy_time::Instant) -> Option<u32> {
    use embassy_rp::pac::PIO0;
    let tx_pattern = TX_LOOPBACK_PATTERN.load(PaOrdering::Relaxed);
    while (PIO0.fstat().read().rxempty() & (1 << PIO_EDGE_SM)) != 0 {
        if tx_pattern != 0 && (PIO0.fstat().read().txfull() & (1 << PIO_TX_SM)) == 0 {
            PIO0.txf(PIO_TX_SM).write_value(tx_pattern);
        }
        if start.elapsed().as_micros() > deadline_us {
            return None;
        }
    }
    Some(PIO0.rxf(PIO_EDGE_SM).read())
}

/// When nonzero, fast_sync's PIO RX read loop refills PIO TX FIFO with this 32-bit
/// pattern. Dispatch handler sets this before triggering fast_sync (and clears
/// after) for the wire_loopback test. Zero = no TX, normal RX-only path.
static TX_LOOPBACK_PATTERN: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

// ============================================================================
// PIO0 SM1 — TX state machine, drives GP0 at slot rate
// ============================================================================
//
// Single-instruction loop: `out pins, 1` shifts the LSB of the OSR onto GP0 every
// PIO cycle, with autopull refilling the OSR from the TX FIFO every 32 bits. SM
// clock is divided to one tick per wire slot, so each bit out of the FIFO occupies
// exactly one slot. CPU pushes 32-bit chunks; PIO drives them out at slot rate.
//
// Sharing the PIO with the RX SM: GP0 funcsel switches to PIO0 when TX is enabled
// (so PIO can drive). The RX SM (jmp pin / in pins reads) doesn't care about
// funcsel — GPIO inputs are always available to PIO regardless. Both SMs run
// concurrently; bridge can transmit and receive at the same time.
//
// Slot rate target ~348 kHz (matches the FPGA's 4-cycle slot at ~1.39 MHz
// enclave_clk). At 125 MHz sys_clk: divider = 125e6 / 348e3 ≈ 359.20. Using
// int=359, frac=51 (0.2 × 256) for a clean slot match.
//
// out pins, 1: opcode=011, dest=000 (PINS), bits=00001 → 0x6001
// set pindirs, 1: opcode=111, dest=100 (PINDIRS), data=00001 → 0xE081
const PIO_TX_PROG_ADDR: usize = 16; // RX uses 0-11; leave room and put TX at 16
const PIO_TX_INSTR: u16 = 0x6001;   // out pins, 1
const PIO_TX_SETDIR_INSTR: u16 = 0xE081; // set pindirs, 1
const PIO_TX_SM: usize = 1;
const PIO_FUNCSEL_PIO0: u8 = 6;
const PIO_FUNCSEL_SIO: u8 = 5;

// Mirror-XOR slot-aware TX program (2 instructions, side-set on PINDIRS).
// Loaded at addresses 14 and 15 — distinct from PIO_TX_PROG_ADDR=16 so the
// existing single-instruction `wire_loopback` path keeps working.
//
//   addr 14: `nop side 0`              = mov y,y with side-set 0 → PINDIRS = 0
//   addr 15: `out pins, 1 side 1`      → PINDIRS = 1, shift 1 OSR bit to GP0
//
// With side_set_count=1 + side_pindir=true, bit [12] of each instruction is
// the side-set output, routed to PINDIRS (NOT pin values). When PINDIRS=0
// the pin tristates; when PINDIRS=1 the pin drives whatever OUT/SET asserted.
//
// The SM cycles addr 14 → 15 → 14 → 15 ... at clkdiv rate. With clkdiv set
// per FPGA slot (one instruction = one slot), this maps directly:
//   enclave slot: nop side 0          → PINDIRS=0, FPGA owns the wire
//   host slot:    out pins, 1 side 1  → PINDIRS=1, bridge drives one TX bit
//
// Encodings (PIO bit fields: opcode[15:13] | sideset/delay[12:8] | operand[7:0]):
//   nop = mov y,y = 0xA042 (opcode=101 MOV, dest=010 Y, op=000, src=010 Y)
//   side 0 with side_set_count=1: bit [12] cleared → 0xA042 unchanged
//   out pins, 1 = 0x6001 (opcode=011 OUT, dest=000 PINS, data=00001)
//   side 1 with side_set_count=1: bit [12] set → 0x6001 | (1<<12) = 0x7001
const PIO_TX_MIRROR_ADDR: usize = 14;
const PIO_TX_MIRROR_NOP_SIDE0: u16 = 0xA042;    // nop side 0  (PINDIRS=0, tristate)
const PIO_TX_MIRROR_OUT_SIDE1: u16 = 0x7001;    // out pins,1 side 1 (PINDIRS=1, drive)
const PIO_TX_MIRROR_CLRDIR_INSTR: u16 = 0xE080; // set pindirs, 0 (one-shot pre-enable)

fn pio_tx_init() {
    use embassy_rp::pac::PIO0;
    use embassy_rp::pac::pio::regs::{InstrMem, SmClkdiv, SmInstr};

    // Disable SM1 first.
    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur & !(1 << PIO_TX_SM));
    });

    // Load OUT instruction at slot 16.
    PIO0.instr_mem(PIO_TX_PROG_ADDR).write_value(InstrMem(PIO_TX_INSTR as u32));

    // Single-instruction loop: wrap_top = wrap_bottom = 16.
    PIO0.sm(PIO_TX_SM).execctrl().write(|w| {
        w.set_wrap_top(PIO_TX_PROG_ADDR as u8);
        w.set_wrap_bottom(PIO_TX_PROG_ADDR as u8);
        w.set_jmp_pin(PIO_EDGE_GPIO); // unused but keep consistent
    });

    // Autopull every 32 bits; right-shift OSR (LSB first onto pin); join TX FIFO
    // (8-deep for headroom). Threshold = 0 means 32 in PIO encoding.
    PIO0.sm(PIO_TX_SM).shiftctrl().write(|w| {
        w.set_autopull(true);
        w.set_pull_thresh(0);
        w.set_out_shiftdir(true);
        w.set_fjoin_tx(true);
    });

    // Pinctrl: drive GP0 only.
    PIO0.sm(PIO_TX_SM).pinctrl().write(|w| {
        w.set_out_base(PIO_EDGE_GPIO);
        w.set_out_count(1);
        w.set_set_base(PIO_EDGE_GPIO);
        w.set_set_count(1);
    });

    // Slot-rate divider: int=359, frac=51 → 348.0 kHz exactly at 125 MHz.
    PIO0.sm(PIO_TX_SM).clkdiv().write(|w| {
        w.set_int(359);
        w.set_frac(51);
    });

    // Inject `set pindirs, 1` to make GP0 an output (one-shot, doesn't touch the
    // wrap loop since we're not enabled yet).
    PIO0.sm(PIO_TX_SM).instr().write_value(SmInstr(PIO_TX_SETDIR_INSTR as u32));
}

/// Take ownership of GP0 (switch funcsel to PIO0) and enable the TX SM. Caller is
/// responsible for pumping the FIFO (via pio_tx_push_word) and stopping when done.
fn pio_tx_start() {
    use embassy_rp::pac::{IO_BANK0, PADS_BANK0, PIO0};
    use embassy_rp::pac::io::vals::{Oeover, Outover};

    // Clear PAD output-disable so PIO can actually drive the pin. Flex::set_as_input
    // leaves PADS_BANK0.gpio[N].od at its boot default (which is typically 1 = output
    // disabled) — PAD.OD has priority over peripheral OE per RP2040 datasheet 2.19,
    // so without this the SM runs but the pin stays floating.
    // Schmitt explicitly TRUE: silicon default per RP2040 reset value but we set it
    // anyway because the 400Ω series + weak pulldown wire is noisy enough that any
    // accidental clear (e.g. from embassy's Flex::set_as_input) would cause RC ringing
    // to register as spurious edges (sub-100ns slivers + quarter-slot splits seen in
    // raw_own_cyc histogram).
    PADS_BANK0.gpio(PIO_EDGE_GPIO as usize).modify(|w| {
        w.set_od(false);       // enable output driver
        w.set_ie(true);        // keep input enabled so PIO RX can still read the pad
        w.set_schmitt(true);   // hysteresis deglitch on RX path
    });

    // Switch GP0 to PIO0 funcsel and FORCE output enabled (Oeover::ENABLE bypasses
    // PIO's PINDIRS — even if the SET PINDIRS injection during init didn't take,
    // the IO_BANK0 override here will drive the pad). Use write() to ensure all
    // ctrl fields go to known values (outover=NORMAL so peripheral signal reaches
    // pad, oeover=ENABLE to force drive).
    IO_BANK0.gpio(PIO_EDGE_GPIO as usize).ctrl().write(|w| {
        w.set_funcsel(PIO_FUNCSEL_PIO0);
        w.set_outover(Outover::NORMAL);
        w.set_oeover(Oeover::ENABLE);
    });

    // Restart + enable SM1. sm_restart clears X/Y/scratch/shifters but NOT the PC
    // (RP2040 datasheet §3.4.6.1) — so we need to force PC to our TX program at
    // addr PIO_TX_PROG_ADDR via a `jmp PROG_ADDR` injection. Otherwise the SM runs
    // whatever happens to be at instr_mem[0..], which is the RX program (loaded
    // by pio_edge_init) — and the pin never sees the TX output.
    PIO0.ctrl().modify(|w| {
        w.set_sm_restart(1 << PIO_TX_SM);
        w.set_clkdiv_restart(1 << PIO_TX_SM);
    });
    // jmp PIO_TX_PROG_ADDR: opcode=000, cond=000 (always), addr=PIO_TX_PROG_ADDR
    let jmp_to_tx = (PIO_TX_PROG_ADDR as u32) & 0x1F;
    PIO0.sm(PIO_TX_SM).instr().write_value(embassy_rp::pac::pio::regs::SmInstr(jmp_to_tx));
    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur | (1 << PIO_TX_SM));
    });
}

fn pio_tx_stop() {
    use embassy_rp::pac::{IO_BANK0, PIO0};

    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur & !(1 << PIO_TX_SM));
    });

    // Hand GP0 back to SIO and put it in input mode (so the FPGA isn't fighting us).
    IO_BANK0.gpio(PIO_EDGE_GPIO as usize).ctrl().modify(|w| w.set_funcsel(PIO_FUNCSEL_SIO));
    // SIO is now driving — clear OE so we don't drive.
    embassy_rp::pac::SIO.gpio_oe(0).value_clr().write_value(1 << PIO_EDGE_GPIO);
}

/// Push one 32-bit word into the TX FIFO. Blocks if the FIFO is full (waits for PIO
/// to drain a slot worth of bits, ~92 µs at 348 kHz slot rate per slot).
fn pio_tx_push_word(word: u32) {
    use embassy_rp::pac::PIO0;
    while (PIO0.fstat().read().txfull() & (1 << PIO_TX_SM)) != 0 {}
    PIO0.txf(PIO_TX_SM).write_value(word);
}

/// Block until the TX FIFO + OSR have fully drained (all bits clocked out).
fn pio_tx_drain() {
    use embassy_rp::pac::PIO0;
    while (PIO0.fstat().read().txempty() & (1 << PIO_TX_SM)) == 0 {}
    // FIFO is empty but OSR may still hold up to 32 bits being shifted out.
    // 32 bits at 348 kHz = ~92 µs; give it ample slack.
    embassy_time::block_for(embassy_time::Duration::from_micros(200));
}

/// Configure SM1 for mirror-XOR slot-aware drive. Loads the 2-instruction TX
/// program at addr 14-15, sets up side-set on PINDIRS via PINCTRL+EXECCTRL,
/// matches autopull/shift config from pio_tx_init. Caller follows with
/// pio_tx_mirror_start(clkdiv) once the CDR has a slot estimate.
fn pio_tx_mirror_init() {
    use embassy_rp::pac::PIO0;
    use embassy_rp::pac::pio::regs::InstrMem;

    // Disable SM1 first.
    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur & !(1 << PIO_TX_SM));
    });

    // Load the 2-instruction program.
    PIO0.instr_mem(PIO_TX_MIRROR_ADDR).write_value(InstrMem(PIO_TX_MIRROR_NOP_SIDE0 as u32));
    PIO0.instr_mem(PIO_TX_MIRROR_ADDR + 1).write_value(InstrMem(PIO_TX_MIRROR_OUT_SIDE1 as u32));

    // Wrap addr 14 → 15 → 14 → 15. wrap_bottom is where the SM jumps BACK to after executing wrap_top.
    PIO0.sm(PIO_TX_SM).execctrl().write(|w| {
        w.set_wrap_bottom(PIO_TX_MIRROR_ADDR as u8);
        w.set_wrap_top((PIO_TX_MIRROR_ADDR + 1) as u8);
        w.set_jmp_pin(PIO_EDGE_GPIO);
        w.set_side_pindir(true); // side-set bits go to PINDIRS, NOT pin values
    });

    PIO0.sm(PIO_TX_SM).shiftctrl().write(|w| {
        w.set_autopull(true);
        w.set_pull_thresh(0); // 0 means 32 in PIO encoding
        w.set_out_shiftdir(true);
        w.set_fjoin_tx(true);
    });

    // PINCTRL: out/set/sideset all target GP0. sideset_count=1 places the side-set bit at [12].
    PIO0.sm(PIO_TX_SM).pinctrl().write(|w| {
        w.set_out_base(PIO_EDGE_GPIO);
        w.set_out_count(1);
        w.set_set_base(PIO_EDGE_GPIO);
        w.set_set_count(1);
        w.set_sideset_base(PIO_EDGE_GPIO);
        w.set_sideset_count(1);
    });

    // CLKDIV is set per-run by pio_tx_mirror_start (seeded from acquisition).
}

/// Start SM1 in mirror-XOR mode aligned to the rising edge that just happened
/// (start of FPGA enclave slot). Sets CLKDIV, takes GP0 funcsel, pre-clears
/// PINDIRS to 0 (tristate), injects `jmp PIO_TX_MIRROR_ADDR`, enables SM.
///
/// Unlike pio_tx_start which uses Oeover::ENABLE (forces drive always),
/// mirror mode uses Oeover::NORMAL so PIO PINDIRS controls OE — required for
/// the side-set tristate-during-enclave-slot behaviour to actually take effect
/// at the pad.
fn pio_tx_mirror_start(clkdiv_int: u16, clkdiv_frac: u8) {
    use embassy_rp::pac::{IO_BANK0, PADS_BANK0, PIO0};
    use embassy_rp::pac::io::vals::{Oeover, Outover};
    use embassy_rp::pac::pio::regs::SmInstr;

    // Set the slot-rate clkdiv from acquisition.
    PIO0.sm(PIO_TX_SM).clkdiv().write(|w| {
        w.set_int(clkdiv_int);
        w.set_frac(clkdiv_frac);
    });

    // PAD: enable driver (od=0), keep input enabled (ie=1) so PIO RX can still sample GP0.
    // Schmitt TRUE: silicon hysteresis deglitches the RX path against RC ringing on
    // wire transitions (see raw_own_cyc histogram: sub-100ns slivers and quarter-slot
    // splits before this was set explicitly).
    PADS_BANK0.gpio(PIO_EDGE_GPIO as usize).modify(|w| {
        w.set_od(false);
        w.set_ie(true);
        w.set_schmitt(true);
    });

    // GP0 → PIO0 funcsel. CRITICAL: Oeover::NORMAL (not ENABLE) so PINDIRS controls OE.
    IO_BANK0.gpio(PIO_EDGE_GPIO as usize).ctrl().write(|w| {
        w.set_funcsel(PIO_FUNCSEL_PIO0);
        w.set_outover(Outover::NORMAL);
        w.set_oeover(Oeover::NORMAL);
    });

    // Pre-clear PINDIRS so the pad is tristated until the first instruction's
    // side-set fires. Without this, PINDIRS retains whatever the prior
    // pio_tx_init injection set (=1), and the pad would briefly drive at sm_enable.
    PIO0.ctrl().modify(|w| {
        w.set_sm_restart(1 << PIO_TX_SM);
        w.set_clkdiv_restart(1 << PIO_TX_SM);
    });
    PIO0.sm(PIO_TX_SM).instr().write_value(SmInstr(PIO_TX_MIRROR_CLRDIR_INSTR as u32));

    // Force PC to PIO_TX_MIRROR_ADDR (nop side 0 — enclave slot). sm_restart leaves
    // PC stale per RP2040 datasheet §3.4.6.1, so without this the SM would run
    // from instr_mem[0..] (which is the RX program).
    let jmp_to_mirror = (PIO_TX_MIRROR_ADDR as u32) & 0x1F;
    PIO0.sm(PIO_TX_SM).instr().write_value(SmInstr(jmp_to_mirror));

    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur | (1 << PIO_TX_SM));
    });
}

/// Stop mirror-mode SM1 and hand GP0 back to SIO input (so the FPGA isn't fought).
fn pio_tx_mirror_stop() {
    use embassy_rp::pac::{IO_BANK0, PIO0};

    PIO0.ctrl().modify(|w| {
        let cur = w.sm_enable();
        w.set_sm_enable(cur & !(1 << PIO_TX_SM));
    });

    IO_BANK0.gpio(PIO_EDGE_GPIO as usize).ctrl().modify(|w| w.set_funcsel(PIO_FUNCSEL_SIO));
    embassy_rp::pac::SIO.gpio_oe(0).value_clr().write_value(1 << PIO_EDGE_GPIO);
}

/// Try to push a 32-bit word into SM1's TX FIFO. Returns true if pushed.
/// Non-blocking — lets the per-edge loop top up the FIFO without stalling.
fn pio_tx_try_push(word: u32) -> bool {
    use embassy_rp::pac::PIO0;
    if (PIO0.fstat().read().txfull() & (1 << PIO_TX_SM)) != 0 {
        return false;
    }
    PIO0.txf(PIO_TX_SM).write_value(word);
    true
}

/// Convert an interval_fp value (slot in sys_clk × 2^frac_bits) into the SM1
/// CLKDIV (int + 8-bit frac) format. With SM1's 2-instruction program running
/// one instruction per FPGA slot, clkdiv per instruction in sys_clk = slot.
fn interval_fp_to_clkdiv(interval_fp: u32, frac_bits: u32) -> (u16, u8) {
    let clkdiv_int = (interval_fp >> frac_bits).min(u16::MAX as u32) as u16;
    let clkdiv_frac = if frac_bits >= 8 {
        ((interval_fp >> (frac_bits - 8)) & 0xFF) as u8
    } else {
        ((interval_fp & ((1u32 << frac_bits) - 1)) << (8 - frac_bits)) as u8
    };
    (clkdiv_int, clkdiv_frac)
}

fn fast_sync(max_iter: u32, frac_bits: u32, settle_iter: u32, p_shift: u32, mirror_mode: bool, tx_pattern: u32, cascade_mode: u32) -> SyncResult {
    let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);
    let start = embassy_time::Instant::now();

    // PIO0 SM0 captures every edge's interval (cycles since previous edge of either
    // polarity) at 2 sys_clk resolution. The CPU pops words from the RX FIFO and feeds
    // them straight into the same cross-polarity tracker the polling version uses.
    // The `iter` counter is now edge-indexed, not poll-indexed.
    pio_edge_init();
    let initial = pio_edge_start();

    // TX piezo H-bridge pair (GP10 in-phase, GP11 anti-phase). Configure as SIO outputs
    // once; latched on each host-slot entry in the slots_crossed loop and HELD through
    // enclave slots. Use lowest-drive pad setting (2 mA on RP2040 is `Drive2mA`) to keep
    // the piezo quiet by default; the user can increase if more volume wanted.
    {
        use embassy_rp::pac::{IO_BANK0, PADS_BANK0, SIO};
        use embassy_rp::pac::io::vals::{Oeover, Outover};
        for pin in [PIEZO_TX_P_GPIO, PIEZO_TX_N_GPIO] {
            PADS_BANK0.gpio(pin as usize).modify(|w| {
                w.set_od(false);
                w.set_ie(false);
                w.set_drive(embassy_rp::pac::pads::vals::Drive::_2MA);
            });
            IO_BANK0.gpio(pin as usize).ctrl().write(|w| {
                w.set_funcsel(5); // SIO
                w.set_outover(Outover::NORMAL);
                w.set_oeover(Oeover::NORMAL);
            });
            SIO.gpio_oe(0).value_set().write_value(1 << pin);
            SIO.gpio_out(0).value_clr().write_value(1 << pin);
        }
    }

    // Mirror-XOR slot-aware drive: pre-configure SM1 with the 2-instruction program
    // and side-set on PINDIRS. The SM isn't enabled here — pio_tx_mirror_start fires
    // on the first rising edge after acquisition, anchoring SM1 to the start of an
    // FPGA enclave slot. tx_words_consumed tracks FIFO pushes for diagnostic.
    let mut mirror_armed = false;
    let mut mirror_started = false;
    let mut tx_words_consumed: u32 = 0;
    if mirror_mode {
        pio_tx_mirror_init();
        TX_MIRROR_PATTERN.store(tx_pattern, PaOrdering::Relaxed);
    }

    // Mirror-mode slot-phase + TX-bit-aware edge filter. After SM1 anchors on a rising
    // edge (start of FPGA enclave slot), the bridge tracks cumulative cycles since
    // anchor. slot_phase toggles per slot boundary; tx_shift_reg mirrors SM1's OSR
    // consumption (one bit per host slot, LSB-first). Each observed wire edge is
    // checked against the predicted wire state — only edges that match what the FPGA
    // and our own TX should produce are fed into the CDR. Spurious edges from SM1
    // tristate-glitches or contention get rejected, breaking the positive-feedback
    // loop that drove interval_fp_low to runaway shrinkage in the un-filtered version.
    let mut cumulative_cyc_since_anchor: u64 = 0;
    let mut slots_since_anchor: u64 = 0;
    let mut slot_phase: u32 = 0;     // 0 = enclave (FPGA owns), 1 = host (bridge owns)
    let mut tx_shift_reg: u32 = tx_pattern;
    let mut tx_bits_remaining: u32 = 32;
    let mut current_tx_bit: u8 = 0;  // bit bridge is driving in the current host slot
    let mut last_driven_bit: u8 = 0; // bit bridge drove in the most recent (ended) host slot
    let mut _edges_rejected_mid_slot: u32 = 0;
    let mut _edges_rejected_wrong_polarity: u32 = 0;
    let mut _edges_accepted_in_mirror: u32 = 0;
    let mut _edges_slots_crossed_capped: u32 = 0;
    let mut _max_observed_slots_crossed: u32 = 0;
    let mut _edges_parity_ambiguous_skipped: u32 = 0;
    // Claim-12-aware polarity prediction model (advisory; counted but not yet wired into
    // accept_for_cdr decision). Bridge models FPGA's Claim 12 encoding:
    //   - effective_fpga_tx_bit = data_mode ? FPGA_TX_PATTERN[fpga_tx_pos] : 0
    //   - enclave wire value    = 1 ^ effective_fpga_tx_bit ^ bridge_last_decoded
    //   - host wire value       = bridge's current drive
    // Compare the predicted transition (would happen at this slot boundary? if so, what
    // polarity?) against the observed edge. If new model is right, _edges_claim12_mispredict
    // should be near zero and far less than _edges_rejected_wrong_polarity (the old
    // slotted_oled-tuned check). That signals the new model can safely replace the old.
    // FPGA TX_PATTERN mirrored on the bridge side for the Claim-12 polarity
    // advisory. Must match `TX_PATTERN` in rtl/measure/top_pipe_mirror_xor.v
    // exactly: source string "The quick brown fox jumps over t" (32 ASCII
    // chars, 256 bits). Byte ordering is natural string order; bit 0 within
    // each byte is consumed first by the FPGA rotation (LSB-first per byte).
    const FPGA_TX_PATTERN: [u8; 32] = [
        b'T', b'h', b'e', b' ', b'q', b'u', b'i', b'c',
        b'k', b' ', b'b', b'r', b'o', b'w', b'n', b' ',
        b'f', b'o', b'x', b' ', b'j', b'u', b'm', b'p',
        b's', b' ', b'o', b'v', b'e', b'r', b' ', b't',
    ];
    // Read bit `pos` (0..256) from FPGA_TX_PATTERN, LSB-first per byte.
    let fpga_tx_bit = |pos: u32| -> u8 {
        let p = (pos & 255) as usize;
        (FPGA_TX_PATTERN[p >> 3] >> (p & 7)) & 1
    };
    let mut fpga_data_mode: bool = false;
    let mut fpga_tx_pos: u32 = 0;
    let mut _edges_claim12_mispredict_no_edge_observed: u32 = 0;   // model: no edge; observed: edge
    let mut _edges_claim12_mispredict_wrong_polarity: u32 = 0;     // model: edge with polarity X; observed: opposite
    let mut _edges_claim12_match: u32 = 0;                         // model and observation agree on polarity
    // Raw wire-state-per-slot log: 256 bits captured at the FIRST 256 slot boundaries
    // crossed after mirror_started. Push happens inside the slots_crossed inner loop
    // (next to where wire_at_slot is computed). Linear, not ring — stop logging at 256.
    let mut slot_wire_log: [u8; 32] = [0; 32];
    let mut slot_wire_log_count: u32 = 0;
    // First-256 FPGA-decoded bits: parallel to slot_wire_log but captures the
    // post-XOR fpga_bit (1 ^ last_driven_bit ^ wire_at_slot) at each enclave-slot
    // crossing. Host verifies bit-exact match against the 256-bit FPGA TX pattern
    // across all 256 rotations. Linear, not ring — stop logging at 256.
    let mut fpga_decoded_log: [u8; 32] = [0; 32];
    let mut fpga_decoded_log_count: u32 = 0;
    // Ring buffer of LAST 256 decoded bits (writes at decode_count % 256).
    let mut fpga_decoded_late_log: [u8; 32] = [0; 32];
    // LATE raw own_cyc ring buffer + edge counter for late-vs-early artifact comparison.
    let mut late_raw_own_cyc_log: [u32; 256] = [0; 256];
    let mut late_raw_own_cyc_count: u32 = 0;
    // Raw inter-edge own_cyc_u capture. First 256 edges after mirror_started, untouched
    // by any decode logic. Host plots histogram and computes own_cyc / slot_cyc to verify
    // the slot tracker's model against the actual wire.
    let mut raw_own_cyc_log: [u32; 256] = [0; 256];
    let mut raw_own_cyc_count: u32 = 0;
    let mut raw_own_cyc_slot_cyc: u32 = 0;
    // Deglitch accumulator. Edges with own_cyc < slot_cyc/3 are wire-handoff glitches
    // (FPGA tristate → bridge drive transitions when both sides want the same logic
    // level briefly droop the wire below Schmitt threshold, producing 1-2 spurious
    // edges around the real slot boundary). Glitch own_cyc accumulates here and folds
    // into the next real edge's own_cyc so the slot tracker sees the true boundary
    // interval. `glitches_since_real` counts skipped edges to correct polarity on the
    // next accepted edge (each skipped transition flips wire polarity, so an odd skip
    // count means the next edge polarity is INVERTED from iter parity).
    let mut pending_glitch_cyc: u32 = 0;
    let mut glitches_since_real: u32 = 0;
    let mut _edges_deglitched_skipped: u32 = 0;
    // Phase 2c bridge-side decode (Claim 12 inverse):
    //   wire_state    = bridge's running view of the wire level (1=HIGH, 0=LOW),
    //                   updated AFTER each accepted edge with that edge's polarity
    //   decode_buffer = u32 LSB-first rolling window of FPGA bits decoded so far,
    //                   shift-right + insert-MSB, so bit 0 of the buffer = oldest
    //                   bit and bit 31 = newest. After 32+ enclave slots with FPGA
    //                   in DATA mode, the buffer's value equals a rotation of the
    //                   FPGA's TX_PATTERN.
    //   decode_count  = total enclave-slot crossings that produced a decoded bit.
    // Decode formula: fpga_bit = 1 XOR last_driven_bit XOR wire_at_enclave_slot,
    // where wire_at_enclave_slot is the wire level steady during the enclave slot
    // (= post-boundary edge if the current edge IS the boundary, else == prior
    // wire_state since no edge crossed that boundary).
    let mut wire_state: u8 = initial as u8;
    let mut decode_buffer: u32 = 0;
    let mut decode_count: u32 = 0;

    // Edge cap: convert host-provided poll cap to an edge cap. The polling fast_sync
    // does ~15 sys_cyc per iter ≈ 8 MHz, so 16M iters ≈ 2 sec. At 6 kHz edges, that's
    // ~12k edges; round up to 32k for headroom. Hard cap on top of that. Wall-clock
    // cap (~8 sec) protects against a fully stalled wire.
    const SYNC_MAX_EDGES_PIO: u32 = 1 << 15;
    let max_edges = (max_iter >> 9)
        .min(SYNC_MAX_EDGES_PIO)
        .max(SYNC_ACQ_PER_POLARITY * 4 + 1);
    let wall_cap_us: u64 = 8_000_000;
    let mut iter: u32 = 0; // edge counter (was poll counter)

    // Discard the first FIFO entry — it's "time from SM enable to first edge", which is
    // a partial phase, not a slot width.
    let _ = pio_edge_read_until(wall_cap_us, start);

    // Dual cross-polarity tracker: HIGH width and LOW width estimated separately.
    //
    //   Rising edge   = end of a LOW interval → measures (rising_now - last_falling)
    //                   = LOW width. Updates interval_fp_low.
    //   Falling edge  = end of a HIGH interval → measures (falling_now - last_rising)
    //                   = HIGH width. Updates interval_fp_high.
    //
    // Each acquired interval is ONE slot (not 2 × slot like same-polarity intervals
    // would be). Sum of N intervals = N × slot → SHIFT = log2(N) = log2(256) = 8.
    // This is the structure that exposes RC asymmetry (HIGH ≠ LOW widths) since each
    // tracker locks to its own polarity's actual duration.
    //
    // Variable names retain the "rise"/"fall" suffixes for wire-format compatibility
    // with SyncResult fields, BUT:
    //   acquisition_slot_cyc_rise / interval_fp_rise  → tracks LOW width
    //   acquisition_slot_cyc_fall / interval_fp_fall  → tracks HIGH width
    // The host CLI documents this mapping; renaming would churn the parser.
    const SYNC_ACQ_SHIFT_PER_POLARITY: u32 = 8; // log2(SYNC_ACQ_PER_POLARITY) = log2(256)
    let mut acq_sum_low: u64 = 0;   // LOW widths via rising edges
    let mut acq_sum_high: u64 = 0;  // HIGH widths via falling edges
    let mut acq_rising: u32 = 0;
    let mut acq_falling: u32 = 0;
    let mut acquisition_done: bool = false;
    let mut acquisition_slot_cyc_low: u32 = 0;
    let mut acquisition_slot_cyc_high: u32 = 0;
    let mut interval_fp_low: u32 = 0;
    let mut interval_fp_high: u32 = 0;
    let mut acquisition_iter_count: u32 = 0;
    // Min-tracking bootstrap for random-bit-data acquisition (1-slot threshold).
    // `_skipped_*` are kept as side effects only — surfacing them through SyncResult
    // would extend the wire format; the test we care about is "does lock hold?", not
    // "exactly how many edges got rejected." Wire through if a future debug session
    // needs them.
    let mut min_interval_u: u32 = u32::MAX;
    let mut _multi_slot_skipped_acq: u32 = 0;
    let mut _multi_slot_skipped_track: u32 = 0;

    // PERIOD tracker — the actual frequency reference. interval_fp_period stores the
    // full rise-to-rise cycle (HIGH + LOW width sum) in fixed-point. It's updated
    // only on rising edges, using period = own_cyc + prev_own_cyc (last falling edge's
    // interval). The per-polarity interval_fp_low/_high are still computed for
    // diagnostic / RC asymmetry reporting, but the SM1 clkdiv and lock detector both
    // use interval_fp_period — because it's the right thing to hold during long
    // silence runs. RC asymmetry shows up as noise on per-polarity own_cyc values
    // but cancels in the sum, so period is a much cleaner frequency reference.
    //
    // For 2^12 = 4096-slot silence resilience within ±50% of one slot, the period
    // estimate must be accurate to ≈122 ppm. Per-polarity tracking had ~150,000 ppm
    // drift in practice because RC-noise pulled HIGH and LOW trackers in opposite
    // directions; period tracking eliminates that mode entirely.
    let mut prev_own_cyc: i32 = 0;
    let mut interval_fp_period: u32 = 0;
    let mut acquisition_slot_cyc_period: u32 = 0;
    let mut have_prev_own_cyc: bool = false;
    // See PERIOD_HIST_BINS for shape interpretation. Filled in the period block before
    // the cascade window check so we observe every rising-to-rising sample, including
    // ones the window rejects.
    let mut period_hist: [u32; PERIOD_HIST_BINS] = [0; PERIOD_HIST_BINS];
    let mut period_sum_local: i64 = 0;
    let mut period_sample_count_local: u32 = 0;
    let mut period_min_local: i32 = i32::MAX;
    let mut period_max_local: i32 = i32::MIN;
    // Slow EMA state in scaled-fp form (state ≈ period_now × 2^SYNC_PERIOD_EMA_SLOW_SHIFT
    // at steady state, so visible value = state >> SHIFT). Scaled form avoids the
    // sign-rounding bias that the naive `ema += (sample - ema) >> shift` form has on
    // signed values. Seeded from acquisition's period seed once acquisition completes
    // (see acquisition-done block); 0 until then.
    let mut period_ema_slow_scaled: i64 = 0;
    // Slew-clamp activation counters (diagnostic only, kept local). Each bumps
    // when raw_slew exceeded ±max_slew at that tracker — high rates mean the
    // loop is being protected from glitches; near-zero rates mean clamp is
    // never engaging (loop running smoothly OR clamp is too loose).
    let mut _slew_clamp_hits_period: u32 = 0;
    let mut _slew_clamp_hits_rise: u32 = 0;
    let mut _slew_clamp_hits_fall: u32 = 0;

    let mut rising_total: u32 = 0;
    let mut falling_total: u32 = 0;
    let mut rising_neg_overflow: u32 = 0;
    let mut rising_pos_overflow: u32 = 0;
    let mut falling_neg_overflow: u32 = 0;
    let mut falling_pos_overflow: u32 = 0;
    let mut phase_sum: i64 = 0;
    let mut fall_to_rise_offset_sum: i64 = 0;
    let mut rise_to_fall_offset_sum: i64 = 0;
    let mut rising_hist = [0u16; SYNC_HIST_BINS];
    let mut falling_hist = [0u16; SYNC_HIST_BINS];
    let mut bits_buffer: u64 = 0;
    let mut bits_decoded: u32 = 0;

    // Lock detector: per-polarity counters of consecutive in-threshold edges. The
    // overall `locked` flag goes true when BOTH polarities have crossed the
    // SYNC_LOCK_HOLD_EDGES threshold simultaneously — single-polarity lock isn't enough
    // because the wire isn't truly stable until both HIGH and LOW widths are tracked
    // independently. edges_to_lock is wall-edge count at the moment both crossed.
    // (Legacy diagnostic only — see SYNC_LOCK_THRESHOLD_CYC comment.)
    let mut consec_in_lock_rise: u32 = 0;
    let mut consec_in_lock_fall: u32 = 0;
    let mut consec_out_lock_rise: u32 = 0;
    let mut consec_out_lock_fall: u32 = 0;
    // P-based lock detector — PERIOD EMA of phase_err in SCALED fixed-point. Updated
    // only on rising edges (one period sample per cycle). Stored as ema × 2^shift so
    // the per-edge update never has to divide phase_err. Update: state = state -
    // (state >> shift) + phase_err. Equivalent to y[n] = (1-α)y[n-1] + αx[n] with
    // α = 1/2^shift, but unbiased — a naive `(phase_err - ema) >> shift` update has
    // asymmetric rounding (-∞ for negatives, 0 for positives) that pulls the EMA
    // toward -∞ even with mean phase_err near zero. Visible EMA = scaled >> shift.
    let mut phase_err_ema_period_scaled: i32 = 0;
    // (Legacy per-polarity EMAs kept for diagnostic reporting only — see
    // phase_err_ema_rise/_fall in SyncResult. Not on the lock decision path.)
    let mut phase_err_ema_rise_scaled: i32 = 0;
    let mut phase_err_ema_fall_scaled: i32 = 0;
    let mut rise_locked: bool = false;
    let mut fall_locked: bool = false;
    // PERIOD lock: |period EMA| <= SYNC_LOCK_EMA_THRESHOLD_CYC. The actual lock
    // decision uses this single flag instead of the per-polarity AND, since period
    // is the frequency reference we care about for slot timing.
    let mut period_locked: bool = false;
    let mut locked: bool = false;
    let mut edges_seen: u32 = 0;
    let mut edges_to_lock: u32 = u32::MAX;

    // PIPE comms latch — clear at start of sync, set at end based on final lock
    // state. Reflects the most recent sync run; host polls via the `info` cmd's
    // `pipe` field. A 1 means we held both polarities' lock for 256 consecutive
    // in-threshold edges (SYNC_LOCK_HOLD_EDGES), well inside the 2^12-slot
    // stability margin proven on this wire.
    PIPE_COMMS_LOCKED.store(0, PaOrdering::Relaxed);

    while iter < max_edges {
        let raw = match pio_edge_read_until(wall_cap_us, start) {
            Some(r) => r,
            None => break,
        };
        iter += 1;

        // Mirror mode TX FIFO topup — runs FIRST, before any per-edge filter can
        // `continue` past the bottom-of-loop topup. SM1 consumes 1 OSR bit per
        // host slot (autopull at 32 → ~1 word per 32 host slots ≈ ~5800 words/sec
        // at 348 kHz). If we only push on accepted edges, the filter rejection
        // rate starves SM1's FIFO, SM1 stalls, bridge stops driving, wire goes
        // silent, no more edges, deadlock. Topping up here keeps drive continuous
        // regardless of how many subsequent edges get filtered out.
        // No-op if FIFO is full (pio_tx_try_push returns false).
        if mirror_started {
            let pattern = TX_MIRROR_PATTERN.load(PaOrdering::Relaxed);
            if pio_tx_try_push(pattern) {
                tx_words_consumed = tx_words_consumed.saturating_add(1);
            }
        }

        // Polarity alternation: edge index N (1-based) is rising iff (N XOR initial)
        // is odd. With initial=0 (pin started LOW): edge 1 is rising, edge 2 falling.
        // With initial=1: edge 1 is falling, edge 2 rising. We discarded edge 0 above
        // so iter=1 is the first usable edge.
        let rising = ((iter ^ initial) & 1) == 1;

        // PIO X decrements every 2 sys_clk cycles. Cycle count = 2 * (0xFFFFFFFF - X) = 2 * !X.
        // (Plus a constant +2 sys_clk for the mov-x-!null init that we drop since it
        // cancels out of every phase_err calculation.)
        let own_cyc_u: u32 = (!raw).wrapping_shl(1);
        let own_cyc: i32 = own_cyc_u as i32;

        if !acquisition_done {
            // With random-bit data the wire skips slot transitions at ~50% probability,
            // so inter-edge intervals come at 1, 2, 3, ... × slot. Acquisition needs to
            // pick out the 1-slot ones. Track a running minimum: 1-slot intervals are
            // the smallest cluster, so once we've seen one, `min_interval_u` locks onto
            // ~1 slot and the 1.5×-threshold rejects multi-slot intervals.
            //
            // Bootstrap: the very first intervals run with min = u32::MAX so they all
            // pass the threshold. If any of those were multi-slot, they corrupted the
            // accumulators — when min drops by >2× (a 1-slot interval finally landed),
            // we reset the sums and start fresh.
            if own_cyc_u < min_interval_u {
                if own_cyc_u * 2 < min_interval_u {
                    // Big drop. Previous accumulations were on the wrong slot; restart.
                    acq_sum_low = 0;
                    acq_sum_high = 0;
                    acq_rising = 0;
                    acq_falling = 0;
                }
                min_interval_u = own_cyc_u;
            }
            let threshold_u = min_interval_u.saturating_add(min_interval_u / 2);

            if own_cyc_u <= threshold_u {
                if rising {
                    if acq_rising < SYNC_ACQ_PER_POLARITY {
                        acq_sum_low += own_cyc_u as u64;
                        acq_rising += 1;
                    }
                    rising_total += 1;
                } else {
                    if acq_falling < SYNC_ACQ_PER_POLARITY {
                        acq_sum_high += own_cyc_u as u64;
                        acq_falling += 1;
                    }
                    falling_total += 1;
                }
            } else {
                _multi_slot_skipped_acq += 1;
            }

            if acq_rising >= SYNC_ACQ_PER_POLARITY && acq_falling >= SYNC_ACQ_PER_POLARITY {
                // Compute the fp-domain seeds DIRECTLY from the accumulator without
                // truncating to integer cyc first — `(sum << frac_bits) >> shift`
                // preserves frac_bits-worth of fractional precision in the seed.
                // The old `(sum >> shift) << frac_bits` form truncated to whole cyc,
                // costing ±0.5 cyc of acquisition error per polarity (±175 ppm on a
                // ~5730 cyc seed) — enough to blow the 61 ppm silence budget on its
                // own, before the P-loop's steady-state noise even contributes.
                interval_fp_low = (acq_sum_low << frac_bits >> SYNC_ACQ_SHIFT_PER_POLARITY) as u32;
                interval_fp_high = (acq_sum_high << frac_bits >> SYNC_ACQ_SHIFT_PER_POLARITY) as u32;
                // Integer-cyc seeds kept for the ±30% sanity-window math (which
                // doesn't need sub-cyc precision).
                acquisition_slot_cyc_low = (interval_fp_low >> frac_bits) as u32;
                acquisition_slot_cyc_high = (interval_fp_high >> frac_bits) as u32;
                // PERIOD seed = LOW seed + HIGH seed in fp, then derive integer.
                interval_fp_period = interval_fp_low.wrapping_add(interval_fp_high);
                acquisition_slot_cyc_period = (interval_fp_period >> frac_bits) as u32;
                // Seed the slow EMA from the acquisition seed so it's usable
                // immediately. Without this it'd take ~1024 samples (~47 ms) starting
                // from 0 to converge — and silence might happen sooner.
                // Scaled-form state = period × 2^SHIFT.
                period_ema_slow_scaled = (acquisition_slot_cyc_period as i64)
                    << SYNC_PERIOD_EMA_SLOW_SHIFT;
                acquisition_done = true;
                acquisition_iter_count = iter;
                if mirror_mode {
                    // Arm: SM1 starts on the NEXT rising edge (= start of an FPGA
                    // enclave slot per top_pipe_slotted_oled.v:169-170).
                    mirror_armed = true;
                }
            }
            continue;
        }

        // Mirror mode: start SM1 on the first rising edge after acquisition. The
        // rising edge marks the start of an FPGA enclave slot; SM1's first
        // instruction is `nop side 0` (PINDIRS=0, tristate during enclave). Use the
        // AVERAGE of interval_fp_low and interval_fp_high so SM1 sits at the
        // symmetric midpoint of the RC-asymmetric FPGA slot pair — minimizes drift
        // either direction before the per-edge correction loop has time to apply.
        if mirror_armed && !mirror_started && rising {
            // SM1 has 2 instructions per FPGA cycle (nop + out pins), so one PIO
            // instruction = one wire slot = period / 2 sys_clk. Drive clkdiv from the
            // PERIOD tracker (rise-to-rise, drift-stable) rather than per-polarity
            // (RC-asymmetry-noisy). Initial SM1 enable uses the period seed.
            let interval_fp_slot = interval_fp_period >> 1;
            let (ci, cf) = interval_fp_to_clkdiv(interval_fp_slot, frac_bits);
            pio_tx_mirror_start(ci, cf);
            // Pre-fill FIFO with up to 8 copies of the TX pattern (fjoin_tx=true gives
            // 8-deep FIFO). Bridge SM1 consumes 1 OSR bit per host slot via autopull at
            // 32 → 1 word per 32 host slots ≈ 1 word per 90 µs at 348 kHz. 8 words =
            // 256 host slots ≈ 730 µs of headroom — well above CPU loop latency, so
            // SM1 keeps drive going even if the filter rejects many consecutive edges.
            for _ in 0..8 {
                if pio_tx_try_push(tx_pattern) {
                    tx_words_consumed = tx_words_consumed.saturating_add(1);
                } else {
                    break;
                }
            }
            mirror_started = true;
            // Reset slot-tracking state. This rising edge IS the anchor — cumulative
            // time begins now; slot_phase is in enclave because SM1's first instruction
            // (nop side 0) executes there. The anchor edge itself is a reference, not a
            // data point — skip CDR processing for it.
            cumulative_cyc_since_anchor = 0;
            slots_since_anchor = 0;
            slot_phase = 0;
            tx_shift_reg = TX_MIRROR_PATTERN.load(PaOrdering::Relaxed);
            tx_bits_remaining = 32;
            current_tx_bit = 0;
            last_driven_bit = 0;
            fpga_data_mode = false;
            fpga_tx_pos = 0;
            slot_wire_log = [0; 32];
            slot_wire_log_count = 0;
            fpga_decoded_log = [0; 32];
            fpga_decoded_log_count = 0;
            fpga_decoded_late_log = [0; 32];
            late_raw_own_cyc_log = [0; 256];
            late_raw_own_cyc_count = 0;
            raw_own_cyc_log = [0; 256];
            raw_own_cyc_count = 0;
            raw_own_cyc_slot_cyc = ((interval_fp_period as u64 >> 1) >> frac_bits) as u32;
            // Count edge for stats but skip CDR update — the anchor is a phase reference,
            // not a slot-duration measurement. Falls through to rising_total/falling_total
            // increment below.
            if rising { rising_total += 1 } else { falling_total += 1 };
            continue;
        }

        // Mirror-mode slot-phase tracker: advance through any slot boundaries this
        // edge implies, updating slot_phase + TX shift register. Then check whether
        // the edge polarity matches what we expect at the new slot phase. Rejection
        // categories:
        //   1. Edge fell mid-slot (cumulative not near a slot boundary) — likely an
        //      SM1 tristate-glitch from CDR drift. Reject to prevent feedback.
        //   2. Edge polarity doesn't match predicted (e.g., rising edge during host
        //      slot when bridge drives 1, or falling edge during enclave with
        //      last_driven_bit=1 — neither should produce a transition).
        let mut accept_for_cdr = true;
        // Track polarity. iter is incremented per edge, but glitches are skipped from
        // slot tracker view — every skipped transition flips physical wire polarity,
        // so we compensate the iter-derived polarity by XORing with the parity of
        // glitches_since_real on the eventual accepted edge.
        let mut rising = rising;
        if mirror_started {
            // Raw capture: first 256 own_cyc_u values after mirror_started, BEFORE any
            // slot tracker math. This is the ground truth — if these values don't form
            // tight clusters at N*slot_cyc, the decode math can't work, no matter how
            // clever the filter.
            if raw_own_cyc_count < 256 {
                raw_own_cyc_log[raw_own_cyc_count as usize] = own_cyc_u;
                raw_own_cyc_count += 1;
            }
            // LATE raw own_cyc ring buffer: writes at late_count % 256, overwrites oldest.
            // At end of run, ring holds the most recent 256 edges' raw own_cyc values.
            let late_ring_pos = (late_raw_own_cyc_count & 255) as usize;
            late_raw_own_cyc_log[late_ring_pos] = own_cyc_u;
            late_raw_own_cyc_count = late_raw_own_cyc_count.wrapping_add(1);
            // Deglitch: edges arriving < slot_cyc/3 after the previous edge are wire
            // handoff/ringing artifacts. Accumulate their own_cyc and fold into the
            // next REAL edge. See raw_own_cyc histogram analysis: 0.25-slot splits +
            // sub-100ns slivers exist even with Schmitt enabled because the wire
            // droops > 200mV during FPGA-tristate↔bridge-drive handoff when both
            // sides want HIGH.
            let slot_cyc_for_filter = (interval_fp_period as u64 >> 1) >> frac_bits;
            if slot_cyc_for_filter >= 8 {
                // Threshold = slot_cyc/2. Any edge arriving < half a slot after the
                // previous is a glitch (real edges are >=1 slot apart). Tightens from
                // previous slot_cyc/3 which let through the wider 0.32-0.5-slot splits.
                let glitch_threshold = (slot_cyc_for_filter as u32) / 2;
                if own_cyc_u < glitch_threshold {
                    pending_glitch_cyc = pending_glitch_cyc.saturating_add(own_cyc_u);
                    glitches_since_real = glitches_since_real.wrapping_add(1);
                    _edges_deglitched_skipped =
                        _edges_deglitched_skipped.saturating_add(1);
                    // Skip the rest of the per-edge processing — no slot tracker
                    // update, no wire log, no decode. Polarity correction will apply
                    // on the next accepted edge.
                    continue;
                }
            }
            // Real edge: fold accumulated glitch cyc into own_cyc. Polarity needs NO
            // correction — `rising` was derived from `iter`, which incremented for
            // every glitch (we just skipped the slot tracker work). So iter's parity
            // already matches the physical wire polarity at this edge.
            let combined_own_cyc_u = own_cyc_u.saturating_add(pending_glitch_cyc);
            pending_glitch_cyc = 0;
            glitches_since_real = 0;
            // SHADOW own_cyc_u and own_cyc with the combined value for the rest of
            // the loop. Use `let` to rebind — slot tracker math below operates on
            // the corrected interval.
            let own_cyc_u = combined_own_cyc_u;
            let own_cyc: i32 = own_cyc_u as i32;
            cumulative_cyc_since_anchor =
                cumulative_cyc_since_anchor.wrapping_add(own_cyc_u as u64);
            // Slot duration in sys_clk cycles. Use the PERIOD tracker (rise-to-rise =
            // HIGH + LOW) divided by 2 — the single drift-stable frequency reference.
            // RC asymmetry (HIGH ≠ LOW) is folded into the average and doesn't bias
            // the slot-phase counter.
            let slot_cyc = (interval_fp_period as u64 >> 1) >> frac_bits;
            if slot_cyc < 8 {
                accept_for_cdr = false;
            } else {
                // Architecture A: derive slot count from CUMULATIVE TIME, not per-edge.
                // The slot count is the integer part of (cumulative / slot_cyc), rounded
                // to nearest. Free-running RX slot clock; drift is bounded by slot_cyc
                // accuracy, NOT by per-edge phase noise.
                //
                // PHASE SNAP: rising edges MUST occur at slot boundaries (a wire LOW→HIGH
                // transition can only happen at a slot boundary by protocol design). So
                // if this is a rising edge, snap cumulative_cyc_since_anchor to the nearest
                // expected boundary time. Eats any accumulated drift in one step. Only
                // applied when the phase error is small (< slot_cyc/4) — larger errors
                // indicate the edge isn't really a slot boundary (e.g. unanchored startup,
                // or a glitch that survived deglitch).
                //
                // Combined with NO cap on slots_crossed: silent gaps (all-1s or all-0s
                // from FPGA) can be arbitrarily long. When an edge finally arrives, it
                // gives us the post-gap wire state, and the per-slot decode loop fills in
                // all intermediate slots with the pre-gap wire state. Cap = u32::MAX/2
                // just for sanity (real workloads are bounded by clock-watchdog limits).
                let target_slot_idx = (cumulative_cyc_since_anchor + slot_cyc / 2) / slot_cyc;
                // Phase snap (tolerance-bounded): edges arriving WITHIN slot_cyc/4 of an
                // expected slot boundary are treated as real boundary events — snap
                // cumulative to the boundary time, eating accumulated drift. Edges further
                // off than slot_cyc/4 are probably NOT boundary events (glitch survivors,
                // misanchored startup, etc.) — leave cumulative alone for those.
                let nearest_boundary_time = target_slot_idx.saturating_mul(slot_cyc);
                let phase_err = (cumulative_cyc_since_anchor as i64)
                    - (nearest_boundary_time as i64);
                if phase_err.unsigned_abs() < slot_cyc / 4 {
                    cumulative_cyc_since_anchor = nearest_boundary_time;
                }
                let raw_slots_crossed = target_slot_idx.saturating_sub(slots_since_anchor as u64);
                let slots_crossed = raw_slots_crossed.min(u32::MAX as u64 / 2);
                if raw_slots_crossed > _max_observed_slots_crossed as u64 {
                    _max_observed_slots_crossed = raw_slots_crossed.min(u32::MAX as u64) as u32;
                }
                let new_slots = slots_since_anchor.wrapping_add(slots_crossed);
                // Wire state for slots crossed by this edge: all earlier boundary
                // crossings share the PRIOR wire_state (no edge happened at those
                // boundaries — wire stayed put); only the LAST crossing aligns with
                // THIS edge, so that slot's wire = post-edge state. `wire_state` is
                // updated unconditionally at end of per-edge loop (after the filter)
                // so acquisition-phase edges keep it fresh too — referencing the
                // PRE-update value inside the loop preserves the "older slot saw
                // prior wire state" invariant.
                let new_wire_state: u8 = if rising { 1 } else { 0 };
                for slot_idx in 0..slots_crossed {
                    slot_phase ^= 1;
                    let is_boundary_for_this_edge = slot_idx + 1 == slots_crossed;
                    let wire_at_slot = if is_boundary_for_this_edge {
                        new_wire_state
                    } else {
                        wire_state
                    };
                    // Log raw wire-state for the first 256 slot boundaries (diagnostic).
                    if slot_wire_log_count < 256 {
                        let byte_idx = (slot_wire_log_count >> 3) as usize;
                        let bit_in_byte = slot_wire_log_count & 7;
                        if wire_at_slot != 0 {
                            slot_wire_log[byte_idx] |= 1 << bit_in_byte;
                        }
                        slot_wire_log_count += 1;
                    }
                    if slot_phase == 1 {
                        // Entering host slot: bridge starts driving the next bit. Mirror
                        // SM1's OSR consumption (1 bit per host slot, LSB-first).
                        current_tx_bit = (tx_shift_reg & 1) as u8;
                        tx_shift_reg >>= 1;
                        tx_bits_remaining = tx_bits_remaining.saturating_sub(1);
                        if tx_bits_remaining == 0 {
                            tx_shift_reg = TX_MIRROR_PATTERN.load(PaOrdering::Relaxed);
                            tx_bits_remaining = 32;
                        }
                        // Piezo H-bridge update: in-phase = current_tx_bit, anti-phase
                        // = its inverse. Held through next enclave slot (no update there)
                        // so audio is continuous.
                        let sio = embassy_rp::pac::SIO;
                        if current_tx_bit != 0 {
                            sio.gpio_out(0).value_set().write_value(1 << PIEZO_TX_P_GPIO);
                            sio.gpio_out(0).value_clr().write_value(1 << PIEZO_TX_N_GPIO);
                        } else {
                            sio.gpio_out(0).value_clr().write_value(1 << PIEZO_TX_P_GPIO);
                            sio.gpio_out(0).value_set().write_value(1 << PIEZO_TX_N_GPIO);
                        }
                    } else {
                        // Entering enclave: the bit bridge WAS driving in the prior host
                        // slot is now `last_driven_bit` (used by both the polarity-filter
                        // below and our decode below).
                        last_driven_bit = current_tx_bit;
                        // FPGA model: rotation happens AT host→enclave transition (per
                        // top_pipe_mirror_xor.v: rotate when prev_slot_owner==1 &&
                        // slot_owner==0). Advance our model of the FPGA's TX bit position.
                        fpga_tx_pos = fpga_tx_pos.wrapping_add(1) & 255;
                        // FPGA model: if bridge drove 1 in the just-ended host slot, FPGA
                        // sampled wire_in==1 at slot_phase==2 of that host slot and latched
                        // data_mode<=1. From the FPGA Verilog the new data_mode is in
                        // effect starting THIS enclave slot we're entering now.
                        if last_driven_bit == 1 {
                            fpga_data_mode = true;
                        }
                        // Phase 2c decode: derive the FPGA's TX bit for this enclave slot
                        // from observed wire state. enclave_drive = 1 ^ fpga_bit ^
                        // bridge_last_decoded; bridge knows it drove `last_driven_bit` in
                        // the prior host slot (= what FPGA decoded). Invert:
                        let fpga_bit: u8 = 1 ^ last_driven_bit ^ wire_at_slot;
                        decode_buffer = (decode_buffer >> 1)
                            | (((fpga_bit & 1) as u32) << 31);
                        decode_count = decode_count.saturating_add(1);
                        // Capture first 256 decoded bits for bit-exact verify against
                        // the 256-bit FPGA TX_PATTERN. Linear (not ring): freezes at
                        // 256 — same convention as slot_wire_log.
                        if fpga_decoded_log_count < 256 {
                            let byte_idx = (fpga_decoded_log_count >> 3) as usize;
                            let bit_in_byte = fpga_decoded_log_count & 7;
                            if fpga_bit != 0 {
                                fpga_decoded_log[byte_idx] |= 1 << bit_in_byte;
                            }
                            fpga_decoded_log_count += 1;
                        }
                        // Ring buffer of last 256 decoded bits — writes at decode_count
                        // % 256. Overwrites the oldest bit so the buffer always holds
                        // the most recent 256. decode_count was incremented BEFORE this
                        // capture, so the ring position is (decode_count - 1) % 256.
                        let ring_pos = ((decode_count.wrapping_sub(1)) & 255) as usize;
                        let late_byte_idx = ring_pos >> 3;
                        let late_bit_in_byte = (ring_pos & 7) as u32;
                        // Clear-then-set so old bits get overwritten cleanly.
                        fpga_decoded_late_log[late_byte_idx] &=
                            !(1u8 << late_bit_in_byte);
                        if fpga_bit != 0 {
                            fpga_decoded_late_log[late_byte_idx] |=
                                1u8 << late_bit_in_byte;
                        }
                    }
                }
                slots_since_anchor = new_slots;

                // How close is the edge to the nearest slot boundary? Edges near a
                // boundary represent legitimate slot transitions; edges in the middle
                // of a slot are spurious (SM1 tristate-glitches from drift).
                // Use per-edge own_cyc (rise-to-rise interval) modulo slot_cyc, NOT
                // cumulative-since-anchor — cumulative integrates ppm-level CDR error
                // indefinitely, eventually drifting off every real slot boundary and
                // cascade-rejecting all real edges (which suppresses the re-anchor that
                // would restore alignment). Per-edge modulo is a fresh measurement each
                // edge: 1-slot edge → own_cyc ≈ slot_cyc → ≈0; N-slot sparse edge →
                // own_cyc ≈ N*slot_cyc → ≈0; mid-slot glitch → ≈ slot_cyc/2.
                let pos_in_slot = (own_cyc_u as u64) % slot_cyc;
                let near_boundary = pos_in_slot < slot_cyc / 4 || pos_in_slot > 3 * slot_cyc / 4;
                if slots_crossed == 0 || !near_boundary {
                    _edges_rejected_mid_slot += 1;
                    accept_for_cdr = false;
                } else {
                    // OLD polarity prediction (slotted_oled-stub-tuned). Still ADVISORY
                    // (counted but not gating acceptance) so we can compare against the
                    // NEW Claim-12-aware prediction below.
                    let expect_rising_here = slot_phase == 0 && last_driven_bit == 0;
                    let expect_falling_here = slot_phase == 1 && current_tx_bit == 0;
                    let old_polarity_ok = (rising && expect_rising_here)
                                       || (!rising && expect_falling_here);
                    if !old_polarity_ok {
                        _edges_rejected_wrong_polarity += 1;
                    }

                    // NEW Claim-12-aware polarity prediction. ADVISORY for now: count how
                    // often it agrees with observation. If agreement rate is high, we
                    // know the model is right and can wire it into accept_for_cdr next.
                    //
                    // Two boundary kinds:
                    //   host→enclave (slot_phase=0 here): wire transitions if FPGA's
                    //     effective bit at this enclave == 0. Polarity = rising iff
                    //     last_driven_bit==0 (bridge drove 0 → enclave brings wire up to 1).
                    //   enclave→host (slot_phase=1 here): enclave value was
                    //     e = 1 ^ fpga_prev ^ last_driven_bit; host value = current_tx_bit.
                    //     Edge iff e != current_tx_bit; rising iff e==0 (host went low→high).
                    let (claim12_expect_edge, claim12_expect_rising) = if slot_phase == 0 {
                        let f_new: u8 = if fpga_data_mode {
                            fpga_tx_bit(fpga_tx_pos)
                        } else { 0 };
                        if f_new == 0 {
                            (true, last_driven_bit == 0)
                        } else {
                            (false, false)
                        }
                    } else {
                        // For slot_phase==1, fpga_tx_pos points to the bit FPGA used in the
                        // enclave just ended (rotation happens on host→enclave, not
                        // enclave→host).
                        let f_prev: u8 = if fpga_data_mode {
                            fpga_tx_bit(fpga_tx_pos)
                        } else { 0 };
                        let e = 1 ^ f_prev ^ last_driven_bit;
                        let b = current_tx_bit;
                        if e != b {
                            (true, e == 0)
                        } else {
                            (false, false)
                        }
                    };
                    if claim12_expect_edge {
                        if rising == claim12_expect_rising {
                            _edges_claim12_match += 1;
                        } else {
                            _edges_claim12_mispredict_wrong_polarity += 1;
                        }
                    } else {
                        _edges_claim12_mispredict_no_edge_observed += 1;
                    }

                    _edges_accepted_in_mirror += 1;
                }
            }
        }

        // wire_state update happens UNCONDITIONALLY on every edge, including during
        // acquisition (mirror_started=false) and including filter-rejected edges. The
        // wire physically transitioned at this edge regardless of whether we accept
        // it for CDR — failing to update would leave a stale value that poisons the
        // Phase 2c decode at the next accepted enclave-slot crossing.
        wire_state = if rising { 1 } else { 0 };

        // Mirror-mode FULL SKIP for edges the slot-phase + TX-bit filter rejected:
        // bridge-driven edges during host slots when we drive HIGH (no transition
        // expected), or unexpected edges during enclave slots (line should be HIGH
        // from FPGA throughout). These edges aren't FPGA-anchored timing references
        // — feeding them through cascade / slew / EMA / bit decoder poisons every
        // downstream measurement. Drop completely; count for diagnostic only.
        if mirror_started && !accept_for_cdr {
            if rising { rising_total += 1 } else { falling_total += 1 };
            continue;
        }

        // PERIOD tracker (rising-to-rising). own_cyc is the cross-polarity interval
        // since previous edge. The PREVIOUS edge before THIS rising was a falling, and
        // before THAT falling was the previous rising. So period = own_cyc (this rising)
        // + prev_own_cyc (the falling between). Falling edges don't update the period
        // tracker — they just record their own_cyc for the next rising to consume.
        if rising && have_prev_own_cyc {
            let period_now = own_cyc.wrapping_add(prev_own_cyc);
            // Diagnostic histogram, sampled BEFORE the cascade window check.
            // bin = period_now * 8 / seed, clamped at PERIOD_HIST_BINS-1 (= overflow).
            // Bin 8 = seed, bin 4 = seed/2 (missed-edge suspect), bin 16 = ≥2×seed.
            // NOTE: we accept ALL period_now values (including negative — indicating a
            // huge own_cyc cast to negative i32) into sum/count/min/max so the host can
            // cross-check `period_sum × 8 ns ≟ wall-time`. The binning step itself still
            // gates on period_now >= 0 because the bin math doesn't accept negatives.
            period_sum_local = period_sum_local.wrapping_add(period_now as i64);
            period_sample_count_local = period_sample_count_local.saturating_add(1);
            if period_now < period_min_local { period_min_local = period_now; }
            if period_now > period_max_local { period_max_local = period_now; }
            // Slow EMA on period_now gated to single-period samples — see the
            // n_periods==1 update below in the cascade block. For LFSR-style
            // multi-slot data, raw period_now averages to N× true period (where N
            // depends on the slot-gap distribution); folding by n_periods would
            // need a division per edge, so we just skip those samples and rely on
            // the n=1 ones to drive the EMA.
            let seed_cyc = acquisition_slot_cyc_period;
            if seed_cyc > 0 && period_now >= 0 {
                let bin = ((period_now as u64 * 8) / seed_cyc as u64) as usize;
                let bin = bin.min(PERIOD_HIST_BINS - 1);
                period_hist[bin] = period_hist[bin].saturating_add(1);
            }
            let period_slot = (interval_fp_period >> frac_bits) as i32;
            if period_slot >= 16 {
                // Narrow-window multi-N CDR (replaces the old cascade_mode windowing).
                // Reference the SEED period (acquisition value, fixed) for the integer-N
                // matching — NOT the live `period_slot`. Referencing the live value lets
                // the N=N+1 fixed points drift with the loop: if slot_cyc has slewed to
                // 1/N of true, period_now looks like a perfect N×current_slot_cyc match
                // → CDR locks to the wrong harmonic (the cascade-promotion bug that
                // plagued cascade_mode=1). Seed is fixed, so only the TRUE multiple
                // matches; everything else gets rejected. Tight ±2% window accepts
                // legitimate ring-osc drift (<300 ppm over a 1-sec test = 1.7 cyc on a
                // 5768-cyc seed; 2% window = ~115 cyc, 68× headroom for real drift)
                // but rejects anything off by a slot or more.
                //
                // Coverage N=1..8: rise-to-rise = 1 FPGA period for AAAA-on-both-sides,
                // 2 periods for IDLE+AAAA (the most-common-edge case), up to 8 periods
                // for sparse data. cascade_mode parameter is now effectively unused —
                // this approach subsumes both cascade_mode=0 (forced N=1) and
                // cascade_mode=1 (try N=1..4 with wide windows) with stricter matching.
                let _ = cascade_mode;  // intentionally ignored
                // NB: `acquisition_slot_cyc_period` is poorly named — it's already a
                // full PERIOD (rise-to-rise = LOW seed + HIGH seed in cyc), not a slot.
                // No ×2 needed.
                let seed_period_cyc = acquisition_slot_cyc_period as i32;
                let narrow_window = (seed_period_cyc / 50).max(4);
                let n_periods: i32 = if seed_period_cyc > 0 {
                    ((period_now + seed_period_cyc / 2) / seed_period_cyc).max(1).min(8)
                } else { 0 };
                let expected_seed = n_periods * seed_period_cyc;
                let seed_phase_err = period_now - expected_seed;
                let accept = n_periods >= 1 && seed_phase_err.abs() < narrow_window;
                if !accept {
                    _multi_slot_skipped_track += 1;
                }
                if accept {
                    // Phase error for slewing the LIVE interval_fp_period: use the live
                    // period_slot (not seed) so we track real drift toward the live value.
                    // Acceptance was already gated by the seed-anchored check above.
                    let expected = n_periods * period_slot;
                    let phase_err_period = period_now - expected;
                    let shift = frac_bits as i32 - p_shift as i32;
                    let raw_slew = if shift >= 0 {
                        phase_err_period << shift
                    } else {
                        phase_err_period >> -shift
                    };
                    // Per-edge slew magnitude clamp (see SYNC_SLEW_CLAMP_DENOM doc).
                    // Prevents a single misclassified or glitch edge from yanking
                    // interval_fp_period to the ±30% sanity floor where it would
                    // get pinned by the slot-phase filter's wrong-fixed-point lock.
                    let seed_fp = (acquisition_slot_cyc_period as u64) << frac_bits;
                    let max_slew = (seed_fp / SYNC_SLEW_CLAMP_DENOM as u64).min(i32::MAX as u64) as i32;
                    let slew = raw_slew.clamp(-max_slew, max_slew);
                    if raw_slew != slew { _slew_clamp_hits_period += 1; }
                    let new_fp = interval_fp_period.wrapping_add_signed(slew);
                    // Sanity window: keep period within ±30% of acquisition seed.
                    let min_fp = ((seed_fp * 7 / 10) as u32).max(1u32 << frac_bits);
                    let max_fp = (seed_fp * 13 / 10).min(u32::MAX as u64) as u32;
                    if new_fp >= min_fp && new_fp <= max_fp {
                        interval_fp_period = new_fp;
                    }
                    // PERIOD P-EMA lock detector — scaled fixed-point form.
                    phase_err_ema_period_scaled = phase_err_ema_period_scaled
                        .wrapping_sub(phase_err_ema_period_scaled >> SYNC_LOCK_EMA_SHIFT)
                        .wrapping_add(phase_err_period);
                    let ema_period = phase_err_ema_period_scaled >> SYNC_LOCK_EMA_SHIFT;
                    period_locked = ema_period.abs() <= SYNC_LOCK_EMA_THRESHOLD_CYC;
                    // Slow EMA: only fed by n_periods==1 samples so multi-slot LFSR
                    // gaps don't bias the silence-prediction estimate up by N×. For
                    // clean-toggle / mirror-XOR (cascade_mode=0) this fires on every
                    // accepted edge; for LFSR (cascade_mode=1) it fires on roughly
                    // half the edges (the ones where the next transition came in the
                    // very next slot — no gap).
                    if n_periods == 1 {
                        period_ema_slow_scaled = period_ema_slow_scaled
                            .wrapping_sub(period_ema_slow_scaled >> SYNC_PERIOD_EMA_SLOW_SHIFT)
                            .wrapping_add(period_now as i64);
                    }
                    // TIMING RE-ANCHOR on accepted period sample. An accepted period
                    // sample is a rising edge that the narrow-window check just confirmed
                    // is at an integer N * seed_period from the last accepted rising —
                    // i.e., bridge KNOWS this edge sits at a true FPGA slot boundary.
                    // Reset the timing tracker (cumulative_cyc + slots_since_anchor) to
                    // 0 so the per-edge slot_phase calculation only has to extrapolate
                    // over the ≤8 slots until the next accepted period sample, not over
                    // the entire run. Bounds accumulated arithmetic drift.
                    //
                    // Slot_phase parity RE-SYNC from absolute time. Per-edge slots_crossed
                    // is fragile: edges with own_cyc near (N + 0.5) * slot_cyc round to N
                    // or N+1 with ~50/50 chance from sub-cycle noise, randomly flipping
                    // slot_phase parity. Once flipped, the per-edge tracker can't recover
                    // (it just keeps advancing from the wrong parity). The fix: at every
                    // accepted period sample (which we know is a clean integer-multiple-of
                    // -slot_cyc edge), recompute slot_phase from total_cyc_since_mirror_start
                    // / slot_cyc % 2. Absolute-time derivation is immune to per-edge errors
                    // (drift is bounded by ppm-level CDR error × time-since-start, which is
                    // well under one slot for reasonable runs).
                    //
                    // The first anchor (mirror_started) declares slot_phase = 0 (enclave-
                    // entry, since SM1's first instruction is a `nop side 0` that exits
                    // host-driving). All subsequent slot_phase values are referenced to
                    // that origin.
                    if mirror_started {
                        cumulative_cyc_since_anchor = 0;
                        slots_since_anchor = 0;
                    }
                }
            }
        }
        prev_own_cyc = own_cyc;
        have_prev_own_cyc = true;

        // Tracking phase. Comparison cascade picks n_slots ∈ {1, 2, 3, 4}: the wire's
        // mirror-XOR-encoded data can leave 1+ slot boundaries without a transition, so
        // own_cyc may be N × slot rather than always 1 × slot. We compute phase_err on
        // the single-slot residual: phase_err = own_cyc - n_slots × slot.
        let interval_fp_self = if rising { interval_fp_low } else { interval_fp_high };
        let slot = (interval_fp_self >> frac_bits) as i32;
        if slot < 8 {
            if rising { rising_pos_overflow += 1 } else { falling_pos_overflow += 1 };
            if rising { rising_total += 1 } else { falling_total += 1 };
            continue;
        }
        let half_slot = slot / 2;
        // n_slots cascade — modal. cascade_mode=1 enables the historical n=1..4 cascade
        // for data with real multi-slot gaps (LFSR / random); cascade_mode=0 forces n=1
        // for single-interval data (clean toggle / mirror-XOR) and rejects any edge that
        // isn't in a symmetric window [slot-half_slot, slot+half_slot] around the slot
        // estimate — "in space, drop". The cascade-promotion runaway that plagued
        // clean-toggle data is structurally impossible in cascade_mode=0, AND sub-slot
        // glitches (RC ringing, sub-threshold transitions) don't get folded as
        // legitimate n=1 edges that would pull slot estimate downward toward the noise.
        let n_slots: i32 = if cascade_mode == 0 {
            if own_cyc >= slot - half_slot && own_cyc < slot + half_slot {
                1
            } else {
                _multi_slot_skipped_track += 1;
                if rising { rising_total += 1 } else { falling_total += 1 };
                continue;
            }
        } else if own_cyc < slot + half_slot { 1 }
                           else if own_cyc < 2 * slot + half_slot { 2 }
                           else if own_cyc < 3 * slot + half_slot { 3 }
                           else if own_cyc < 4 * slot + half_slot { 4 }
                           else {
                               // Interval too long to fold into n ≤ 4 — could be a
                               // glitch, a stalled wire, or noise on the line. Skip
                               // updating the P controller but still count it for
                               // diagnostics.
                               _multi_slot_skipped_track += 1;
                               if rising { rising_total += 1 } else { falling_total += 1 };
                               continue;
                           };
        let expected = n_slots * slot;
        let phase_err = own_cyc - expected;

        // No gap compensation. The "naive" per-edge slew of `phase_err << shift` is
        // actually gain-matched in continuous time: a multi-slot interval gives N×
        // phase_err per observation, but observations come once per N slots, so the
        // per-slot tracking rate is constant regardless of N. Dividing by N (whether
        // exactly or via nearest-power-of-2) reduces multi-slot contribution to
        // per-slot rate and the slot estimate lags more. Empirically: std on random
        // data jumped 40% and lock window shut. The naive slew is correct.
        //
        // TODO: TX gating. Once the bridge drives the wire too, edges caused by our own
        // TX should NOT feed the P controller (they're zero-information about FPGA slot
        // timing, and risk positive-feedback drift). Filter at this point — accept the
        // edge only if it doesn't coincide with a known own-TX transition.
        let shift = frac_bits as i32 - p_shift as i32;
        let raw_slew = if shift >= 0 { phase_err << shift } else { phase_err >> -shift };
        // Per-edge slew magnitude clamp (per-polarity). Uses the seed of the
        // current polarity (low for rising, high for falling) as the reference,
        // matching the per-polarity ±30% sanity window below. See
        // SYNC_SLEW_CLAMP_DENOM doc for rationale.
        let polarity_seed_cyc = if rising { acquisition_slot_cyc_low } else { acquisition_slot_cyc_high };
        let polarity_seed_fp = (polarity_seed_cyc as u64) << frac_bits;
        let max_slew = (polarity_seed_fp / SYNC_SLEW_CLAMP_DENOM as u64).min(i32::MAX as u64) as i32;
        let slew = raw_slew.clamp(-max_slew, max_slew);
        if raw_slew != slew {
            if rising { _slew_clamp_hits_rise += 1 } else { _slew_clamp_hits_fall += 1 };
        }
        let new_fp = interval_fp_self.wrapping_add_signed(slew);
        // Only feed CDR with edges that passed the slot-phase + TX-bit filter.
        // accept_for_cdr is always true outside mirror mode.
        if accept_for_cdr {
            // Per-polarity sanity window: if the proposed new interval_fp would land
            // outside ±30% of the acquisition seed, the edge is a glitch / cosmic ray
            // / spurious transient — DROP it entirely, no slew, no count toward CDR.
            // Clamping toward the rail would let the bogus direction leak into the
            // integrator's state and bias subsequent lock decisions. Skipping keeps
            // the loop pure: only plausible edges contribute to slot estimate.
            // Ring-osc drift is well under 1000 ppm/sec so ±30% is generous slack for
            // legitimate frequency wander while structurally rejecting noise.
            let target_fp_mut: &mut u32 = if rising {
                &mut interval_fp_low
            } else {
                &mut interval_fp_high
            };
            let seed_fp = polarity_seed_fp;
            let min_fp = ((seed_fp * 7 / 10) as u32).max(1u32 << frac_bits);
            let max_fp = (seed_fp * 13 / 10).min(u32::MAX as u64) as u32;
            if new_fp >= min_fp && new_fp <= max_fp {
                *target_fp_mut = new_fp;
            } else {
                // Edge "in space" — drop it FULLY. Bump the skip counter and
                // total counter for diagnostic, then `continue` so neither
                // interval_fp nor the lock-detector EMA gets touched by a glitch.
                // (Letting a -200 cyc phase_err shift the EMA by -0.8 cyc each
                // time keeps the lock detector chattering near the threshold
                // even when the loop itself is well-tracked.)
                _multi_slot_skipped_track += 1;
                if rising { rising_total += 1 } else { falling_total += 1 };
                continue;
            }
        }

        // Mirror mode CDR-coupled CLKDIV update: only update SM1's clkdiv when the
        // filter ACCEPTED this edge (interval_fp moved as a real measurement). Reject
        // events shouldn't move SM1's rate.
        if mirror_started && accept_for_cdr {
            // Per-edge SM1 clkdiv refresh from the PERIOD tracker.
            let interval_fp_slot = interval_fp_period >> 1;
            let (ci, cf) = interval_fp_to_clkdiv(interval_fp_slot, frac_bits);
            embassy_rp::pac::PIO0.sm(PIO_TX_SM).clkdiv().write(|w| {
                w.set_int(ci);
                w.set_frac(cf);
            });
        }

        // (TX FIFO topup now runs at top of loop so early-skip `continue`s
        // don't starve SM1 — see comment near pio_edge_read_until.)

        // RX bit decode. Each edge with n_slots gap = (n_slots - 1) quiet slots
        // (bit 0) followed by this transition slot (bit 1). Shift the buffer left
        // by n_slots and OR the trailing 1 — the n_slots-1 leading zeros come for
        // free because shifting in clears the new low bits.
        bits_buffer = bits_buffer.wrapping_shl(n_slots as u32) | 1;
        bits_decoded = bits_decoded.saturating_add(n_slots as u32);

        edges_seen += 1;
        let in_threshold = phase_err.abs() <= SYNC_LOCK_THRESHOLD_CYC;
        // Legacy consec counters — kept only because tests/diagnostics use them
        // for "edges-to-lock convergence rate". Not on the lock decision path.
        if rising {
            if in_threshold {
                consec_in_lock_rise = consec_in_lock_rise.saturating_add(1);
                consec_out_lock_rise = 0;
            } else {
                consec_out_lock_rise = consec_out_lock_rise.saturating_add(1);
                consec_in_lock_rise = 0;
            }
            // P-based lock: scaled EMA of phase_err (see decl comment). Single-edge
            // outliers wash out; sustained drift moves the EMA past threshold.
            phase_err_ema_rise_scaled = phase_err_ema_rise_scaled
                .wrapping_sub(phase_err_ema_rise_scaled >> SYNC_LOCK_EMA_SHIFT)
                .wrapping_add(phase_err);
            let ema_rise = phase_err_ema_rise_scaled >> SYNC_LOCK_EMA_SHIFT;
            rise_locked = ema_rise.abs() <= SYNC_LOCK_EMA_THRESHOLD_CYC;
        } else {
            if in_threshold {
                consec_in_lock_fall = consec_in_lock_fall.saturating_add(1);
                consec_out_lock_fall = 0;
            } else {
                consec_out_lock_fall = consec_out_lock_fall.saturating_add(1);
                consec_in_lock_fall = 0;
            }
            phase_err_ema_fall_scaled = phase_err_ema_fall_scaled
                .wrapping_sub(phase_err_ema_fall_scaled >> SYNC_LOCK_EMA_SHIFT)
                .wrapping_add(phase_err);
            let ema_fall = phase_err_ema_fall_scaled >> SYNC_LOCK_EMA_SHIFT;
            fall_locked = ema_fall.abs() <= SYNC_LOCK_EMA_THRESHOLD_CYC;
        }
        // Global `locked` = period EMA lock. Period is the actual frequency reference
        // (rise-to-rise = full cycle), and it's what SM1 clkdiv and the 2^12-silence
        // resilience budget hinge on. Per-polarity rise/fall_locked still update for
        // diagnostic surfaces but aren't on the decision path. Current-state semantics
        // — flips back to false the instant period EMA drifts past threshold.
        let was_locked = locked;
        locked = period_locked;
        if locked && !was_locked && edges_to_lock == u32::MAX {
            edges_to_lock = edges_seen;
        }

        let in_settle = iter < acquisition_iter_count + settle_iter;
        if !in_settle {
            phase_sum += phase_err as i64;

            let bin_signed = phase_err + SYNC_HIST_HALF_RANGE;
            if bin_signed >= 0 && bin_signed < SYNC_HIST_BINS as i32 {
                if rising {
                    rising_hist[bin_signed as usize] = rising_hist[bin_signed as usize].saturating_add(1);
                } else {
                    falling_hist[bin_signed as usize] = falling_hist[bin_signed as usize].saturating_add(1);
                }
            } else if phase_err < 0 {
                if rising { rising_neg_overflow += 1 } else { falling_neg_overflow += 1 };
            } else {
                if rising { rising_pos_overflow += 1 } else { falling_pos_overflow += 1 };
            }

            if rising {
                fall_to_rise_offset_sum += phase_err as i64;
            } else {
                rise_to_fall_offset_sum += phase_err as i64;
            }
        }

        if rising { rising_total += 1 } else { falling_total += 1 };
    }

    pio_edge_stop();

    // Mirror mode cleanup: release GP0 back to SIO input so the wire is clean for
    // the next operation. Without this, SM1 keeps cycling its program after we
    // return, and GP0 stays under PIO0 funcsel.
    if mirror_started {
        pio_tx_mirror_stop();
    }

    // Publish current PIPE comms state — reflects whether this sync run held lock.
    PIPE_COMMS_LOCKED.store(if locked { 1 } else { 0 }, PaOrdering::Release);

    let status: u32 = if rising_total == 0 && falling_total == 0 {
        2
    } else if !acquisition_done {
        1
    } else {
        0
    };

    let measurement_iter_count = iter.saturating_sub(acquisition_iter_count);

    // Combined slot for backward compatibility — average of HIGH and LOW slot estimates
    // (= the period / 2). Single-slot consumers (older CLI) get the right ballpark; the
    // _rise / _fall fields below carry the actual per-polarity slots:
    //   _rise field → LOW slot (LOW width, updated on rising edges)
    //   _fall field → HIGH slot (HIGH width, updated on falling edges)
    let acquisition_slot_cyc_avg = ((acquisition_slot_cyc_low as u64 + acquisition_slot_cyc_high as u64) / 2) as u32;
    let interval_fp_avg = ((interval_fp_low as u64 + interval_fp_high as u64) / 2) as u32;

    SyncResult {
        elapsed_us: start.elapsed().as_micros() as u32,
        total_iterations: iter,
        status,
        frac_bits,
        p_shift,
        locked: if locked { 1 } else { 0 },
        edges_to_lock,
        acquisition_slot_iter: acquisition_slot_cyc_avg,
        final_interval_fp: interval_fp_avg,
        acquisition_slot_cyc_rise: acquisition_slot_cyc_low,
        acquisition_slot_cyc_fall: acquisition_slot_cyc_high,
        final_interval_fp_rise: interval_fp_low,
        final_interval_fp_fall: interval_fp_high,
        acquisition_iter_count,
        measurement_iter_count,
        acq_rising,
        acq_falling,
        rising_total,
        falling_total,
        rising_neg_overflow,
        rising_pos_overflow,
        falling_neg_overflow,
        falling_pos_overflow,
        phase_sum,
        fall_to_rise_offset_sum,
        rise_to_fall_offset_sum,
        rising_hist,
        falling_hist,
        bits_buffer,
        bits_decoded,
        tx_words_consumed,
        // Report visible EMA (= scaled >> shift) so host doesn't need to know the
        // internal storage form.
        phase_err_ema_rise: phase_err_ema_rise_scaled >> SYNC_LOCK_EMA_SHIFT,
        phase_err_ema_fall: phase_err_ema_fall_scaled >> SYNC_LOCK_EMA_SHIFT,
        acquisition_slot_cyc_period,
        final_interval_fp_period: interval_fp_period,
        phase_err_ema_period: phase_err_ema_period_scaled >> SYNC_LOCK_EMA_SHIFT,
        period_hist,
        period_sum: period_sum_local,
        period_sample_count: period_sample_count_local,
        period_min: period_min_local,
        period_max: period_max_local,
        // Report slow EMA in fp form (same frac_bits as the other fp fields).
        // EMA state is already scaled by 2^SLOW_SHIFT in cyc units, so it has
        // SLOW_SHIFT bits of fractional precision baked in. To convert to fp form
        // with frac_bits precision, shift the difference — preserves the EMA's
        // sub-cyc precision instead of throwing it away with a >> then << pair.
        period_ema_slow_fp: {
            let shift_diff = frac_bits as i32 - SYNC_PERIOD_EMA_SLOW_SHIFT as i32;
            let scaled = if shift_diff >= 0 {
                period_ema_slow_scaled.wrapping_shl(shift_diff as u32)
            } else {
                period_ema_slow_scaled.wrapping_shr((-shift_diff) as u32)
            };
            scaled as u32
        },
        fpga_decoded_buffer: decode_buffer,
        fpga_decoded_count: decode_count,
        mirror_edges_accepted: _edges_accepted_in_mirror,
        mirror_edges_rejected_mid_slot: _edges_rejected_mid_slot,
        mirror_edges_rejected_wrong_polarity: _edges_rejected_wrong_polarity,
        mirror_claim12_match: _edges_claim12_match,
        mirror_claim12_mispredict_no_edge_observed: _edges_claim12_mispredict_no_edge_observed,
        mirror_claim12_mispredict_wrong_polarity: _edges_claim12_mispredict_wrong_polarity,
        slot_wire_log,
        slot_wire_log_count,
        fpga_decoded_log,
        fpga_decoded_log_count,
        edges_slots_crossed_capped: _edges_slots_crossed_capped,
        max_observed_slots_crossed: _max_observed_slots_crossed,
        edges_parity_ambiguous_skipped: _edges_parity_ambiguous_skipped,
        raw_own_cyc_log,
        raw_own_cyc_count,
        raw_own_cyc_slot_cyc,
        fpga_decoded_late_log,
        late_raw_own_cyc_log,
        late_raw_own_cyc_count,
    }
}

/// Slot-clock decoder. Acquisition + bang-bang CDR (same as fast_sync) seeds and tracks `interval_fp`. A continuous slot clock — driven by `interval_fp >> FRAC_BITS` — ticks autonomously regardless of edge density on the wire. Each tick advances slot_phase (enclave/host) and fires a mid-slot sample event. Edges feed the bang-bang to refine `interval_fp` (drift tracking) and update per-polarity wire-state width stats (RC bias diagnostic).
///
/// Why slot clock independent of edges: real protocol data has multi-slot HIGH/LOW dropouts (PROTOCOL.md Examples 2-5 show wire-LOW spans across multiple slot owners). An edge-triggered sampler would miss those slots entirely. The slot clock keeps ticking and we sample the wire's current state on every slot — codec decodes whatever the wire actually says, including extended LOWs.
///
/// Phase anchor: first rising edge after acquisition marks the start of an enclave (even) slot. From there the slot clock alternates polarity every `slot_iter` iter.
///
/// Caller MUST run inside `cortex_m::interrupt::free`.
fn fast_decode(max_iter: u32, frac_bits: u32) -> DecodeResult {
    let max_iter = max_iter.min(SYNC_MAX_ITERATIONS);
    let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);
    let gpio_in: *const u32 = embassy_rp::pac::SIO.gpio_in(0).as_ptr();
    let start = embassy_time::Instant::now();

    let mut prev: u32 = unsafe { gpio_in.read_volatile() & 1 };
    let mut iter: u32 = 1;
    let mut any_anchored: bool = false;
    let mut iter_since_rise: u32 = 0;
    let mut iter_since_fall: u32 = 0;
    let mut rise_anchored: bool = false;
    let mut fall_anchored: bool = false;

    // Acquisition (mirror of fast_sync).
    let mut acq_sum: u64 = 0;
    let mut acq_rising: u32 = 0;
    let mut acq_falling: u32 = 0;
    let mut acquisition_done: bool = false;
    let mut acquisition_slot_iter: u32 = 0;
    let mut interval_fp: u32 = 0;

    // Slot clock state. The state machine ticks every iter (post-acquisition); actions are gated by phase_anchored so the per-iter cost is uniform across the acquisition window and the decode window. Without that uniformity, the iter rate during acquisition (lean loop) differs from the iter rate during decode (slot-clock + codec call), and acquisition_slot_iter calibrates wrong in decode's iter frame — bang-bang then slews interval_fp to compensate, observable as drift of tens of iter over multi-second runs.
    //
    // iter_in_slot_fp tracks the slot counter at the SAME fixed-point precision as interval_fp. Increment by 1<<frac_bits per iter; boundary fires when iter_in_slot_fp >= interval_eff and subtracts interval_eff. The fractional component of interval_fp is preserved across every boundary — no integer truncation, so non-integer wire periods (e.g. 28.5 iter) stay phase-locked instead of drifting 0.5 iter per slot.
    let mut phase_anchored: bool = false;
    let mut iter_in_slot_fp: u32 = 0;
    let mut slot_phase: u32 = 0; // 0 = enclave, 1 = host
    let mut sample_done_this_slot: bool = false;
    let mut phase_adj_done: bool = false;
    let mut codec = Codec::host();

    // Per-polarity wire-state width diagnostic.
    let mut hi_count: u32 = 0;
    let mut hi_sum: u64 = 0;
    let mut hi_min: u32 = u32::MAX;
    let mut hi_max: u32 = 0;
    let mut lo_count: u32 = 0;
    let mut lo_sum: u64 = 0;
    let mut lo_min: u32 = u32::MAX;
    let mut lo_max: u32 = 0;

    let mut slots_total: u32 = 0;
    let mut bits_decoded: u32 = 0;
    let mut ones: u32 = 0;
    let mut zeros: u32 = 0;
    let mut recent_bits: [u64; 4] = [0; 4];

    while iter < max_iter {
        let cur = unsafe { gpio_in.read_volatile() & 1 };
        iter += 1;
        iter_since_rise += 1;
        iter_since_fall += 1;

        if cur != prev {
            let rising = cur == 1;
            prev = cur;

            if !any_anchored {
                any_anchored = true;
                if rising {
                    iter_since_rise = 0;
                    rise_anchored = true;
                } else {
                    iter_since_fall = 0;
                    fall_anchored = true;
                }
                continue;
            }

            if !acquisition_done {
                // Same-polarity acquisition: mirror fast_sync.
                if rising {
                    if !rise_anchored {
                        iter_since_rise = 0;
                        rise_anchored = true;
                    } else if acq_rising < SYNC_ACQ_PER_POLARITY {
                        acq_sum += iter_since_rise as u64;
                        acq_rising += 1;
                        iter_since_rise = 0;
                    }
                } else {
                    if !fall_anchored {
                        iter_since_fall = 0;
                        fall_anchored = true;
                    } else if acq_falling < SYNC_ACQ_PER_POLARITY {
                        acq_sum += iter_since_fall as u64;
                        acq_falling += 1;
                        iter_since_fall = 0;
                    }
                }
                if acq_rising >= SYNC_ACQ_PER_POLARITY && acq_falling >= SYNC_ACQ_PER_POLARITY {
                    acquisition_slot_iter = (acq_sum >> SYNC_ACQ_SHIFT) as u32;
                    interval_fp = acquisition_slot_iter << frac_bits;
                    acquisition_done = true;
                }
                continue;
            }

            // Post-acquisition gated phase detector with continuous P (gain 1/32). At most one adjustment per slot — first qualifying edge wins. iter_in_slot_fp is the error signal: V=0 is the target (boundary aligned with wire transition).
            //
            // Uses raw interval_fp (NOT the 8-iter pre-acquisition floor that interval_eff applies for safety against div-by-zero). The floor only matters before acquisition; once interval_fp is seeded from acquisition_slot_iter it's a real slot and the phase detector must operate on the real value. Using the floor here would: compute signed_offset relative to a synthetic ≥8-iter slot while interval_fp may be smaller (e.g. 4 iter at low iter rates), so adj = signed_offset >> 5 can exceed interval_fp, drag it below zero, and i32 wraparound makes it max u32 — runaway.
            //
            // Two cases based on which side of V the edge falls:
            //   V SMALL (<= half): edge happened just past our boundary in the new slot. Our clock fired too soon — slow down. Expected polarity = transition INTO new slot (slot_phase has already toggled): slot_phase==0 (now enclave) → rising; slot_phase==1 (now host) → falling. signed_offset = V (positive); adj = V >> 5 (positive); interval_fp += adj.
            //   V LARGE (> half): edge happened in the second half of the current slot, BEFORE our boundary. Our clock period is too long — speed up. Expected polarity = transition OUT of current slot: slot_phase==0 (enclave ending) → falling; slot_phase==1 (host ending) → rising. signed_offset = V - interval_fp (negative); adj = signed_offset >> 5 (negative); interval_fp += adj → decreases.
            //
            // Polarity check rejects edges from wrong-direction transitions (noise, RC ringing, real protocol data bits mid-slot). After every adjustment we clamp interval_fp to [seed/8, seed*8] — bounded enough that bang-bang noise can't drive the loop into the absurd, loose enough to track real ring-osc drift (hundreds of ppm/sec from chip self-heating).
            if phase_anchored && !phase_adj_done && interval_fp != 0 {
                let half_pd = interval_fp >> 1;
                let in_first_half = iter_in_slot_fp <= half_pd;
                let expected_rising = if in_first_half {
                    slot_phase == 0
                } else {
                    slot_phase == 1
                };
                if rising == expected_rising {
                    let signed_offset = if in_first_half {
                        iter_in_slot_fp as i32
                    } else {
                        iter_in_slot_fp as i32 - interval_fp as i32
                    };
                    let adj = signed_offset >> 5;
                    let new_fp = (interval_fp as i32).wrapping_add(adj);
                    // Clamp to [seed/8, seed*8] in fp units — covers any plausible ring-osc drift while bounding runaway from bang-bang misfire.
                    let seed_fp = (acquisition_slot_iter as u64) << frac_bits;
                    let min_fp = ((seed_fp >> 3) as u32).max(1u32 << frac_bits);
                    let max_fp = (seed_fp << 3).min(u32::MAX as u64) as u32;
                    interval_fp = (new_fp.max(min_fp as i32) as u32).min(max_fp);
                    phase_adj_done = true;
                }
            }

            // Width of the phase that just ended. Rising edge → previous phase was LOW (iter_since_fall counts iter since last falling). Falling edge → previous phase was HIGH.
            if rising {
                let dur = iter_since_fall;
                if dur < lo_min { lo_min = dur; }
                if dur > lo_max { lo_max = dur; }
                lo_sum += dur as u64;
                lo_count += 1;
            } else {
                let dur = iter_since_rise;
                if dur < hi_min { hi_min = dur; }
                if dur > hi_max { hi_max = dur; }
                hi_sum += dur as u64;
                hi_count += 1;
            }

            // Phase anchor: first rising edge after acquisition fires the slot clock.
            if !phase_anchored && rising {
                phase_anchored = true;
                iter_in_slot_fp = 0;
                slot_phase = 0;
                sample_done_this_slot = false;
            }

            if rising {
                iter_since_rise = 0;
            } else {
                iter_since_fall = 0;
            }
        }

        // Continuous slot clock — state machine ticks every iter at fixed-point precision matching interval_fp. iter_in_slot_fp += 1<<frac_bits per iter; boundary fires at iter_in_slot_fp >= interval_eff and subtracts interval_eff. Working in the SAME fp width as interval_fp preserves the fractional period across every boundary — no integer truncation, so non-integer wire periods stay phase-locked indefinitely.
        //
        // Pre-acquisition (interval_fp == 0), interval_eff saturates to 8<<frac_bits so the boundary check stays well-defined and constant-cost. Actions are gated by phase_anchored; checks themselves run every iter to keep the per-iter cost uniform across acquisition / pre-anchor / post-anchor.
        let one_iter_fp: u32 = 1u32 << frac_bits;
        iter_in_slot_fp = iter_in_slot_fp.wrapping_add(one_iter_fp);
        // Pre-acquisition floor (interval_fp == 0) keeps the boundary check well-defined; once interval_fp seeds from acquisition the real value drives the slot clock. Without this conditional, a real interval_fp smaller than 8 iter at low CPU rates (e.g. 4 iter at ~1 MHz iter rate) would be silently doubled and the bang-bang's per-edge adjustments would slew the clock toward absurd values.
        let interval_eff = if interval_fp == 0 { 8u32 << frac_bits } else { interval_fp };
        let half_interval = interval_eff >> 1;
        let mid_slot_hit = !sample_done_this_slot && iter_in_slot_fp >= half_interval;
        let slot_boundary_hit = iter_in_slot_fp >= interval_eff;

        if mid_slot_hit {
            if phase_anchored {
                let sample = cur as u8;
                if slot_phase == 0 {
                    let bit = codec.rx(sample);
                    if bit & 1 == 1 { ones += 1 } else { zeros += 1 };
                    bits_decoded += 1;
                    recent_bits[3] = (recent_bits[3] << 1) | (recent_bits[2] >> 63);
                    recent_bits[2] = (recent_bits[2] << 1) | (recent_bits[1] >> 63);
                    recent_bits[1] = (recent_bits[1] << 1) | (recent_bits[0] >> 63);
                    recent_bits[0] = (recent_bits[0] << 1) | (bit as u64 & 1);
                } else {
                    let _ = codec.tx(0);
                }
            }
            sample_done_this_slot = true;
        }

        if slot_boundary_hit {
            iter_in_slot_fp -= interval_eff;
            slot_phase ^= 1;
            sample_done_this_slot = false;
            phase_adj_done = false;
            if phase_anchored {
                slots_total += 1;
            }
        }
    }

    if hi_count == 0 { hi_min = 0; }
    if lo_count == 0 { lo_min = 0; }

    let status: u32 = if !any_anchored {
        2
    } else if !acquisition_done {
        1
    } else if !phase_anchored {
        3
    } else {
        0
    };

    DecodeResult {
        elapsed_us: start.elapsed().as_micros() as u32,
        total_iterations: iter,
        status,
        frac_bits,
        acquisition_slot_iter,
        final_interval_fp: interval_fp,
        hi_count,
        hi_sum_iter: hi_sum,
        hi_min_iter: hi_min,
        hi_max_iter: hi_max,
        lo_count,
        lo_sum_iter: lo_sum,
        lo_min_iter: lo_min,
        lo_max_iter: lo_max,
        slots_total,
        bits_decoded,
        ones,
        zeros,
        recent_bits,
    }
}

/// Core 1's PIPE wire task — owns GP0.
///
/// Phase 1 (current): holds the pin idle. Phase 2 will:
///   1. Hand GP0 to a PIO state machine implementing the mirror-XOR codec
///      (rtl/codec.v reference).
///   2. Run a DPLL on the line edges for clock recovery (8× oversample,
///      ±1 sample phase nudge per edge — bridge XOSC ±20 ppm × 20 µs slot
///      means we nudge maybe once every ~10 000 bits at most).
///   3. Pump bytes between PIO FIFOs and a pair of cross-core ring buffers
///      drained/filled by `handle_frames` on core 0.
///
/// The wire core stays single-purpose: PIO timing must not perturb (or be
/// perturbed by) USB latency, so all USB work lives on core 0.
#[embassy_executor::task]
async fn pipe_wire_task(mut wire: Flex<'static>) {
    // Configure GP0 as input with no pull — the FPGA-side 5kΩ external pull-down dominates the line when nobody's driving.
    wire.set_as_input();
    wire.set_pull(Pull::None);

    // Idle service loop: poll for diagnostic-tool arm requests (trace, stats, sync). No slot-rate sampling and no codec decode yet — that wiring waits until the FPGA emits protocol-spec idle and we feed wire_sync's locked slot_cycles back in here. The 1 ms poll is a yield point for the embassy executor (without it core 1 busy-spins) and is below human perception for tool-arm latency.
    loop {
        let req = TRACE_REQUEST.load(PaOrdering::Acquire);
        if req != 0 {
            let samples = (req as usize).min(TRACE_MAX_SAMPLES);
            let period_ns = TRACE_PERIOD_NS.load(PaOrdering::Relaxed);
            let elapsed_us = cortex_m::interrupt::free(|_| fast_capture(samples, period_ns));
            TRACE_ELAPSED_US.store(elapsed_us, PaOrdering::Relaxed);
            // Release: pairs with core 0's Acquire on TRACE_RESPONSE, publishing both TRACE_FAST_BUF writes and TRACE_ELAPSED_US.
            TRACE_RESPONSE.store(samples as u32, PaOrdering::Release);
            TRACE_REQUEST.store(0, PaOrdering::Relaxed);
        }

        let stats_req = STATS_REQUEST.load(PaOrdering::Acquire);
        if stats_req != 0 {
            let result = cortex_m::interrupt::free(|_| fast_stats(stats_req));
            let taken = result.samples_taken;
            unsafe {
                STATS_RESULT = result;
            }
            // Release: pairs with core 0's Acquire on STATS_RESPONSE, publishing STATS_RESULT writes.
            STATS_RESPONSE.store(taken, PaOrdering::Release);
            STATS_REQUEST.store(0, PaOrdering::Relaxed);
        }

        let sync_req = SYNC_REQUEST.load(PaOrdering::Acquire);
        if sync_req != 0 {
            let frac_req = SYNC_FRAC_REQUEST.load(PaOrdering::Relaxed);
            let settle_req = SYNC_SETTLE_REQUEST.load(PaOrdering::Relaxed);
            let p_shift_req = SYNC_P_SHIFT_REQUEST.load(PaOrdering::Relaxed);
            let mirror_mode = SYNC_MIRROR_MODE.load(PaOrdering::Relaxed) != 0;
            let tx_pattern = TX_MIRROR_PATTERN.load(PaOrdering::Relaxed);
            let cascade_mode = SYNC_CASCADE_MODE.load(PaOrdering::Relaxed);
            let result = cortex_m::interrupt::free(|_| fast_sync(sync_req, frac_req, settle_req, p_shift_req, mirror_mode, tx_pattern, cascade_mode));
            let iters = result.total_iterations.max(1);
            unsafe {
                SYNC_RESULT = result;
            }
            // Release: pairs with core 0's Acquire on SYNC_RESPONSE.
            SYNC_RESPONSE.store(iters, PaOrdering::Release);
            SYNC_REQUEST.store(0, PaOrdering::Relaxed);
        }

        let decode_req = DECODE_REQUEST.load(PaOrdering::Acquire);
        if decode_req != 0 {
            let frac_req = DECODE_FRAC_REQUEST.load(PaOrdering::Relaxed);
            let result = cortex_m::interrupt::free(|_| fast_decode(decode_req, frac_req));
            let iters = result.total_iterations.max(1);
            unsafe {
                DECODE_RESULT = result;
            }
            DECODE_RESPONSE.store(iters, PaOrdering::Release);
            DECODE_REQUEST.store(0, PaOrdering::Relaxed);
        }

        embassy_time::Timer::after(embassy_time::Duration::from_millis(1)).await;
    }
}

#[embassy_executor::task]
async fn geiger_task(mut heartbeat: Output<'static>) {
    use blake3::Hasher;
    use embassy_rp::pac;

    const GALOIS_TAPS: u32 = 0x80200003; // x^32 + x^22 + x^2 + x + 1

    // Boot-time seed: 32 raw ROSC bits → BLAKE3 → first 4 bytes
    let mut seed = [0u8; 32];
    for byte in &mut seed {
        for _ in 0..8 {
            let bit = pac::ROSC.randombit().read().randombit() as u8;
            *byte = (*byte << 1) | bit;
        }
    }
    let hash = Hasher::new().update(&seed).finalize();
    let mut state: u32 = u32::from_le_bytes(hash.as_bytes()[0..4].try_into().unwrap());
    if state == 0 {
        // LFSR must start non-zero or it stays at 0 forever
        state = 0xACE1DEED;
    }

    // Geiger blink, fully event-driven, geometric distribution (linear in µs).
    //
    // ON duration: one LFSR step → max(leading_ones, leading_zeros) of the
    //   32-bit state. Always 1..=32. P(k) = 2^(-k): 50% are 1 µs, 25% are
    //   2 µs, 12.5% are 3 µs, …, max 32 µs. Bits are unbiased so we have to
    //   look both ways from the MSB.
    //
    // OFF duration: AND OFF_ANDS LFSR steps together — each output bit is
    //   1 with probability 2^(-OFF_ANDS). At OFF_ANDS=12 that's 1/4096, so
    //   the MSB is 0 ~99.98% of the time and `leading_zeros` alone is the
    //   answer (no `leading_ones` to consider — Cortex-M0+ has no CLZ
    //   instruction, so each count is ~10–30 cycles; dropping the one that
    //   contributes nothing is a real save).
    //   If the 32-bit chunk lands all-zero (P ≈ 99.2% with OFF_ANDS=12),
    //   extend: another 32 leading zeros, another chunk, repeat. Tail
    //   extends to whatever bit width the dice want, no cap.
    //   Expected total OFF at OFF_ANDS=12: ~4 ms (1/p = 4096 bits ≈
    //   4096 µs), heavy tail.
    //
    // Both sleeps are select(Timer, WAKE_SIGNAL) so a USB state change
    // mid-pulse aborts the sleep and re-evaluates at the loop head, giving
    // TX/RX hold USB-IRQ latency rather than blink-cycle latency.
    use embassy_futures::select::{select, Either};

    const OFF_ANDS: u32 = 7;

    fn lfsr_step(state: &mut u32) {
        let trng = embassy_rp::pac::ROSC.randombit().read().randombit() as u32;
        *state ^= trng;
        let lsb = *state & 1;
        *state >>= 1;
        if lsb != 0 {
            *state ^= GALOIS_TAPS;
        }
    }

    fn on_pulse_us(state: &mut u32) -> u64 {
        lfsr_step(state);
        // 1 + leading_zeros has the same geometric distribution as max(clo, clz)
        // out to k=31 (P(k) = 1/2^k for k in 1..=32), with only a vanishing
        // 1/2^32 difference at the very tail. Uses one __clzsi2 call instead
        // of two, and the +1 floors at 1 µs so we never schedule a 0 µs sleep.
        1 + state.leading_zeros() as u64
    }

    /// AND `ands` LFSR readings into a single u32. Early-exits as soon as the
    /// accumulator collapses to 0 — at AND_n=12 the chunk reaches 0 around
    /// iteration 6-7 on average (P(zero by step k) = (1 - 1/2^k)^32), so the
    /// 99% "chunk is zero" path now does ~6 LFSR steps instead of 12. The
    /// answer is already determined the moment chunk hits 0; the remaining
    /// steps were busy-work.
    fn and_chunk(state: &mut u32, ands: u32) -> u32 {
        let mut chunk: u32 = u32::MAX;
        for _ in 0..ands {
            lfsr_step(state);
            chunk &= *state;
            if chunk == 0 {
                return 0;
            }
        }
        chunk
    }

    fn off_pulse_us(state: &mut u32) -> u64 {
        let mut total_zeros: u64 = 0;
        loop {
            let chunk = and_chunk(state, OFF_ANDS);
            if chunk != 0 {
                // +1 floors at 1 µs so the rare case where the first chunk's
                // MSB is already 1 (P ≈ 1/4096 at AND-12) doesn't schedule a
                // 0 µs sleep.
                return total_zeros + chunk.leading_zeros() as u64 + 1;
            }
            // Zero chunk — contributes 32 leading zeros, load another batch.
            total_zeros += 32;
        }
    }

    loop {
        match USB_STATE.load(Ordering::Relaxed) {
            STATE_TX => {
                heartbeat.set_high();
                WAKE_SIGNAL.wait().await;
            }
            STATE_RX => {
                heartbeat.set_low();
                WAKE_SIGNAL.wait().await;
            }
            _ => {
                // --- ON phase ---
                let on_us = on_pulse_us(&mut state);
                heartbeat.set_high();
                if let Either::Second(_) = select(
                    embassy_time::Timer::after_micros(on_us),
                    WAKE_SIGNAL.wait(),
                )
                .await
                {
                    continue;
                }

                // --- OFF phase ---
                let off_us = off_pulse_us(&mut state);
                heartbeat.set_low();
                if let Either::Second(_) = select(
                    embassy_time::Timer::after_micros(off_us),
                    WAKE_SIGNAL.wait(),
                )
                .await
                {
                    continue;
                }
            }
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // ram-image variant: point VTOR at our vector table in SRAM. cortex-m-rt doesn't touch VTOR, and the boot ROM leaves it pointing at the default (boot ROM at 0x00000000), not our 0x20000000 table.
    #[cfg(feature = "ram-image")]
    unsafe {
        let scb = &*cortex_m::peripheral::SCB::PTR;
        scb.vtor.write(0x2000_0000);
    }

    // Heap must come up before anything that allocates (VsfBuilder, etc).
    unsafe { HEAP.init(&raw mut HEAP_MEM as usize, HEAP_SIZE) }

    let p = embassy_rp::init(Default::default());

    // ---- Device public ID -------------------------------------------------
    // Read the flash chip's 8-byte unique ID via SPI cmd 0x4B, hash it together
    // with a domain string. The resulting 32 bytes are the device public ID
    // (a `hp` field on the wire). No private counterpart exists because the
    // flash unique ID isn't isolated — anyone with the chip can read it.
    let mut flash_uid = [0u8; 8];
    {
        let mut flash = Flash::<_, Blocking, FLASH_SIZE>::new_blocking(p.FLASH);
        // Disable interrupts during flash access — XIP is paused while talking SPI.
        let _ = cortex_m::interrupt::free(|_| flash.blocking_unique_id(&mut flash_uid));
    }
    static DEVICE_ID: StaticCell<[u8; 32]> = StaticCell::new();
    let device_id: &'static [u8; 32] =
        DEVICE_ID.init(blake3::derive_key(DEVICE_ID_DOMAIN, &flash_uid));

    // ---- GPIO setup ------------------------------------------------------
    // GP0 = the PIPE wire pin. Ownership moves to core 1 (the wire core).
    // Flex so we can switch between Input (RX/listen) and Output (TX/drive HIGH).
    // RX-only phase right now — input mode, FPGA-side 5kΩ pull-down handles LOW.
    let wire = Flex::new(p.PIN_0);

    // GP25 = external heartbeat LED. Direct-soldered (no series resistor)
    // at 2 mA drive strength — pin's own current limit replaces the resistor.
    // Stays on core 0 alongside USB, because LED state IS USB activity state:
    // the geiger task only runs the Galois LFSR when USB is idle, otherwise
    // holds the LED to indicate TX/RX direction. Same-core means no
    // cross-core signalling.
    let mut heartbeat = Output::new(p.PIN_25, Level::Low);
    heartbeat.set_drive_strength(Drive::_2mA);

    // ---- Core 1: PIPE wire ---------------------------------------------
    // Dedicated to wire comms so PIO timing / clock recovery isn't perturbed
    // by USB latency. Communicates with core 0 only via shared-memory ring
    // buffers (to be wired up alongside the Phase 2 PIO codec).
    spawn_core1(
        p.CORE1,
        unsafe { &mut *core::ptr::addr_of_mut!(CORE1_STACK) },
        move || {
            let executor1 = EXECUTOR1.init(Executor::new());
            executor1.run(|spawner| {
                spawner.spawn(pipe_wire_task(wire)).unwrap();
            });
        },
    );

    // ---- Core 0: USB + LED ---------------------------------------------
    // Spawn geiger on this executor; it shares cooperatively with the USB
    // future via the existing USB_STATE / WAKE_SIGNAL pair. Cross-core
    // signalling overhead is gone now that both tasks live here.
    spawner.spawn(geiger_task(heartbeat)).unwrap();

    // Onboard WS2812 RGB LED is on GP16 — not driven by this scaffold.

    // ---- USB stack -------------------------------------------------------
    let driver = Driver::new(p.USB, Irqs);

    // VID 0x1209 (pid.codes), PID 0x4665 (ferros, assigned via pid.codes PR #1208 2026-05-13).
    let mut config = Config::new(0x1209, 0x4665);
    config.manufacturer = Some("ferros");
    config.product = Some("pipe-bridge-rp2040");
    config.serial_number = Some("dev-0001");
    config.max_power = 100;
    config.max_packet_size_0 = 64;

    static CONFIG_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static MSOS_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static CTRL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESC.init([0; 256]),
        BOS_DESC.init([0; 256]),
        MSOS_DESC.init([0; 256]),
        CTRL_BUF.init([0; 64]),
    );

    let state = STATE.init(State::new());
    let mut class = CdcAcmClass::new(&mut builder, state, 64);
    let mut usb = builder.build();

    // ---- Run USB + dispatch + geiger (all on core 0, cooperative) -------
    let usb_fut = usb.run();
    let dispatch_fut = async {
        loop {
            class.wait_connection().await;
            let _ = handle_frames(&mut class, device_id).await;
        }
    };

    embassy_futures::join::join(usb_fut, dispatch_fut).await;
}

struct Disconnected {}

impl From<EndpointError> for Disconnected {
    fn from(val: EndpointError) -> Self {
        match val {
            EndpointError::BufferOverflow => core::panic!("Buffer overflow"),
            EndpointError::Disabled => Disconnected {},
        }
    }
}

/// Phase 2 loop: parse VSF commands from USB, dispatch, respond with VSF.
///
/// Wire format (each packet = one frame, fits in 64-byte CDC packet for now):
///   Every packet is a complete VSF document with one section named "pipe_message".
///   Body shape: [(d"op":a"<name>")(d"id":u<n>)(...optional fields...)]
///   The section name lives in the header TOC entry only; body is just fields.
///   Direction (cmd vs resp) is implicit from USB transfer direction.
///
/// Supported ops (Tier 1):
///   "ping"    → "pong"
///   "info"    → name, ver, did (hp 32B), clk (u32 Hz), up (u64 ms)
///   "uptime"  → ms (u64 since boot)
///   "random"  → data (vb3 ≤32 bytes, BLAKE3-conditioned ROSC entropy); accepts optional (d"n":u<count>) arg
///   "bootsel" → no response — drops into UF2 mass-storage bootloader (disconnect is the answer)
///   "reset"   → no response — soft-resets (disconnect is the answer)
///   (others)  → "unknown_op" error
///
/// Action commands deliberately send no ack. USB bulk transfers are guaranteed
/// at the transport layer, so for data commands the response IS the ack. For
/// actions the device disappears off the bus, so any ack races the disconnect
/// — drop it and let the host infer success from the disconnect.
async fn handle_frames<'d, T: embassy_usb::driver::Driver<'d>>(
    class: &mut CdcAcmClass<'d, T>,
    device_id: &'static [u8; 32],
) -> Result<(), Disconnected> {
    // `in_buf` accumulates incoming bytes across multiple CDC packets until we
    // see `]` (end of cmd section). Host writes hp-validated cmds that are
    // typically 78-100 bytes — well over the 64-byte CDC packet limit — so a
    // single-packet read is never enough. `out_buf` is sized for the biggest
    // response: wire_trace at TRACE_MAX_SAMPLES (8192 bits = 1024 bytes) plus
    // 8 B count/elapsed header plus ~100 B VSF framing → 2 KiB is comfortable.
    // dispatch() silently drops responses that don't fit, so undersizing this
    // surfaces as a mysterious host-side timeout (not an error code).
    let mut in_buf = [0u8; 256];
    let mut out_buf = [0u8; 4096];
    const MAX_PACKET: usize = 64;
    let mut acc_len = 0usize;
    loop {
        let n = class.read_packet(&mut in_buf[acc_len..]).await?;
        if n == 0 {
            continue;
        }
        acc_len += n;

        // Wait until we see the closing `]` of a cmd section — otherwise the
        // frame is incomplete and parsing would fail. If the buffer fills up
        // without one, drop everything (malformed frame).
        if in_buf[acc_len - 1] != b']' {
            if acc_len == in_buf.len() {
                acc_len = 0;
            }
            continue;
        }
        let frame_len = acc_len;
        acc_len = 0;

        // USB activity LED: receiving cmd from host = LED OFF; transmitting response to host = LED solid ON. Mental model is from the USB direction, not the wire direction. Idle reverts to the geiger heartbeat.
        USB_STATE.store(STATE_RX, Ordering::Relaxed);
        WAKE_SIGNAL.signal(());

        let (resp_len, action) = dispatch(&in_buf[..frame_len], &mut out_buf, device_id);

        if resp_len > 0 {
            USB_STATE.store(STATE_TX, Ordering::Relaxed);
            WAKE_SIGNAL.signal(());
            // Chunk into MAX_PACKET-sized writes. CDC-ACM bulk endpoints want
            // one packet per write call.
            let mut sent = 0;
            while sent < resp_len {
                let end = (sent + MAX_PACKET).min(resp_len);
                class.write_packet(&out_buf[sent..end]).await?;
                sent = end;
            }
            // If the response is an exact multiple of the packet size, append a
            // zero-length packet so the host knows the transfer ended.
            if resp_len.is_multiple_of(MAX_PACKET) {
                class.write_packet(&[]).await?;
            }
        }

        USB_STATE.store(STATE_IDLE, Ordering::Relaxed);
        WAKE_SIGNAL.signal(());

        // Post-action runs only after the response is on the wire so the host
        // actually sees the ack before the device drops off the bus.
        match action {
            PostAction::None => {}
            PostAction::BootSel => {
                embassy_rp::rom_data::reset_to_usb_boot(0, 0);
            }
            PostAction::Reset => {
                cortex_m::peripheral::SCB::sys_reset();
            }
            PostAction::LoadDev => {
                let size = LOAD_DEV_SIZE.load(PaOrdering::Relaxed);
                let id = LOAD_DEV_ID.load(PaOrdering::Relaxed);
                let expected_hash: [u8; 32] = unsafe { *(&raw const LOAD_DEV_HASH) };
                // Phase A: stream `size` raw bytes from CDC into SRAM at DEV_IMAGE_DEST.
                // No mid-stream hashing — verify by reading back the final destination
                // after the write completes, which catches both wire errors and any
                // hardware glitches between receive and store.
                USB_STATE.store(STATE_RX, Ordering::Relaxed);
                WAKE_SIGNAL.signal(());

                let dest = DEV_IMAGE_DEST as *mut u8;
                let mut received: u32 = 0;
                let mut chunk = [0u8; MAX_PACKET];
                let mut stage_err: Option<&'static str> = None;
                while received < size {
                    let n = match class.read_packet(&mut chunk).await {
                        Ok(0) => continue,
                        Ok(n) => n,
                        Err(_) => {
                            stage_err = Some("disconnect");
                            break;
                        }
                    };
                    let take = (n as u32).min(size - received) as usize;
                    if take > 0 {
                        unsafe {
                            core::ptr::copy_nonoverlapping(
                                chunk.as_ptr(),
                                dest.add(received as usize),
                                take,
                            );
                        }
                        received += take as u32;
                    }
                }

                // Phase B: verify SRAM by hashing it back and comparing to `did`.
                if stage_err.is_none() {
                    let staged = unsafe {
                        core::slice::from_raw_parts(DEV_IMAGE_DEST as *const u8, size as usize)
                    };
                    if blake3::hash(staged).as_bytes() != &expected_hash {
                        stage_err = Some("stage_hash_mismatch");
                    }
                }

                if let Some(err) = stage_err {
                    let err_fields: alloc::vec::Vec<(alloc::string::String, VsfType)> = vec![
                        ("id".to_string(), VsfType::u(id as usize, false)),
                        ("err".to_string(), VsfType::a(err.to_string())),
                    ];
                    let mut b = VsfBuilder::new().version(7, 7).provenance_only();
                    if let Some(et) = next_eagle_time() {
                        b = b.creation_time_oscillations(et as i64);
                    }
                    if let Ok(doc) = b.add_section("pipe_message", err_fields).build() {
                        USB_STATE.store(STATE_TX, Ordering::Relaxed);
                        WAKE_SIGNAL.signal(());
                        let mut sent = 0;
                        while sent < doc.len() {
                            let end = (sent + MAX_PACKET).min(doc.len());
                            if class.write_packet(&doc[sent..end]).await.is_err() {
                                break;
                            }
                            sent = end;
                        }
                        if doc.len().is_multiple_of(MAX_PACKET) {
                            let _ = class.write_packet(&[]).await;
                        }
                    }
                    USB_STATE.store(STATE_IDLE, Ordering::Relaxed);
                    WAKE_SIGNAL.signal(());
                    continue;
                }

                // Phase C: commit. Brief delay so any in-flight USB ack the host is
                // still reading clears the FIFO, then hand off to the dev image. The
                // USB disconnect that follows IS the success signal.
                embassy_time::Timer::after_millis(50).await;
                jump_to_dev_image();
            }
        }
    }
}

/// Hand off to a dev image already written to SRAM at DEV_IMAGE_DEST. Reads SP from
/// vector_table[0] and reset_handler from vector_table[1], disables interrupts, points
/// VTOR at the dev image's vector table, then sets MSP and `bx`-es to the reset handler.
/// The dev image's cortex-m-rt reset code takes over from there.
///
/// We do NOT reset the USB controller here. embassy_rp::init in the dev image performs
/// reset + unreset on USBCTRL as part of clocks::init, so the host sees a clean disconnect
/// followed by re-enumeration with the dev image's descriptors.
fn jump_to_dev_image() -> ! {
    unsafe {
        let sp = core::ptr::read_volatile(DEV_IMAGE_DEST as *const u32);
        let pc = core::ptr::read_volatile((DEV_IMAGE_DEST + 4) as *const u32);
        // VTOR before MSP/bx so any IRQ that fires during the brief transition vectors
        // through the dev image's table (which we just wrote into SRAM) rather than
        // manager's. Leave PRIMASK alone — cold-boot state is "enabled", and
        // embassy_executor on cortex-m assumes the same. Disabling here was the bug
        // that previously left the dev image with IRQs masked, so USBCTRL_IRQ never
        // fired and host descriptor reads timed out.
        let scb = &*cortex_m::peripheral::SCB::PTR;
        scb.vtor.write(DEV_IMAGE_DEST);
        core::arch::asm!(
            "msr msp, {sp}",
            "bx  {pc}",
            sp = in(reg) sp,
            pc = in(reg) pc,
            options(noreturn),
        );
    }
}

// ---------------------------------------------------------------------------
// Eagle Time epoch anchor — re-synced from the host on every cmd received.
//
// Host CLI uses `nunc-time` to source absolute Eagle Time and writes it into
// every cmd's `creation_time` header field. The firmware re-anchors
// `(host_et, my_uptime_at_receive)` on every cmd, so drift between cmds is
// bounded by the inter-cmd interval rather than accumulating across the full
// session. Subsequent `next_eagle_time()` calls return
// `host_et + (now - anchor_uptime)` — an absolute Eagle Time value monotonic
// across responses.
//
// `LAST_ET` enforces strict monotonicity: every emitted Eagle Time value is
// strictly greater than the previous one. If the host's clock ever moves
// backwards (NTP correction, DST, etc), the anchor moves with it but
// `LAST_ET` still prevents emitted timestamps from decreasing.
//
// EPOCH lives in a `static mut Option<(u64, u64)>` accessed via `&raw const`/
// `&raw mut` to avoid the static_mut_refs lint; the bridge handle_frames task
// is single-threaded on core 0, so reads and writes can't race.
// ---------------------------------------------------------------------------

static mut EPOCH: Option<(u64, u64)> = None;
static LAST_ET: AtomicU64 = AtomicU64::new(0);

/// Record `(host_eagle_time, my_uptime_us_at_receive)` from the current cmd.
/// Re-anchors on every call so drift is bounded by the inter-cmd interval.
/// No-op if the cmd's header omits `creation_time` (clockless callers).
fn anchor_epoch_from_cmd(input: &[u8]) {
    let (header, _) = match VsfHeader::decode(input) {
        Ok(h) => h,
        Err(_) => return,
    };
    let host_et = match &header.creation_time {
        Some(VsfType::e(EtType::e5(v))) => *v as u64,
        Some(VsfType::e(EtType::e6(v))) => *v as u64,
        Some(VsfType::e(EtType::e7(v))) => *v as u64,
        _ => return,
    };
    // SAFETY: the bridge runs handle_frames on a single embassy task pinned to core 0; anchor_epoch_from_cmd is only called from there, so we have exclusive access to EPOCH and the write can't race with the read in next_eagle_time().
    unsafe {
        *(&raw mut EPOCH) = Some((host_et, Instant::now().as_micros()));
    }
}

/// Return a strictly-monotonic Eagle Time value for the next outgoing packet, or `None` if the bridge has no clock anchor yet (no cmd has ever provided `creation_time`).
/// When `None`, the response omits the `e` field entirely rather than emit a fake/zero timestamp — same honesty rule the VSF spec applies to clockless devices.
fn next_eagle_time() -> Option<u64> {
    // SAFETY: see `anchor_epoch_from_cmd` — only called from the single bridge task.
    // Option<(u64, u64)> is Copy, so we get a snapshot — no torn reads possible on the single core 0 caller.
    let snapshot = unsafe { *(&raw const EPOCH) };
    let (host_et, anchor_us) = snapshot?;

    // host_et is in 21cm oscillations (~1.42 GHz); `Instant::as_micros()` is in microseconds.
    // Split-multiply by OSCILLATIONS_PER_SECOND so `secs * OPS` only overflows past ~400 years of uptime.
    let delta_us = Instant::now().as_micros().saturating_sub(anchor_us);
    let delta_secs = delta_us / 1_000_000;
    let delta_sub_us = delta_us % 1_000_000;
    let delta_oscillations = delta_secs
        .saturating_mul(OSCILLATIONS_PER_SECOND)
        .saturating_add(delta_sub_us * OSCILLATIONS_PER_SECOND / 1_000_000);
    let candidate = host_et.saturating_add(delta_oscillations);

    // Monotonic bump: never emit a value equal to or less than the previous one.
    // portable_atomic provides AtomicU64 CAS on Cortex-M0+ via critical_section polyfill.
    // Survives host clock corrections that move the anchor backwards — emitted values stay strictly increasing.
    loop {
        let prev = LAST_ET.load(PaOrdering::Relaxed);
        let next = candidate.max(prev.saturating_add(1));
        if LAST_ET
            .compare_exchange_weak(prev, next, PaOrdering::Relaxed, PaOrdering::Relaxed)
            .is_ok()
        {
            return Some(next);
        }
    }
}

/// Pull `n` bytes (≤32) of BLAKE3-conditioned hardware entropy.
///
/// Gathers 64 raw ROSC bits, runs them through one BLAKE3 invocation, returns
/// the first `n` bytes of the digest. Not crypto-grade — the RP2040 ROSC is a
/// single ring with no health checks (datasheet says so explicitly) — but it's
/// fine for the bridge's `random` debug command. PIPE silicon has the actual
/// entropy source.
fn gather_random(out: &mut [u8]) {
    use blake3::Hasher;
    use embassy_rp::pac;

    let mut raw = [0u8; 64];
    for byte in &mut raw {
        for _ in 0..8 {
            let bit = pac::ROSC.randombit().read().randombit() as u8;
            *byte = (*byte << 1) | bit;
        }
    }
    let digest = Hasher::new().update(&raw).finalize();
    let n = out.len().min(32);
    out[..n].copy_from_slice(&digest.as_bytes()[..n]);
}

/// Parse one VSF cmd packet from `input` (complete VSF document), dispatch,
/// encode the response into `output` (also a complete VSF document).
/// Returns `(response_length, post_action)`; a zero length means the frame
/// was malformed / hp-invalid / unknown section, in which case the host can
/// retry.
fn dispatch(input: &[u8], output: &mut [u8], device_id: &[u8; 32]) -> (usize, PostAction) {
    // Anchor the host Eagle Time on the first cmd we ever see, regardless of
    // whether hp later verifies. The header is parsed independently and the
    // anchor is a one-shot; even a malicious caller can't bump it twice.
    anchor_epoch_from_cmd(input);

    // hp verification covers the entire VSF document. Standard `is_original`
    // re-hashes with the hp slot zeroed and compares against the stored hp.
    if is_original(input).is_err() {
        return (0, PostAction::None);
    }

    // Locate the "pipe_message" section in the header TOC, then schema-parse its body.
    let (header, _) = match VsfHeader::decode(input) {
        Ok(h) => h,
        Err(_) => return (0, PostAction::None),
    };
    let field = match header.fields.iter().find(|f| f.name == "pipe_message") {
        Some(f) => f,
        _ => return (0, PostAction::None),
    };
    let off = field.offset_bytes;
    let size = field.size_bytes;
    if off.checked_add(size).map_or(true, |end| end > input.len()) {
        return (0, PostAction::None);
    }
    let section_bytes = &input[off..off + size];
    let cmd = match SectionBuilder::parse(pipe_message_schema(), section_bytes) {
        Ok(c) => c,
        Err(_) => return (0, PostAction::None),
    };

    // Schema-validated field reads. Missing field → default (`""` / `0`).
    let op_str = cmd
        .get("op")
        .ok()
        .and_then(|vs| vs.first())
        .and_then(|v| match v {
            VsfType::a(s) => Some(s.as_str()),
            _ => None,
        })
        .unwrap_or("");
    let id = cmd
        .get("id")
        .ok()
        .and_then(|vs| vs.first())
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let n_arg = cmd
        .get("n")
        .ok()
        .and_then(|vs| vs.first())
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    // Action commands send no response — the disconnect is the answer.
    match op_str {
        "bootsel" => return (0, PostAction::BootSel),
        "reset" => return (0, PostAction::Reset),
        _ => {}
    }

    // Build the resp section: always carries `id`, plus the op-specific fields.
    let up_ms = Instant::now().as_millis();
    let mut fields: alloc::vec::Vec<(alloc::string::String, VsfType)> = vec![
        ("id".to_string(), VsfType::u(id as usize, false)),
    ];
    let mut pending_action = PostAction::None;
    match op_str {
        "ping" => {
            fields.push(("op".to_string(), VsfType::a("pong".to_string())));
        }
        "info" => {
            fields.push(("name".to_string(), VsfType::a("pipe-bridge-rp2040".to_string())));
            fields.push(("ver".to_string(), VsfType::u(FW_VERSION as usize, false)));
            fields.push(("did".to_string(), VsfType::hp(device_id.to_vec())));
            fields.push((
                "clk".to_string(),
                VsfType::u(embassy_rp::clocks::clk_sys_freq() as usize, false),
            ));
            fields.push(("up".to_string(), VsfType::u(up_ms as usize, false)));
            // PIPE comms state from the most recent fast_sync/wire_mirror run.
            // 0 = never locked or lost lock; 1 = held lock for 256 consecutive
            // in-threshold edges per polarity (= we have comms with PIPE).
            fields.push((
                "pipe".to_string(),
                VsfType::u(PIPE_COMMS_LOCKED.load(PaOrdering::Acquire) as usize, false),
            ));
        }
        "uptime" => {
            fields.push(("ms".to_string(), VsfType::u(up_ms as usize, false)));
        }
        "random" => {
            // Default to 32 bytes if no `n` arg; cap at 32 (BLAKE3 digest size).
            let count = if n_arg == 0 { 32 } else { n_arg.min(32) } as usize;
            let mut buf = [0u8; 32];
            gather_random(&mut buf[..count]);
            fields.push(("data".to_string(), VsfType::v(b'b', buf[..count].to_vec())));
        }
        "wire_trace" => {
            // Input params packed into the request `data` blob:
            //   bytes 0..4  : samples (u32 LE) — output positions, clamped to
            //                 [1, TRACE_MAX_SAMPLES]
            //   bytes 4..8  : period_ns (u32 LE) — 0 = native loop rate,
            //                 >0 = delay between samples in nanoseconds
            // Missing/short blob → defaults: full buffer at native rate.
            let data_in = cmd
                .get("data")
                .ok()
                .and_then(|vs| vs.first().cloned())
                .and_then(|v| match v {
                    VsfType::v(b'b', bytes) => Some(bytes),
                    _ => None,
                })
                .unwrap_or_default();
            let (samples_req, period_ns) = if data_in.len() >= 8 {
                (
                    u32::from_le_bytes([data_in[0], data_in[1], data_in[2], data_in[3]]),
                    u32::from_le_bytes([data_in[4], data_in[5], data_in[6], data_in[7]]),
                )
            } else {
                (TRACE_MAX_SAMPLES as u32, 0u32)
            };
            let samples_req = samples_req.min(TRACE_MAX_SAMPLES as u32);

            if samples_req == 0 {
                fields.push(("err".to_string(), VsfType::a("zero_samples".to_string())));
            } else {
                // Arm: clear response first (so the poll below can wait on a
                // 0→N transition), publish period, then store samples count.
                // Release on TRACE_REQUEST pairs with core 1's Acquire load.
                TRACE_RESPONSE.store(0, PaOrdering::Relaxed);
                TRACE_PERIOD_NS.store(period_ns, PaOrdering::Relaxed);
                TRACE_REQUEST.store(samples_req, PaOrdering::Release);

                // Worst-case wall time = samples × period_ns; cap at 2 s so a
                // stuck wire task can't hang dispatch. At TRACE_MAX_SAMPLES
                // (8192) and 100 µs/sample that's 819 ms — comfortably inside.
                let deadline = Instant::now() + embassy_time::Duration::from_secs(2);
                while TRACE_RESPONSE.load(PaOrdering::Acquire) == 0 {
                    if Instant::now() > deadline {
                        break;
                    }
                    cortex_m::asm::nop();
                }

                let captured = TRACE_RESPONSE.load(PaOrdering::Relaxed);
                let elapsed_us = TRACE_ELAPSED_US.load(PaOrdering::Relaxed);
                let bytes_used = ((captured as usize) + 7) >> 3;

                // Response layout: [captured u32 LE][elapsed_us u32 LE][bitpacked samples].
                // Host divides elapsed_us by captured to derive the true rate.
                let mut payload = alloc::vec::Vec::with_capacity(8 + bytes_used);
                payload.extend_from_slice(&captured.to_le_bytes());
                payload.extend_from_slice(&elapsed_us.to_le_bytes());
                let buf_ptr = &raw const TRACE_FAST_BUF as *const u8;
                for i in 0..bytes_used {
                    payload.push(unsafe { buf_ptr.add(i).read_volatile() });
                }
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
            }
        }
        "wire_stats" => {
            // Input: bytes 0..4 = samples (u32 LE), clamped to STATS_MAX_SAMPLES. Missing/short → default 2^20 samples (~44 ms at 24 MS/s).
            let data_in = cmd
                .get("data")
                .ok()
                .and_then(|vs| vs.first().cloned())
                .and_then(|v| match v {
                    VsfType::v(b'b', bytes) => Some(bytes),
                    _ => None,
                })
                .unwrap_or_default();
            let samples_req = if data_in.len() >= 4 {
                u32::from_le_bytes([data_in[0], data_in[1], data_in[2], data_in[3]])
            } else {
                1u32 << 20
            };
            let samples_req = samples_req.min(STATS_MAX_SAMPLES);

            if samples_req == 0 {
                fields.push(("err".to_string(), VsfType::a("zero_samples".to_string())));
            } else {
                STATS_RESPONSE.store(0, PaOrdering::Relaxed);
                STATS_REQUEST.store(samples_req, PaOrdering::Release);

                // Worst case at STATS_MAX_SAMPLES (~4M) / ~24 MS/s ≈ 175 ms; 2 s deadline covers slower silicon variants comfortably.
                let deadline = Instant::now() + embassy_time::Duration::from_secs(2);
                while STATS_RESPONSE.load(PaOrdering::Acquire) == 0 {
                    if Instant::now() > deadline {
                        break;
                    }
                    cortex_m::asm::nop();
                }

                let taken = STATS_RESPONSE.load(PaOrdering::Relaxed);
                if taken == 0 {
                    fields.push(("err".to_string(), VsfType::a("stats_timeout".to_string())));
                } else {
                    // Acquire above already published STATS_RESULT.
                    let s = unsafe { STATS_RESULT };
                    // Layout (all LE), 200 bytes total: 72 bytes scalars (see WireStats), then 16 × u32 hi_hist (log2 run-length bins, 1..65k samples), then 16 × u32 lo_hist.
                    let mut payload = alloc::vec::Vec::with_capacity(200);
                    payload.extend_from_slice(&s.elapsed_us.to_le_bytes());
                    payload.extend_from_slice(&s.samples_taken.to_le_bytes());
                    payload.extend_from_slice(&s.final_state.to_le_bytes());
                    payload.extend_from_slice(&s.final_run.to_le_bytes());
                    payload.extend_from_slice(&s.hi_count.to_le_bytes());
                    payload.extend_from_slice(&s.hi_min.to_le_bytes());
                    payload.extend_from_slice(&s.hi_max.to_le_bytes());
                    payload.extend_from_slice(&s.hi_sum.to_le_bytes());
                    payload.extend_from_slice(&s.hi_sumsq.to_le_bytes());
                    payload.extend_from_slice(&s.lo_count.to_le_bytes());
                    payload.extend_from_slice(&s.lo_min.to_le_bytes());
                    payload.extend_from_slice(&s.lo_max.to_le_bytes());
                    payload.extend_from_slice(&s.lo_sum.to_le_bytes());
                    payload.extend_from_slice(&s.lo_sumsq.to_le_bytes());
                    for bin in &s.hi_hist {
                        payload.extend_from_slice(&bin.to_le_bytes());
                    }
                    for bin in &s.lo_hist {
                        payload.extend_from_slice(&bin.to_le_bytes());
                    }
                    fields.push(("data".to_string(), VsfType::v(b'b', payload)));
                }
            }
        }
        "wire_sync" => {
            // Input: bytes 0..4 = max_iter, 4..8 = frac_bits (optional), 8..12 = settle_iter (optional). All u32 LE.
            let data_in = cmd
                .get("data")
                .ok()
                .and_then(|vs| vs.first().cloned())
                .and_then(|v| match v {
                    VsfType::v(b'b', bytes) => Some(bytes),
                    _ => None,
                })
                .unwrap_or_default();
            let max_iter = if data_in.len() >= 4 {
                u32::from_le_bytes([data_in[0], data_in[1], data_in[2], data_in[3]])
            } else {
                1u32 << 25
            };
            let frac_bits = if data_in.len() >= 8 {
                u32::from_le_bytes([data_in[4], data_in[5], data_in[6], data_in[7]])
            } else {
                SYNC_FRAC_BITS_DEFAULT
            };
            let settle_iter = if data_in.len() >= 12 {
                u32::from_le_bytes([data_in[8], data_in[9], data_in[10], data_in[11]])
            } else {
                0
            };
            let p_shift = if data_in.len() >= 16 {
                u32::from_le_bytes([data_in[12], data_in[13], data_in[14], data_in[15]])
            } else {
                8 // default proportional gain 1/256 — converges in ~one 256-bit exchange
            };
            // Optional loopback TX pattern (bytes 16..20). Nonzero enables PIO TX on SM1
            // for the duration of the fast_sync run: the bridge drives this 32-bit pattern
            // continuously onto GP0 at slot rate, and the same PIO RX SM captures the
            // wire — letting us prove TX produces real transitions without needing
            // FPGA-side verification. Backward compat: missing/zero → no TX (the old
            // wire_sync behavior).
            let tx_pattern = if data_in.len() >= 20 {
                u32::from_le_bytes([data_in[16], data_in[17], data_in[18], data_in[19]])
            } else {
                0
            };
            // Optional cascade_mode (bytes 20..24). 0 = force n_slots=1 (clean toggle /
            // single-interval data), 1 = enable 1..4 cascade (LFSR / multi-slot). Default
            // 1 preserves the original wire_sync behaviour for existing callers.
            let cascade_mode = if data_in.len() >= 24 {
                u32::from_le_bytes([data_in[20], data_in[21], data_in[22], data_in[23]])
            } else {
                1
            };
            let max_iter = max_iter.min(SYNC_MAX_ITERATIONS).max(SYNC_ACQ_PER_POLARITY * 8);
            let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);
            let settle_iter = settle_iter.min(max_iter / 2);
            // Clamp p_shift to a sane range. Lower bound 0 = full iter correction per
            // edge (aggressive, risks oscillation). Upper bound 24 = effective no-op
            // (slew << small for any reasonable phase_err).
            let p_shift = p_shift.min(24);

            // Bring TX up BEFORE fast_sync triggers — the read loop in fast_sync (on
            // core 1) will keep the TX FIFO topped up via TX_LOOPBACK_PATTERN.
            if tx_pattern != 0 {
                pio_tx_init();
                pio_tx_start();
                for _ in 0..4 { pio_tx_push_word(tx_pattern); }
                TX_LOOPBACK_PATTERN.store(tx_pattern, PaOrdering::Release);
            }

            SYNC_RESPONSE.store(0, PaOrdering::Relaxed);
            SYNC_FRAC_REQUEST.store(frac_bits, PaOrdering::Relaxed);
            SYNC_SETTLE_REQUEST.store(settle_iter, PaOrdering::Relaxed);
            SYNC_P_SHIFT_REQUEST.store(p_shift, PaOrdering::Relaxed);
            SYNC_CASCADE_MODE.store(cascade_mode, PaOrdering::Relaxed);
            SYNC_REQUEST.store(max_iter, PaOrdering::Release);

            // SYNC_MAX_ITERATIONS = 2^28 = ~45-90 s worst case; 120 s deadline gives margin. USB CDC stays up on core 0 during this because interrupt::free on core 1 doesn't gate core 0's IRQs.
            let deadline = Instant::now() + embassy_time::Duration::from_secs(120);
            while SYNC_RESPONSE.load(PaOrdering::Acquire) == 0 {
                if Instant::now() > deadline {
                    break;
                }
                cortex_m::asm::nop();
            }

            if tx_pattern != 0 {
                TX_LOOPBACK_PATTERN.store(0, PaOrdering::Release);
                pio_tx_stop();
            }
            let iters = SYNC_RESPONSE.load(PaOrdering::Relaxed);
            if iters == 0 {
                fields.push(("err".to_string(), VsfType::a("sync_timeout".to_string())));
            } else {
                let s = unsafe { SYNC_RESULT };
                // Layout (all LE): 24 × u32 + 3 × i64 + 2 × SYNC_HIST_BINS × u16.
                //   u32: elapsed_us, total_iterations, status, frac_bits, p_shift,
                //        locked, edges_to_lock, acquisition_slot_cyc (combined avg),
                //        final_interval_fp (combined avg),
                //        acquisition_slot_cyc_rise, acquisition_slot_cyc_fall,
                //        final_interval_fp_rise, final_interval_fp_fall,
                //        acquisition_iter_count, measurement_iter_count, acq_rising,
                //        acq_falling, rising_total, falling_total, rising_neg_overflow,
                //        rising_pos_overflow, falling_neg_overflow, falling_pos_overflow,
                //        hist_bins
                //   i64: phase_sum, fall_to_rise_offset_sum, rise_to_fall_offset_sum
                //   u16[]: rising_hist[hist_bins], falling_hist[hist_bins]
                //
                // All slot/interval_fp fields are CYCLES (SYSTICK @ 125 MHz = 8 ns/cyc).
                // The historical *_iter suffix was kept where the byte name didn't change.
                let hist_bytes = SYNC_HIST_BINS * 2;
                let cap = 24 * 4 + 3 * 8 + 2 * hist_bytes + 8 + 4;  // +12 for RX bits appendix
                let mut payload = alloc::vec::Vec::with_capacity(cap);
                payload.extend_from_slice(&s.elapsed_us.to_le_bytes());
                payload.extend_from_slice(&s.total_iterations.to_le_bytes());
                payload.extend_from_slice(&s.status.to_le_bytes());
                payload.extend_from_slice(&s.frac_bits.to_le_bytes());
                payload.extend_from_slice(&s.p_shift.to_le_bytes());
                payload.extend_from_slice(&s.locked.to_le_bytes());
                payload.extend_from_slice(&s.edges_to_lock.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_iter.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_cyc_rise.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_cyc_fall.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp_rise.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp_fall.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_iter_count.to_le_bytes());
                payload.extend_from_slice(&s.measurement_iter_count.to_le_bytes());
                payload.extend_from_slice(&s.acq_rising.to_le_bytes());
                payload.extend_from_slice(&s.acq_falling.to_le_bytes());
                payload.extend_from_slice(&s.rising_total.to_le_bytes());
                payload.extend_from_slice(&s.falling_total.to_le_bytes());
                payload.extend_from_slice(&s.rising_neg_overflow.to_le_bytes());
                payload.extend_from_slice(&s.rising_pos_overflow.to_le_bytes());
                payload.extend_from_slice(&s.falling_neg_overflow.to_le_bytes());
                payload.extend_from_slice(&s.falling_pos_overflow.to_le_bytes());
                payload.extend_from_slice(&(SYNC_HIST_BINS as u32).to_le_bytes());
                payload.extend_from_slice(&s.phase_sum.to_le_bytes());
                payload.extend_from_slice(&s.fall_to_rise_offset_sum.to_le_bytes());
                payload.extend_from_slice(&s.rise_to_fall_offset_sum.to_le_bytes());
                for v in &s.rising_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                for v in &s.falling_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                // RX bit decoder appendix — backward compatible (old parsers stop after
                // the two histograms). bits_buffer (u64) holds the last 64 decoded
                // wire bits (LSB = newest), bits_decoded counts total bits since lock.
                payload.extend_from_slice(&s.bits_buffer.to_le_bytes());
                payload.extend_from_slice(&s.bits_decoded.to_le_bytes());
                // Mirror-mode appendix — count of 32-bit TX words pushed into SM1
                // FIFO during the run (0 outside mirror mode). Backward compatible.
                payload.extend_from_slice(&s.tx_words_consumed.to_le_bytes());
                // EMA-based lock detector appendix — per-polarity phase_err EMA value
                // (i32 cycles) at end of run. |EMA| <= SYNC_LOCK_EMA_THRESHOLD_CYC
                // means locked. Backward compatible (old parsers stop earlier).
                payload.extend_from_slice(&s.phase_err_ema_rise.to_le_bytes());
                payload.extend_from_slice(&s.phase_err_ema_fall.to_le_bytes());
                // PERIOD tracker appendix — the drift-stable frequency reference and
                // the active lock signal. acquisition_slot_cyc_period (u32 seed),
                // final_interval_fp_period (u32 fp value at end), phase_err_ema_period
                // (i32 EMA value, |EMA|<=16 = locked). Backward compatible (old parsers
                // stop at the per-polarity EMA fields).
                payload.extend_from_slice(&s.acquisition_slot_cyc_period.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp_period.to_le_bytes());
                payload.extend_from_slice(&s.phase_err_ema_period.to_le_bytes());
                // PERIOD histogram appendix — 17 × u32, see PERIOD_HIST_BINS.
                // Backward compatible (old parsers stop after phase_err_ema_period).
                for v in &s.period_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                // PERIOD sanity-check appendix — i64 sum, u32 count, i32 min, i32 max.
                payload.extend_from_slice(&s.period_sum.to_le_bytes());
                payload.extend_from_slice(&s.period_sample_count.to_le_bytes());
                payload.extend_from_slice(&s.period_min.to_le_bytes());
                payload.extend_from_slice(&s.period_max.to_le_bytes());
                // Slow EMA appendix — u32 fp value, same frac_bits scaling. The
                // long-term-stable prediction for the wire period.
                payload.extend_from_slice(&s.period_ema_slow_fp.to_le_bytes());
                // Phase 2c decode appendix — u32 LSB-first rolling buffer of FPGA
                // bits decoded per Claim 12 inverse, u32 cumulative count of enclave
                // slots that contributed. Both are 0 outside mirror mode.
                payload.extend_from_slice(&s.fpga_decoded_buffer.to_le_bytes());
                payload.extend_from_slice(&s.fpga_decoded_count.to_le_bytes());
                // Mirror-mode filter counters appendix — 3 × u32 for accepted, mid-slot
                // rejected, wrong-polarity rejected. All 0 in wire_sync; useful for
                // diagnosing decode regressions vs. filter false-rejection rates.
                payload.extend_from_slice(&s.mirror_edges_accepted.to_le_bytes());
                payload.extend_from_slice(&s.mirror_edges_rejected_mid_slot.to_le_bytes());
                payload.extend_from_slice(&s.mirror_edges_rejected_wrong_polarity.to_le_bytes());
                payload.extend_from_slice(&s.mirror_claim12_match.to_le_bytes());
                payload.extend_from_slice(&s.mirror_claim12_mispredict_no_edge_observed.to_le_bytes());
                payload.extend_from_slice(&s.mirror_claim12_mispredict_wrong_polarity.to_le_bytes());
                // Raw wire-state-per-slot log (32 bytes = 256 bits) + count (u32).
                payload.extend_from_slice(&s.slot_wire_log);
                payload.extend_from_slice(&s.slot_wire_log_count.to_le_bytes());
                // FPGA-decoded-bits log (32 bytes = 256 bits) + count (u32). First 256
                // decoded enclave-slot bits for bit-exact verify against the 256-bit
                // FPGA TX_PATTERN. Older host parsers stop after slot_wire_log_count.
                payload.extend_from_slice(&s.fpga_decoded_log);
                payload.extend_from_slice(&s.fpga_decoded_log_count.to_le_bytes());
                // slots_crossed clamp diagnostic (2 × u32): how often the SLOTS_CROSSED_MAX
                // clamp fired (each event = slot_phase parity off by truncated count) and
                // the largest single-edge slots_crossed observed (pre-clamp).
                payload.extend_from_slice(&s.edges_slots_crossed_capped.to_le_bytes());
                payload.extend_from_slice(&s.max_observed_slots_crossed.to_le_bytes());
                // Parity-ambiguous skip counter (u32). Older host parsers stop after
                // max_observed_slots_crossed; this is a tail-appended diagnostic.
                payload.extend_from_slice(&s.edges_parity_ambiguous_skipped.to_le_bytes());
                // Raw own_cyc capture appendix: u32 slot_cyc snapshot, u32 count, then
                // 256 × u32 own_cyc_u values. Host plots histogram + ratios to verify
                // the slot tracker's model of the actual wire timing.
                payload.extend_from_slice(&s.raw_own_cyc_slot_cyc.to_le_bytes());
                payload.extend_from_slice(&s.raw_own_cyc_count.to_le_bytes());
                for v in s.raw_own_cyc_log.iter() {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                // Late-bits sliding window (32 bytes = ring of LAST 256 decoded bits).
                payload.extend_from_slice(&s.fpga_decoded_late_log);
                // LATE raw own_cyc ring: u32 count + 256 × u32 log.
                payload.extend_from_slice(&s.late_raw_own_cyc_count.to_le_bytes());
                for v in s.late_raw_own_cyc_log.iter() {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
            }
        }
        "wire_mirror" => {
            // Slot-aware mirror-XOR drive: bridge owns host slots, FPGA owns enclave
            // slots, no CMOS contention. Runs the same fast_sync CDR as wire_sync,
            // but with mirror_mode=true so SM1 (with the 2-instr side-set program)
            // gets enabled on the first rising edge after acquisition, and SM1's
            // CLKDIV is continuously updated from interval_fp_low (rising-edge-anchored
            // FPGA timing). TX pattern is shifted LSB-first via `out pins, 1`.
            //
            // Input layout: max_iter (u32), frac_bits (u32, opt), p_shift (u32, opt),
            // tx_pattern (u32, opt, hex). Defaults: max_iter=2^25, frac=16, p_shift=8,
            // tx=AAAAAAAA (alternating bits maintain edge density for CDR feedback).
            let data_in = cmd
                .get("data")
                .ok()
                .and_then(|vs| vs.first().cloned())
                .and_then(|v| match v {
                    VsfType::v(b'b', bytes) => Some(bytes),
                    _ => None,
                })
                .unwrap_or_default();
            let max_iter = if data_in.len() >= 4 {
                u32::from_le_bytes([data_in[0], data_in[1], data_in[2], data_in[3]])
            } else {
                1u32 << 25
            };
            let frac_bits = if data_in.len() >= 8 {
                u32::from_le_bytes([data_in[4], data_in[5], data_in[6], data_in[7]])
            } else {
                SYNC_FRAC_BITS_DEFAULT
            };
            let p_shift = if data_in.len() >= 12 {
                u32::from_le_bytes([data_in[8], data_in[9], data_in[10], data_in[11]])
            } else {
                8
            };
            let tx_pattern = if data_in.len() >= 16 {
                u32::from_le_bytes([data_in[12], data_in[13], data_in[14], data_in[15]])
            } else {
                0xAAAA_AAAA
            };
            // cascade_mode is optional; default 0 (force n_periods=1). This is the
            // right default for AAAAAAAA-class TX patterns where the rising-to-
            // rising period after the slot-phase filter is reliably 1× seed.
            // cascade=1 (n=1..4 unfolding) reintroduces cascade-promotion fixed
            // points — observed to pull the loop down to seed/2 in mirror mode for
            // both AAAAAAAA and DEADBEEF. Truly sparse TX patterns like DEADBEEF
            // need TX-aware period prediction (compute exact n_periods from the
            // known TX pattern) before they'll lock — neither cascade value works.
            let cascade_mode = if data_in.len() >= 20 {
                u32::from_le_bytes([data_in[16], data_in[17], data_in[18], data_in[19]])
            } else {
                0
            }.min(1);
            let max_iter = max_iter.min(SYNC_MAX_ITERATIONS).max(SYNC_ACQ_PER_POLARITY * 8);
            let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);
            let p_shift = p_shift.min(24);

            SYNC_RESPONSE.store(0, PaOrdering::Relaxed);
            SYNC_FRAC_REQUEST.store(frac_bits, PaOrdering::Relaxed);
            SYNC_SETTLE_REQUEST.store(0, PaOrdering::Relaxed);
            SYNC_P_SHIFT_REQUEST.store(p_shift, PaOrdering::Relaxed);
            SYNC_MIRROR_MODE.store(1, PaOrdering::Relaxed);
            TX_MIRROR_PATTERN.store(tx_pattern, PaOrdering::Relaxed);
            SYNC_CASCADE_MODE.store(cascade_mode, PaOrdering::Relaxed);
            SYNC_REQUEST.store(max_iter, PaOrdering::Release);

            let deadline = Instant::now() + embassy_time::Duration::from_secs(120);
            while SYNC_RESPONSE.load(PaOrdering::Acquire) == 0 {
                if Instant::now() > deadline {
                    break;
                }
                cortex_m::asm::nop();
            }

            // Clear mirror mode flag so subsequent wire_sync calls don't accidentally
            // run with mirror enabled. The fast_sync function already called
            // pio_tx_mirror_stop on its way out.
            SYNC_MIRROR_MODE.store(0, PaOrdering::Relaxed);

            let iters = SYNC_RESPONSE.load(PaOrdering::Relaxed);
            if iters == 0 {
                fields.push(("err".to_string(), VsfType::a("sync_timeout".to_string())));
            } else {
                // Same payload encoding as wire_sync — host CLI parses both with the
                // same SyncResult layout, including the tx_words_consumed appendix.
                let s = unsafe { SYNC_RESULT };
                let hist_bytes = SYNC_HIST_BINS * 2;
                let cap = 24 * 4 + 3 * 8 + 2 * hist_bytes + 8 + 4 + 4;
                let mut payload = alloc::vec::Vec::with_capacity(cap);
                payload.extend_from_slice(&s.elapsed_us.to_le_bytes());
                payload.extend_from_slice(&s.total_iterations.to_le_bytes());
                payload.extend_from_slice(&s.status.to_le_bytes());
                payload.extend_from_slice(&s.frac_bits.to_le_bytes());
                payload.extend_from_slice(&s.p_shift.to_le_bytes());
                payload.extend_from_slice(&s.locked.to_le_bytes());
                payload.extend_from_slice(&s.edges_to_lock.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_iter.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_cyc_rise.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_cyc_fall.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp_rise.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp_fall.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_iter_count.to_le_bytes());
                payload.extend_from_slice(&s.measurement_iter_count.to_le_bytes());
                payload.extend_from_slice(&s.acq_rising.to_le_bytes());
                payload.extend_from_slice(&s.acq_falling.to_le_bytes());
                payload.extend_from_slice(&s.rising_total.to_le_bytes());
                payload.extend_from_slice(&s.falling_total.to_le_bytes());
                payload.extend_from_slice(&s.rising_neg_overflow.to_le_bytes());
                payload.extend_from_slice(&s.rising_pos_overflow.to_le_bytes());
                payload.extend_from_slice(&s.falling_neg_overflow.to_le_bytes());
                payload.extend_from_slice(&s.falling_pos_overflow.to_le_bytes());
                payload.extend_from_slice(&(SYNC_HIST_BINS as u32).to_le_bytes());
                payload.extend_from_slice(&s.phase_sum.to_le_bytes());
                payload.extend_from_slice(&s.fall_to_rise_offset_sum.to_le_bytes());
                payload.extend_from_slice(&s.rise_to_fall_offset_sum.to_le_bytes());
                for v in &s.rising_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                for v in &s.falling_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                payload.extend_from_slice(&s.bits_buffer.to_le_bytes());
                payload.extend_from_slice(&s.bits_decoded.to_le_bytes());
                payload.extend_from_slice(&s.tx_words_consumed.to_le_bytes());
                // EMA-based lock detector appendix — per-polarity phase_err EMA value
                // (i32 cycles) at end of run. |EMA| <= SYNC_LOCK_EMA_THRESHOLD_CYC
                // means locked. Backward compatible (old parsers stop earlier).
                payload.extend_from_slice(&s.phase_err_ema_rise.to_le_bytes());
                payload.extend_from_slice(&s.phase_err_ema_fall.to_le_bytes());
                // PERIOD tracker appendix — the drift-stable frequency reference and
                // the active lock signal. acquisition_slot_cyc_period (u32 seed),
                // final_interval_fp_period (u32 fp value at end), phase_err_ema_period
                // (i32 EMA value, |EMA|<=16 = locked). Backward compatible (old parsers
                // stop at the per-polarity EMA fields).
                payload.extend_from_slice(&s.acquisition_slot_cyc_period.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp_period.to_le_bytes());
                payload.extend_from_slice(&s.phase_err_ema_period.to_le_bytes());
                // PERIOD histogram appendix — 17 × u32, see PERIOD_HIST_BINS.
                for v in &s.period_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                // PERIOD sanity-check appendix — i64 sum, u32 count, i32 min, i32 max.
                // Lets the host verify `period_sum × 8 ns ≟ tracking-phase wall time`.
                payload.extend_from_slice(&s.period_sum.to_le_bytes());
                payload.extend_from_slice(&s.period_sample_count.to_le_bytes());
                payload.extend_from_slice(&s.period_min.to_le_bytes());
                payload.extend_from_slice(&s.period_max.to_le_bytes());
                // Slow EMA appendix — u32 fp value, same frac_bits scaling. Matches
                // wire_sync's appendix layout; previously absent from wire_mirror's
                // payload (drift), now in lockstep.
                payload.extend_from_slice(&s.period_ema_slow_fp.to_le_bytes());
                // Phase 2c decode appendix — u32 rolling buffer of FPGA bits decoded
                // per Claim 12 inverse, u32 enclave-slot count. Both 0 in wire_sync.
                payload.extend_from_slice(&s.fpga_decoded_buffer.to_le_bytes());
                payload.extend_from_slice(&s.fpga_decoded_count.to_le_bytes());
                // Mirror-mode filter counters appendix — 3 × u32 for accepted, mid-slot
                // rejected, wrong-polarity rejected. See SyncResult doc; matches the
                // wire_sync appendix layout.
                payload.extend_from_slice(&s.mirror_edges_accepted.to_le_bytes());
                payload.extend_from_slice(&s.mirror_edges_rejected_mid_slot.to_le_bytes());
                payload.extend_from_slice(&s.mirror_edges_rejected_wrong_polarity.to_le_bytes());
                payload.extend_from_slice(&s.mirror_claim12_match.to_le_bytes());
                payload.extend_from_slice(&s.mirror_claim12_mispredict_no_edge_observed.to_le_bytes());
                payload.extend_from_slice(&s.mirror_claim12_mispredict_wrong_polarity.to_le_bytes());
                // Raw wire-state-per-slot log (32 bytes = 256 bits) + count (u32).
                payload.extend_from_slice(&s.slot_wire_log);
                payload.extend_from_slice(&s.slot_wire_log_count.to_le_bytes());
                // FPGA-decoded-bits log (32 bytes = 256 bits) + count (u32). First 256
                // decoded enclave-slot bits for bit-exact verify against the 256-bit
                // FPGA TX_PATTERN. Older host parsers stop after slot_wire_log_count.
                payload.extend_from_slice(&s.fpga_decoded_log);
                payload.extend_from_slice(&s.fpga_decoded_log_count.to_le_bytes());
                // slots_crossed clamp diagnostic (2 × u32): how often the SLOTS_CROSSED_MAX
                // clamp fired (each event = slot_phase parity off by truncated count) and
                // the largest single-edge slots_crossed observed (pre-clamp).
                payload.extend_from_slice(&s.edges_slots_crossed_capped.to_le_bytes());
                payload.extend_from_slice(&s.max_observed_slots_crossed.to_le_bytes());
                // Parity-ambiguous skip counter (u32). Older host parsers stop after
                // max_observed_slots_crossed; this is a tail-appended diagnostic.
                payload.extend_from_slice(&s.edges_parity_ambiguous_skipped.to_le_bytes());
                // Raw own_cyc capture appendix: u32 slot_cyc snapshot, u32 count, then
                // 256 × u32 own_cyc_u values. Host plots histogram + ratios to verify
                // the slot tracker's model of the actual wire timing.
                payload.extend_from_slice(&s.raw_own_cyc_slot_cyc.to_le_bytes());
                payload.extend_from_slice(&s.raw_own_cyc_count.to_le_bytes());
                for v in s.raw_own_cyc_log.iter() {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                // Late-bits sliding window (32 bytes = ring of LAST 256 decoded bits).
                payload.extend_from_slice(&s.fpga_decoded_late_log);
                // LATE raw own_cyc ring: u32 count + 256 × u32 log.
                payload.extend_from_slice(&s.late_raw_own_cyc_count.to_le_bytes());
                for v in s.late_raw_own_cyc_log.iter() {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
            }
        }
        "wire_tx_diag" => {
            // Two-phase TX diagnostic. Phase A: PIO TX. Phase B: SIO direct toggle.
            // Run them back-to-back from the same context, count GP0 transitions in
            // each. SIO can definitively drive the pin from the CPU register set,
            // bypassing PIO entirely — so if SIO transitions > 0 and PIO transitions
            // == 0, the bug is in our PIO TX setup, not the pad/contention.
            //
            // Wire format (all LE u32):
            //   pio_samples, pio_transitions, pio_first, pio_last,
            //   ctrl_before, ctrl_pio, pads_pio,
            //   pio_sm_addr, pio_sm_execctrl, pio_fstat,
            //   sio_samples, sio_transitions, sio_first, sio_last,
            //   ctrl_sio, pads_sio
            cortex_m::interrupt::free(|_| {
                use embassy_rp::pac::{IO_BANK0, PADS_BANK0, PIO0, SIO};
                use embassy_rp::pac::io::vals::{Oeover, Outover};

                let ctrl_before = IO_BANK0.gpio(0).ctrl().read().0;
                let gpio_in: *const u32 = SIO.gpio_in(0).as_ptr();

                // ============================ Phase A: PIO TX ============================
                pio_tx_init();
                pio_tx_start();
                for _ in 0..4 { pio_tx_push_word(0xAAAA_AAAA); }
                let ctrl_pio = IO_BANK0.gpio(0).ctrl().read().0;
                let pads_pio = PADS_BANK0.gpio(0).read().0;
                for _ in 0..1000 { cortex_m::asm::nop(); }

                let pio_first = unsafe { gpio_in.read_volatile() & 1 };
                let mut last_seen = pio_first;
                let mut pio_transitions: u32 = 0;
                const SAMPLES: u32 = 4096;
                for _ in 0..SAMPLES {
                    let cur = unsafe { gpio_in.read_volatile() & 1 };
                    if cur != last_seen { pio_transitions += 1; last_seen = cur; }
                    if (PIO0.fstat().read().txfull() & (1 << PIO_TX_SM)) == 0 {
                        PIO0.txf(PIO_TX_SM).write_value(0xAAAA_AAAA);
                    }
                }
                let pio_last = last_seen;
                let pio_sm_addr = PIO0.sm(PIO_TX_SM).addr().read().0;
                let pio_sm_execctrl = PIO0.sm(PIO_TX_SM).execctrl().read().0;
                let pio_fstat = PIO0.fstat().read().0;
                pio_tx_stop();

                // ============================ Phase B: SIO toggle ============================
                // Take ownership of GP0 via SIO. Force IO_BANK0 to SIO funcsel + ENABLE OE.
                // Make sure PAD output is enabled. Toggle GP0 1024 times via the
                // gpio_out_xor register (cheapest way: single store flips the bit), and
                // sample after each toggle.
                IO_BANK0.gpio(0).ctrl().write(|w| {
                    w.set_funcsel(5); // SIO
                    w.set_outover(Outover::NORMAL);
                    w.set_oeover(Oeover::ENABLE);
                });
                PADS_BANK0.gpio(0).modify(|w| {
                    w.set_od(false);
                    w.set_ie(true);
                });
                // SIO OE for GP0: enable output
                SIO.gpio_oe(0).value_set().write_value(1);
                SIO.gpio_out(0).value_clr().write_value(1); // start LOW

                let ctrl_sio = IO_BANK0.gpio(0).ctrl().read().0;
                let pads_sio = PADS_BANK0.gpio(0).read().0;

                let sio_first = unsafe { gpio_in.read_volatile() & 1 };
                let mut last_seen = sio_first;
                let mut sio_transitions: u32 = 0;
                const SIO_TOGGLES: u32 = 1024;
                for i in 0..SIO_TOGGLES {
                    // Toggle GP0 via XOR register (atomic single-cycle flip).
                    SIO.gpio_out(0).value_xor().write_value(1);
                    // Small delay so the synchronizer can see it.
                    if (i & 0x3) == 0 { for _ in 0..16 { cortex_m::asm::nop(); } }
                    let cur = unsafe { gpio_in.read_volatile() & 1 };
                    if cur != last_seen { sio_transitions += 1; last_seen = cur; }
                }
                let sio_last = last_seen;

                // Hand pin back to input (disable SIO OE).
                SIO.gpio_oe(0).value_clr().write_value(1);

                let mut payload = alloc::vec::Vec::with_capacity(16 * 4);
                payload.extend_from_slice(&SAMPLES.to_le_bytes());
                payload.extend_from_slice(&pio_transitions.to_le_bytes());
                payload.extend_from_slice(&pio_first.to_le_bytes());
                payload.extend_from_slice(&pio_last.to_le_bytes());
                payload.extend_from_slice(&ctrl_before.to_le_bytes());
                payload.extend_from_slice(&ctrl_pio.to_le_bytes());
                payload.extend_from_slice(&pads_pio.to_le_bytes());
                payload.extend_from_slice(&pio_sm_addr.to_le_bytes());
                payload.extend_from_slice(&pio_sm_execctrl.to_le_bytes());
                payload.extend_from_slice(&pio_fstat.to_le_bytes());
                payload.extend_from_slice(&SIO_TOGGLES.to_le_bytes());
                payload.extend_from_slice(&sio_transitions.to_le_bytes());
                payload.extend_from_slice(&sio_first.to_le_bytes());
                payload.extend_from_slice(&sio_last.to_le_bytes());
                payload.extend_from_slice(&ctrl_sio.to_le_bytes());
                payload.extend_from_slice(&pads_sio.to_le_bytes());
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
            });
        }
        "wire_decode" => {
            // Input: bytes 0..4 = max_iter (u32 LE), bytes 4..8 = frac_bits (u32 LE, optional).
            let data_in = cmd
                .get("data")
                .ok()
                .and_then(|vs| vs.first().cloned())
                .and_then(|v| match v {
                    VsfType::v(b'b', bytes) => Some(bytes),
                    _ => None,
                })
                .unwrap_or_default();
            let max_iter = if data_in.len() >= 4 {
                u32::from_le_bytes([data_in[0], data_in[1], data_in[2], data_in[3]])
            } else {
                5_000_000
            };
            let frac_bits = if data_in.len() >= 8 {
                u32::from_le_bytes([data_in[4], data_in[5], data_in[6], data_in[7]])
            } else {
                SYNC_FRAC_BITS_DEFAULT
            };
            let max_iter = max_iter.min(SYNC_MAX_ITERATIONS).max(SYNC_ACQ_PER_POLARITY * 8);
            let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);

            DECODE_RESPONSE.store(0, PaOrdering::Relaxed);
            DECODE_FRAC_REQUEST.store(frac_bits, PaOrdering::Relaxed);
            DECODE_REQUEST.store(max_iter, PaOrdering::Release);

            let deadline = Instant::now() + embassy_time::Duration::from_secs(120);
            while DECODE_RESPONSE.load(PaOrdering::Acquire) == 0 {
                if Instant::now() > deadline {
                    break;
                }
                cortex_m::asm::nop();
            }
            let iters = DECODE_RESPONSE.load(PaOrdering::Relaxed);
            if iters == 0 {
                fields.push(("err".to_string(), VsfType::a("decode_timeout".to_string())));
            } else {
                let d = unsafe { DECODE_RESULT };
                // Layout (all LE), 112 bytes total:
                //   16 × u32: elapsed_us, total_iterations, status, frac_bits, acquisition_slot_iter, final_interval_fp, hi_count, hi_min_iter, hi_max_iter, lo_count, lo_min_iter, lo_max_iter, slots_total, bits_decoded, ones, zeros
                //   2 × u64: hi_sum_iter, lo_sum_iter
                //   4 × u64: recent_bits[]
                let cap = 16 * 4 + 2 * 8 + 4 * 8;
                let mut payload = alloc::vec::Vec::with_capacity(cap);
                payload.extend_from_slice(&d.elapsed_us.to_le_bytes());
                payload.extend_from_slice(&d.total_iterations.to_le_bytes());
                payload.extend_from_slice(&d.status.to_le_bytes());
                payload.extend_from_slice(&d.frac_bits.to_le_bytes());
                payload.extend_from_slice(&d.acquisition_slot_iter.to_le_bytes());
                payload.extend_from_slice(&d.final_interval_fp.to_le_bytes());
                payload.extend_from_slice(&d.hi_count.to_le_bytes());
                payload.extend_from_slice(&d.hi_sum_iter.to_le_bytes());
                payload.extend_from_slice(&d.hi_min_iter.to_le_bytes());
                payload.extend_from_slice(&d.hi_max_iter.to_le_bytes());
                payload.extend_from_slice(&d.lo_count.to_le_bytes());
                payload.extend_from_slice(&d.lo_sum_iter.to_le_bytes());
                payload.extend_from_slice(&d.lo_min_iter.to_le_bytes());
                payload.extend_from_slice(&d.lo_max_iter.to_le_bytes());
                payload.extend_from_slice(&d.slots_total.to_le_bytes());
                payload.extend_from_slice(&d.bits_decoded.to_le_bytes());
                payload.extend_from_slice(&d.ones.to_le_bytes());
                payload.extend_from_slice(&d.zeros.to_le_bytes());
                for v in &d.recent_bits {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
            }
        }
        "load_dev" => {
            // Hot-reload a dev image into SRAM. `n` = image size, `did` = BLAKE3.
            // handle_frames streams `size` raw bytes into SRAM at DEV_IMAGE_DEST,
            // hashes the staged SRAM, verifies against `did`, and jumps on match.
            // Reject here on bad size or wrong hash length so the host never enters
            // the streaming phase for a doomed transfer.
            let size_u64 = n_arg;
            let hash_bytes = cmd
                .get("did")
                .ok()
                .and_then(|vs| vs.first().cloned())
                .and_then(|v| match v {
                    VsfType::hp(b) => Some(b),
                    _ => None,
                });
            if size_u64 == 0 || size_u64 > DEV_IMAGE_MAX_BYTES as u64 {
                fields.push(("err".to_string(), VsfType::a("bad_size".to_string())));
            } else if hash_bytes.as_ref().map(|b| b.len()) != Some(32) {
                fields.push(("err".to_string(), VsfType::a("bad_hash".to_string())));
            } else {
                LOAD_DEV_SIZE.store(size_u64 as u32, PaOrdering::Relaxed);
                LOAD_DEV_ID.store(id, PaOrdering::Relaxed);
                unsafe {
                    (&raw mut LOAD_DEV_HASH).copy_from_nonoverlapping(
                        hash_bytes.as_ref().unwrap().as_ptr() as *const [u8; 32],
                        1,
                    );
                }
                pending_action = PostAction::LoadDev;
                fields.push(("op".to_string(), VsfType::a("load_dev_ready".to_string())));
            }
        }
        _ => {
            fields.push(("err".to_string(), VsfType::a("unknown_op".to_string())));
        }
    }

    // Only attach a creation_time if we have an anchor; clockless responses honestly omit the `e` field.
    let mut builder = VsfBuilder::new().version(7, 7).provenance_only();
    if let Some(et) = next_eagle_time() {
        builder = builder.creation_time_oscillations(et as i64);
    }
    let doc = builder.add_section("pipe_message", fields).build();
    let bytes = match doc {
        Ok(b) => b,
        Err(_) => return (0, PostAction::None),
    };
    if bytes.len() > output.len() {
        return (0, PostAction::None);
    }
    output[..bytes.len()].copy_from_slice(&bytes);
    (bytes.len(), pending_action)
}
