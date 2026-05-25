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

/// Lock detector threshold (cycles). |phase_err| below this is "in lock"; we need
/// SYNC_LOCK_HOLD_EDGES consecutive in-lock edges to flip the locked flag. At 125 MHz
/// SYSTICK that's ±64 ns ≈ ±2% of slot at the current 170 kHz wire. Adjust if a slower
/// wire wants a tighter threshold or a noisier one wants slack.
const SYNC_LOCK_THRESHOLD_CYC: i32 = 8;
/// Consecutive in-lock edges required before declaring locked. 256 = one exchange's
/// worth — matches the per-exchange convergence design (P shifted ~1/256 per edge so
/// a 1-iter error converges in one exchange).
const SYNC_LOCK_HOLD_EDGES: u32 = 256;

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
static SYNC_RESPONSE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

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
#[inline(always)]
fn pio_edge_read_until(deadline_us: u64, start: embassy_time::Instant) -> Option<u32> {
    use embassy_rp::pac::PIO0;
    while (PIO0.fstat().read().rxempty() & (1 << PIO_EDGE_SM)) != 0 {
        if start.elapsed().as_micros() > deadline_us {
            return None;
        }
    }
    Some(PIO0.rxf(PIO_EDGE_SM).read())
}

fn fast_sync(max_iter: u32, frac_bits: u32, settle_iter: u32, p_shift: u32) -> SyncResult {
    let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);
    let start = embassy_time::Instant::now();

    // PIO0 SM0 captures every edge's interval (cycles since previous edge of either
    // polarity) at 2 sys_clk resolution. The CPU pops words from the RX FIFO and feeds
    // them straight into the same cross-polarity tracker the polling version uses.
    // The `iter` counter is now edge-indexed, not poll-indexed.
    pio_edge_init();
    let initial = pio_edge_start();

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
    let mut consec_in_lock_rise: u32 = 0;
    let mut consec_in_lock_fall: u32 = 0;
    let mut rise_locked: bool = false;
    let mut fall_locked: bool = false;
    let mut locked: bool = false;
    let mut edges_seen: u32 = 0;
    let mut edges_to_lock: u32 = u32::MAX;

    while iter < max_edges {
        let raw = match pio_edge_read_until(wall_cap_us, start) {
            Some(r) => r,
            None => break,
        };
        iter += 1;

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
                acquisition_slot_cyc_low = (acq_sum_low >> SYNC_ACQ_SHIFT_PER_POLARITY) as u32;
                acquisition_slot_cyc_high = (acq_sum_high >> SYNC_ACQ_SHIFT_PER_POLARITY) as u32;
                interval_fp_low = acquisition_slot_cyc_low << frac_bits;
                interval_fp_high = acquisition_slot_cyc_high << frac_bits;
                acquisition_done = true;
                acquisition_iter_count = iter;
            }
            continue;
        }

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
        let n_slots: i32 = if own_cyc < slot + half_slot { 1 }
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
        let slew = if shift >= 0 { phase_err << shift } else { phase_err >> -shift };
        let new_fp = interval_fp_self.wrapping_add_signed(slew);
        if rising {
            interval_fp_low = new_fp;
        } else {
            interval_fp_high = new_fp;
        }

        // RX bit decode. Each edge with n_slots gap = (n_slots - 1) quiet slots
        // (bit 0) followed by this transition slot (bit 1). Shift the buffer left
        // by n_slots and OR the trailing 1 — the n_slots-1 leading zeros come for
        // free because shifting in clears the new low bits.
        bits_buffer = bits_buffer.wrapping_shl(n_slots as u32) | 1;
        bits_decoded = bits_decoded.saturating_add(n_slots as u32);

        edges_seen += 1;
        let in_threshold = phase_err.abs() <= SYNC_LOCK_THRESHOLD_CYC;
        if rising {
            if in_threshold {
                consec_in_lock_rise = consec_in_lock_rise.saturating_add(1);
                if consec_in_lock_rise >= SYNC_LOCK_HOLD_EDGES { rise_locked = true; }
            } else {
                consec_in_lock_rise = 0;
                rise_locked = false;
            }
        } else {
            if in_threshold {
                consec_in_lock_fall = consec_in_lock_fall.saturating_add(1);
                if consec_in_lock_fall >= SYNC_LOCK_HOLD_EDGES { fall_locked = true; }
            } else {
                consec_in_lock_fall = 0;
                fall_locked = false;
            }
        }
        if !locked && rise_locked && fall_locked {
            locked = true;
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

            // Post-acquisition gated phase detector with continuous P (gain 1/512). At most one adjustment per slot — first qualifying edge wins. iter_in_slot_fp is the error signal: V=0 is the target (boundary aligned with wire transition).
            //
            // Two cases based on which side of V the edge falls:
            //   V SMALL (<= half): edge happened just past our boundary in the new slot. Our clock fired too soon — slow down. Expected polarity = transition INTO new slot (slot_phase has already toggled): slot_phase==0 (now enclave) → rising; slot_phase==1 (now host) → falling. signed_offset = V (positive); adj = V >> 9 (positive); interval_fp += adj.
            //   V LARGE (> half): edge happened in the second half of the current slot, BEFORE our boundary. Our clock period is too long — speed up. Expected polarity = transition OUT of current slot: slot_phase==0 (enclave ending) → falling; slot_phase==1 (host ending) → rising. signed_offset = V - interval_eff (negative); adj = signed_offset >> 9 (negative); interval_fp += adj → decreases.
            //
            // Polarity check rejects edges from wrong-direction transitions (noise, RC ringing, real protocol data bits mid-slot). Continuous P with target=0 has no bias at perfect lock — adj == 0 when V == 0. Gain 1/512 = slot/512 per qualifying edge, well below the slot/256 cap from crypto's 256-bit max-run guarantee. Skips chasing every edge: at most one P adjustment per slot, survives long zero-runs in protocol data.
            if phase_anchored && !phase_adj_done {
                let interval_eff_pd = interval_fp.max(8u32 << frac_bits);
                let half_pd = interval_eff_pd >> 1;
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
                        iter_in_slot_fp as i32 - interval_eff_pd as i32
                    };
                    // P gain 1/32 — higher than the user's suggested 1/512, but the loop is undamped (pure P on a phase error → 2nd-order oscillator) so we trade convergence speed against oscillation amplitude. Stronger gain damps oscillation faster.
                    let adj = signed_offset >> 5;
                    interval_fp = (interval_fp as i32).wrapping_add(adj) as u32;
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
        let interval_eff = interval_fp.max(8u32 << frac_bits);
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
            let result = cortex_m::interrupt::free(|_| fast_sync(sync_req, frac_req, settle_req, p_shift_req));
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
    let mut out_buf = [0u8; 2048];
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
            let max_iter = max_iter.min(SYNC_MAX_ITERATIONS).max(SYNC_ACQ_PER_POLARITY * 8);
            let frac_bits = frac_bits.clamp(SYNC_FRAC_BITS_MIN, SYNC_FRAC_BITS_MAX);
            let settle_iter = settle_iter.min(max_iter / 2);
            // Clamp p_shift to a sane range. Lower bound 0 = full iter correction per
            // edge (aggressive, risks oscillation). Upper bound 24 = effective no-op
            // (slew << small for any reasonable phase_err).
            let p_shift = p_shift.min(24);

            SYNC_RESPONSE.store(0, PaOrdering::Relaxed);
            SYNC_FRAC_REQUEST.store(frac_bits, PaOrdering::Relaxed);
            SYNC_SETTLE_REQUEST.store(settle_iter, PaOrdering::Relaxed);
            SYNC_P_SHIFT_REQUEST.store(p_shift, PaOrdering::Relaxed);
            SYNC_REQUEST.store(max_iter, PaOrdering::Release);

            // SYNC_MAX_ITERATIONS = 2^28 = ~45-90 s worst case; 120 s deadline gives margin. USB CDC stays up on core 0 during this because interrupt::free on core 1 doesn't gate core 0's IRQs.
            let deadline = Instant::now() + embassy_time::Duration::from_secs(120);
            while SYNC_RESPONSE.load(PaOrdering::Acquire) == 0 {
                if Instant::now() > deadline {
                    break;
                }
                cortex_m::asm::nop();
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
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
            }
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
