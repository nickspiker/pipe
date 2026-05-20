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

use defmt::*;
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
use {defmt_rtt as _, panic_probe as _};

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
#[derive(Clone, Copy)]
enum PostAction {
    None,
    BootSel,
    Reset,
}

// Shared LED-state flag between core 0 (USB task) and core 1 (geiger task).
//   STATE_IDLE → geiger runs normally (no USB activity right now)
//   STATE_TX   → core 1 forces LED ON  (host → bridge → wire)
//   STATE_RX   → core 1 forces LED OFF (wire → bridge → host)
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
// Wire sync — bang-bang PLL with per-polarity phase anchoring.
//
// The RC asymmetry on the wire (driver charges through ~800Ω fast, pull-down discharges through 5kΩ slow) means rising and falling threshold crossings sit at *different* offsets from the true slot boundary. A single mixed-polarity anchor inevitably locks to one polarity and rejects the other as half-slot-offset. Solution: each polarity has its own phase anchor (iter_since_rise / iter_since_fall, both increment every iteration); each accepted edge measures its own polarity's mod-folded interval against the shared slot estimate, both polarities contribute ±1 slews to the same `interval`.
//
// ACQUISITION: 256 mixed-polarity inter-edge intervals seed interval = (sum / 256) << FRAC_BITS. Polarity-specific counters reset to zero on the first own-polarity edge after acquisition completes.
//
// TRACKING per polarity P (P ∈ {rising, falling}):
//   slot = interval >> 11
//   n_slots = round(iter_since_P / slot)                  // typically 2 in idle (rise→rise spans 2 slots)
//   phase_err = iter_since_P - n_slots * slot             // residual within slot grid
//   if |phase_err| < slot/8:
//     interval ± 1 (sign, ±1 deadband)
//     iter_since_P = 0; record signed phase_err
//     // ALSO: mod-fold iter_since_OTHER against slot; residual = RC offset contribution
//     rc_offset_sum_from_P += residual
//   else: reject this polarity for this edge (anchor stays)
//
// RC OFFSET MEASUREMENT: at falling acceptance, iter_since_rise gives time-since-last-rising. In idle that's ideally 1 slot; with RC, it's 1*slot + (rc_fall - rc_rise) = slot + Δrc. Mod-fold against slot, residual ≈ Δrc. At rising acceptance, iter_since_fall residual ≈ -Δrc. Difference between the two means = 2*Δrc directly, in iter units. This is the bridge-side measurement of the slot-grid offset between rising and falling threshold crossings.
//
// FIXED-POINT: interval is u32 with 11 frac bits (1/256 P × 1/8 window = 1/2048 = 2^11). Each ±1 step on interval = slot/2048 — bang-bang slew rate cap. 2048 same-direction accepts to shift integer slot by 1 iter — way above any realistic PVT drift rate.
//
// LOOP DISCIPLINE: body must stay constant-time per iter for the iter ↔ wall-time mapping to hold. Lives inside interrupt::free.
// ---------------------------------------------------------------------------
const SYNC_ACQ_EDGES: u32 = 256;
/// Fractional bits below the integer slot_cycles value. Each ±1 step on `interval` slews slot_cycles by 1/2^FRAC of a slot. Tune to trade P-gain for noise immunity: 11 = slot/2048 per edge (default), bigger = quieter/slower, smaller = faster/jitterier.
const SYNC_FRAC_BITS: u32 = 11;
/// Hard cap on inner-loop iterations to bound wall time even if the wire is dead. At ~24 MS/s ≈ 42 ns/iter, 2^22 ≈ 175 ms.
const SYNC_MAX_ITERATIONS: u32 = 1 << 22;
/// Per-polarity histogram bin count for signed phase_err. Centered on zero, covers ±SYNC_HIST_HALF_RANGE iter at 1-iter resolution. Edges beyond go to per-polarity overflow counters.
const SYNC_HIST_BINS: usize = 256;
const SYNC_HIST_HALF_RANGE: i32 = (SYNC_HIST_BINS as i32) / 2; // = 128, range is [-128, +127]

#[repr(C)]
#[derive(Clone, Copy)]
struct SyncResult {
    elapsed_us: u32,
    total_iterations: u32,
    /// 0 = locked OK, 1 = ran out of iterations during acquisition, 2 = no edge ever seen.
    status: u32,
    /// Initial mean inter-edge interval after acquisition (raw iter, not fixed-point).
    acquisition_slot_cycles: u32,
    /// Final `interval` value (fixed-point, SYNC_FRAC_BITS frac bits). Integer slot_cycles = final_interval_fp >> SYNC_FRAC_BITS.
    final_interval_fp: u32,
    /// Per-polarity tracking edge counts (no rejection — every edge counts).
    rising_total: u32,
    falling_total: u32,
    /// Edges with phase_err outside the histogram range [-HALF, +HALF). Per polarity per sign.
    rising_neg_overflow: u32,
    rising_pos_overflow: u32,
    falling_neg_overflow: u32,
    falling_pos_overflow: u32,
    /// Signed sum of phase_err (iter units) across all tracking edges, both polarities. Trends to zero in steady state — diagnostic for lock convergence.
    phase_sum: i64,
    /// RC offset measurement. At rising slew, fold iter_since_fall against slot → residual ≈ -Δrc. At falling slew, fold iter_since_rise → residual ≈ +Δrc. Means subtracted give 2*Δrc.
    fall_to_rise_offset_sum: i64,
    rise_to_fall_offset_sum: i64,
    /// Per-polarity signed phase_err histogram. Bin i covers phase_err = i - SYNC_HIST_HALF_RANGE iter. u16 holds up to 65k edges per bin — well above any per-bin density at our edge rates.
    rising_hist: [u16; SYNC_HIST_BINS],
    falling_hist: [u16; SYNC_HIST_BINS],
}

static mut SYNC_RESULT: SyncResult = SyncResult {
    elapsed_us: 0,
    total_iterations: 0,
    status: 0,
    acquisition_slot_cycles: 0,
    final_interval_fp: 0,
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
};

static SYNC_REQUEST: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);
static SYNC_RESPONSE: portable_atomic::AtomicU32 = portable_atomic::AtomicU32::new(0);

/// Host-side mirror-XOR codec, byte-identical to host/src/codec.rs. Inlined here to keep the firmware crate self-contained for now; once the codec is stable we'll lift it into a shared `pipe_codec` crate that both host and firmware import. Not currently used in the runtime — the slot loop was nuked along with the hardcoded SLOT_US, and the next iteration will plug Codec back in driven by wire_sync's locked slot_cycles.
#[allow(dead_code)]
struct Codec {
    own_idle: u8,
    other_idle: u8,
    own_last: u8,
    other_last: u8,
}

#[allow(dead_code)]
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

/// CDR sync loop. Caller MUST run inside `cortex_m::interrupt::free` — the per-iteration↔wall-time mapping requires no IRQ preemption. `max_iter` caps wall time even if the wire is silent.
fn fast_sync(max_iter: u32) -> SyncResult {
    let max_iter = max_iter.min(SYNC_MAX_ITERATIONS);
    let gpio_in: *const u32 = embassy_rp::pac::SIO.gpio_in(0).as_ptr();
    let start = embassy_time::Instant::now();

    let mut prev: u32 = unsafe { gpio_in.read_volatile() & 1 };
    let mut iter: u32 = 1;
    let mut edge_count: u32 = 0;
    let mut any_anchored: bool = false;

    // Acquisition (mixed-polarity sum of inter-edge intervals, mean = 1 slot in idle).
    let mut iter_since_any_edge: u32 = 0;
    let mut acq_sum: u64 = 0;
    let mut acquisition_slot_cycles: u32 = 0;

    // Per-polarity tracking counters. Increment every iter regardless of edges.
    let mut iter_since_rise: u32 = 0;
    let mut iter_since_fall: u32 = 0;
    let mut rise_anchored: bool = false;
    let mut fall_anchored: bool = false;

    // Shared slot estimate (fixed-point, SYNC_FRAC_BITS frac bits).
    let mut interval_fp: u32 = 0;

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

    while iter < max_iter {
        let cur = unsafe { gpio_in.read_volatile() & 1 };
        iter += 1;
        iter_since_any_edge += 1;
        iter_since_rise += 1;
        iter_since_fall += 1;
        if cur != prev {
            let rising = cur == 1;
            prev = cur;
            if !any_anchored {
                any_anchored = true;
                iter_since_any_edge = 0;
                continue;
            }
            edge_count += 1;
            if edge_count <= SYNC_ACQ_EDGES {
                // Acquisition: sum mixed-polarity intervals; seed interval_fp at the boundary edge.
                acq_sum += iter_since_any_edge as u64;
                iter_since_any_edge = 0;
                if edge_count == SYNC_ACQ_EDGES {
                    acquisition_slot_cycles = (acq_sum / SYNC_ACQ_EDGES as u64) as u32;
                    interval_fp = acquisition_slot_cycles << SYNC_FRAC_BITS;
                    // Anchor on whichever polarity this last acquisition edge was.
                    if rising {
                        iter_since_rise = 0;
                        rise_anchored = true;
                    } else {
                        iter_since_fall = 0;
                        fall_anchored = true;
                    }
                }
            } else {
                // Tracking. Per-polarity anchor + mod-fold against own counter. No rejection — every edge slews and counts.
                let slot = (interval_fp >> SYNC_FRAC_BITS) as i32;
                if slot < 8 {
                    // Defensive — slot estimate collapsed; bump overflow and skip.
                    if rising { rising_pos_overflow += 1 } else { falling_pos_overflow += 1 };
                    continue;
                }
                let half_slot = slot / 2;

                let own_anchored = if rising { rise_anchored } else { fall_anchored };
                if !own_anchored {
                    // First edge of this polarity post-acquisition; just anchor it.
                    if rising {
                        iter_since_rise = 0;
                        rise_anchored = true;
                        rising_total += 1;
                    } else {
                        iter_since_fall = 0;
                        fall_anchored = true;
                        falling_total += 1;
                    }
                    continue;
                }

                let own_iter = if rising { iter_since_rise as i32 } else { iter_since_fall as i32 };
                let mut n_slots = (own_iter + half_slot) / slot;
                if n_slots == 0 {
                    n_slots = 1;
                }
                let expected = n_slots * slot;
                let phase_err = own_iter - expected;

                // Always slew on sign (no deadband). Float onto the actual lock.
                if phase_err > 0 {
                    interval_fp = interval_fp.wrapping_add(1);
                } else if phase_err < 0 {
                    interval_fp = interval_fp.wrapping_sub(1);
                }
                phase_sum += phase_err as i64;

                // Bin phase_err into per-polarity histogram (±HALF_RANGE iter, 1-iter resolution).
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

                // RC offset using the OTHER polarity's counter (folded against slot).
                let other_iter = if rising { iter_since_fall as i32 } else { iter_since_rise as i32 };
                let other_anchored = if rising { fall_anchored } else { rise_anchored };
                if other_anchored {
                    let mut o_n = (other_iter + half_slot) / slot;
                    if o_n == 0 { o_n = 1; }
                    let o_residual = other_iter - o_n * slot;
                    if rising {
                        fall_to_rise_offset_sum += o_residual as i64;
                    } else {
                        rise_to_fall_offset_sum += o_residual as i64;
                    }
                }

                if rising {
                    rising_total += 1;
                    iter_since_rise = 0;
                } else {
                    falling_total += 1;
                    iter_since_fall = 0;
                }
            }
        }
    }

    let status: u32 = if !any_anchored {
        2
    } else if edge_count < SYNC_ACQ_EDGES {
        1
    } else {
        0
    };

    if status == 1 && edge_count > 0 {
        acquisition_slot_cycles = (acq_sum / edge_count as u64) as u32;
        interval_fp = acquisition_slot_cycles << SYNC_FRAC_BITS;
    }

    SyncResult {
        elapsed_us: start.elapsed().as_micros() as u32,
        total_iterations: iter,
        status,
        acquisition_slot_cycles,
        final_interval_fp: interval_fp,
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
            let result = cortex_m::interrupt::free(|_| fast_sync(sync_req));
            let iters = result.total_iterations.max(1);
            unsafe {
                SYNC_RESULT = result;
            }
            // Release: pairs with core 0's Acquire on SYNC_RESPONSE.
            SYNC_RESPONSE.store(iters, PaOrdering::Release);
            SYNC_REQUEST.store(0, PaOrdering::Relaxed);
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
    // Heap must come up before anything that allocates (VsfBuilder, etc).
    unsafe { HEAP.init(&raw mut HEAP_MEM as usize, HEAP_SIZE) }

    let p = embassy_rp::init(Default::default());
    info!("pipe-bridge-rp2040 boot");

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
    info!("device_id derived from flash uid={=[u8]:02x}", flash_uid);

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
            info!("host connected");
            let _ = handle_frames(&mut class, device_id).await;
            info!("host disconnected");
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

        // USB activity → core 1 holds LED high during processing
        USB_STATE.store(STATE_TX, Ordering::Relaxed);
        WAKE_SIGNAL.signal(());

        let (resp_len, action) = dispatch(&in_buf[..frame_len], &mut out_buf, device_id);

        if resp_len > 0 {
            USB_STATE.store(STATE_RX, Ordering::Relaxed);
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
        }
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
            // Input: bytes 0..4 = max_iter (u32 LE). Default = SYNC_MAX_ITERATIONS.
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
                SYNC_MAX_ITERATIONS
            };
            let max_iter = max_iter.min(SYNC_MAX_ITERATIONS).max(SYNC_ACQ_EDGES * 8);

            SYNC_RESPONSE.store(0, PaOrdering::Relaxed);
            SYNC_REQUEST.store(max_iter, PaOrdering::Release);

            let deadline = Instant::now() + embassy_time::Duration::from_secs(2);
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
                // Layout (all LE), 1092 bytes (11 × u32 + 3 × i64 + 2 × 256 × u16 hists + bin-count header u32):
                //   u32 elapsed_us, total_iterations, status, frac_bits, acquisition_slot_cycles, final_interval_fp,
                //   u32 rising_total, falling_total,
                //   u32 rising_neg_overflow, rising_pos_overflow, falling_neg_overflow, falling_pos_overflow,
                //   u32 hist_bins, hist_half_range,
                //   i64 phase_sum, fall_to_rise_offset_sum, rise_to_fall_offset_sum,
                //   u16[hist_bins] rising_hist, u16[hist_bins] falling_hist
                let hist_bytes = SYNC_HIST_BINS * 2;
                let cap = 14 * 4 + 3 * 8 + 2 * hist_bytes;
                let mut payload = alloc::vec::Vec::with_capacity(cap);
                payload.extend_from_slice(&s.elapsed_us.to_le_bytes());
                payload.extend_from_slice(&s.total_iterations.to_le_bytes());
                payload.extend_from_slice(&s.status.to_le_bytes());
                payload.extend_from_slice(&SYNC_FRAC_BITS.to_le_bytes());
                payload.extend_from_slice(&s.acquisition_slot_cycles.to_le_bytes());
                payload.extend_from_slice(&s.final_interval_fp.to_le_bytes());
                payload.extend_from_slice(&s.rising_total.to_le_bytes());
                payload.extend_from_slice(&s.falling_total.to_le_bytes());
                payload.extend_from_slice(&s.rising_neg_overflow.to_le_bytes());
                payload.extend_from_slice(&s.rising_pos_overflow.to_le_bytes());
                payload.extend_from_slice(&s.falling_neg_overflow.to_le_bytes());
                payload.extend_from_slice(&s.falling_pos_overflow.to_le_bytes());
                payload.extend_from_slice(&(SYNC_HIST_BINS as u32).to_le_bytes());
                payload.extend_from_slice(&(SYNC_HIST_HALF_RANGE as u32).to_le_bytes());
                payload.extend_from_slice(&s.phase_sum.to_le_bytes());
                payload.extend_from_slice(&s.fall_to_rise_offset_sum.to_le_bytes());
                payload.extend_from_slice(&s.rise_to_fall_offset_sum.to_le_bytes());
                for v in &s.rising_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                for v in &s.falling_hist {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                fields.push(("data".to_string(), VsfType::v(b'b', payload)));
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
    (bytes.len(), PostAction::None)
}
