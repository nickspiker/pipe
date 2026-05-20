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
use embassy_rp::gpio::{Drive, Level, Output};
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
async fn pipe_wire_task(_wire: Output<'static>) {
    loop {
        // Nothing to do until Phase 2. Long sleep to keep the task alive
        // without burning core 1; embassy's time driver handles wake.
        embassy_time::Timer::after_secs(60).await;
    }
}

#[embassy_executor::task]
async fn geiger_task(mut heartbeat: Output<'static>) {
    use blake3::Hasher;
    use embassy_rp::pac;

    const ON_THRESHOLD: u32 = 11 << 17;
    const OFF_THRESHOLD: u32 = 7 << 22;
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

    // Outer state-driven loop:
    //   IDLE  → run LFSR in bursts, yield between bursts so USB gets serviced
    //   TX/RX → set LED, then await Signal — task sleeps, zero CPU
    //
    // The inner LFSR loop CANNOT be tight-spin because geiger shares core 0
    // with the USB + dispatch task; without yields, the executor never polls
    // those futures and the bridge looks bricked on the USB bus. Burst size
    // tuned so the LED still flickers fast enough to look "geiger-counter"
    // (sub-millisecond visual rate) while leaving USB IRQ work plenty of
    // headroom.
    const BURST: u32 = 64;
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
                // IDLE: BURST iterations of LFSR, then yield to let USB run.
                for _ in 0..BURST {
                    if USB_STATE.load(Ordering::Relaxed) != STATE_IDLE {
                        break;
                    }
                    // 1. Mix in fresh hardware entropy
                    let trng = pac::ROSC.randombit().read().randombit() as u32;
                    state ^= trng;

                    // 2. Galois LFSR step (single conditional XOR)
                    let lsb = state & 1;
                    state >>= 1;
                    if lsb != 0 {
                        state ^= GALOIS_TAPS;
                    }

                    // 3. Threshold check on the full 32-bit state
                    if state < ON_THRESHOLD {
                        heartbeat.set_high();
                    } else if state < OFF_THRESHOLD {
                        heartbeat.set_low();
                    }
                }
                embassy_futures::yield_now().await;
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
    // Phase 2: core 1 hands this to a PIO state machine implementing the
    // mirror-XOR codec. Phase 1 (current): core 1 just holds it idle.
    let wire = Output::new(p.PIN_0, Level::Low);

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
    // response (`info` ≈ 180 B with hp + did) plus headroom.
    let mut in_buf = [0u8; 256];
    let mut out_buf = [0u8; 256];
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
