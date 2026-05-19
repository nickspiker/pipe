//! pipe-bridge-rp2040 — dumb USB-CDC ↔ PIPE wire bridge for RP2040-Zero
//!
//! Phase 1 (this file): scaffolding. USB-CDC enumerates as a serial port; any byte sent over USB toggles the wire GPIO (GP0) and is echoed back over USB. This proves the USB stack + GPIO are alive end-to-end.
//!
//! Phase 2 (next): replace the bit-bang loop with a PIO program implementing the mirror-XOR codec from rtl/codec.v and host/src/codec.rs. PIO runs at sys_clk (125 MHz default) so the ~20 µs slot rate has ~2500 PIO cycles per slot — plenty of headroom.
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
use static_cell::StaticCell;
use {defmt_rtt as _, panic_probe as _};

/// RP2040-Zero flash size (Boya BY25Q16ES = 2 MiB).
const FLASH_SIZE: usize = 2 * 1024 * 1024;

/// BLAKE3 domain string for the device public ID. Bumping the version invalidates
/// all prior IDs, so treat it as part of the on-the-wire identity contract.
const DEVICE_ID_DOMAIN: &str = "ferros bridge rp2040-zero device id v1";

/// Firmware semantic version. Bump on every flash; `info` reports it.
const FW_VERSION: u64 = 2;

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
    //   IDLE  → run LFSR flat-out, check atomic each iter (one cheap load)
    //   TX/RX → set LED, then await Signal — core 1 sleeps, zero CPU
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
                // IDLE: ripping Galois LFSR until state leaves IDLE
                while USB_STATE.load(Ordering::Relaxed) == STATE_IDLE {
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
            }
        }
    }
}

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
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
    // GP0 = the wire output. Phase 2 will hand this to PIO; for now it's a
    // plain GPIO bit-banged by the USB task.
    let mut wire = Output::new(p.PIN_0, Level::Low);

    // GP25 = external heartbeat LED. Direct-soldered (no series resistor)
    // at 2 mA drive strength — pin's own current limit replaces the resistor.
    // Ownership of `heartbeat` is moved to core 1 below.
    let mut heartbeat = Output::new(p.PIN_25, Level::Low);
    heartbeat.set_drive_strength(Drive::_2mA);

    // Launch core 1 with its own executor running the Geiger task.
    // Core 0 stays focused on USB + the echo/bit-bang loop.
    spawn_core1(
        p.CORE1,
        unsafe { &mut *core::ptr::addr_of_mut!(CORE1_STACK) },
        move || {
            let executor1 = EXECUTOR1.init(Executor::new());
            executor1.run(|spawner| {
                spawner.spawn(geiger_task(heartbeat)).unwrap();
            });
        },
    );

    // Onboard WS2812 RGB LED is on GP16 — not driven by this scaffold.

    // ---- USB stack -------------------------------------------------------
    let driver = Driver::new(p.USB, Irqs);

    let mut config = Config::new(0x1209, 0x000C); // pid.codes test VID/PID — fine for development
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

    // ---- Run USB + echo on core 0 (Geiger lives on core 1) --------------
    let usb_fut = usb.run();
    let echo_fut = async {
        loop {
            class.wait_connection().await;
            info!("host connected");
            let _ = handle_frames(&mut class, &mut wire, device_id).await;
            info!("host disconnected");
        }
    };

    // (heartbeat_fut moved to core 1 as `geiger_task` above)
    #[allow(unused)]
    let _placeholder = async {
        // Geiger LED, BLAKE3-XOF conditioned version.
        //
        // Raw ROSC RANDOMBIT is biased and looks visibly periodic (single ring,
        // no health checks, no conditioner — RP2040 datasheet explicitly says
        // it's not crypto-grade). Fix: gather 32 bytes of raw ROSC entropy at
        // boot, BLAKE3-hash to seed an XOF (extendable output function), then
        // pull a fresh uniform-random 32-byte block per tick.
        //
        // Threshold logic on the full 256-bit XOF block (big-endian):
        //   value < 2^250  (top 6 bits zero ⇔ buf[0] < 4)  → turn OFF  ~1.56%
        //   value < 2^248  (top 8 bits zero ⇔ buf[0] == 0) → turn ON   ~0.39%
        // When both fire (buf[0]==0), turn-on runs second and wins.
        //
        // unused — kept so the type-checker has a valid future to drop later
    };

    embassy_futures::join::join(usb_fut, echo_fut).await;
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
///   request:   [d"cmd"(d"op":l"<name>")(d"id":u<n>)...optional args...]
///   response:  [d"resp"(d"id":u<n>)(d"op":l"<reply>")...optional fields...]
///   error:     [d"resp"(d"id":u<n>)(d"err":l"<reason>")]
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
    _wire: &mut Output<'_>,
    device_id: &'static [u8; 32],
) -> Result<(), Disconnected> {
    // `in_buf` is one CDC packet (host commands are small — current largest is
    // ~24 bytes). `out_buf` is sized for the biggest response (`info` ≈ 133 B
    // with the 32-byte device hash) plus headroom for future fields.
    let mut in_buf = [0u8; 64];
    let mut out_buf = [0u8; 256];
    const MAX_PACKET: usize = 64;
    loop {
        let n = class.read_packet(&mut in_buf).await?;
        if n == 0 {
            continue;
        }

        // USB activity → core 1 holds LED high during processing
        USB_STATE.store(STATE_TX, Ordering::Relaxed);
        WAKE_SIGNAL.signal(());

        let (resp_len, action) = dispatch(&in_buf[..n], &mut out_buf, device_id);

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

/// Parse one VSF "cmd" section from `input`, dispatch, encode response into
/// `output`. Returns `(response_length, post_action)`; a zero length means the
/// frame was malformed and is silently dropped (host can retry).
fn dispatch(
    input: &[u8],
    output: &mut [u8],
    device_id: &[u8; 32],
) -> (usize, PostAction) {
    use vsf_mini::{VsfReader, VsfWriter};

    let mut reader = VsfReader::new(input);

    // Expect '[' section open
    if reader.read_byte_raw() != Some(b'[') {
        return (0, PostAction::None);
    }

    // Section name must be "cmd"
    let section_name = match reader.dict_key_str() {
        Some(s) => s,
        None => return (0, PostAction::None),
    };
    if section_name != "cmd" {
        return (0, PostAction::None);
    }

    // Walk fields until ']'
    let mut op_buf = [0u8; 16];
    let mut op_len = 0usize;
    let mut id: u64 = 0;
    // `n` is per-command arg (e.g. random byte count). 0 → use op's default.
    let mut n_arg: u64 = 0;
    loop {
        match reader.peek_tag() {
            Some(b'(') => {
                reader.read_byte_raw();
                let field_name = match reader.dict_key_str() {
                    Some(s) => s,
                    None => return (0, PostAction::None),
                };
                if reader.read_byte_raw() != Some(b':') {
                    return (0, PostAction::None);
                }
                match field_name {
                    "op" => {
                        let bytes = match reader.label() {
                            Some(b) => b,
                            None => return (0, PostAction::None),
                        };
                        if bytes.len() > op_buf.len() {
                            return (0, PostAction::None);
                        }
                        op_buf[..bytes.len()].copy_from_slice(bytes);
                        op_len = bytes.len();
                    }
                    "id" => {
                        id = reader.uint().unwrap_or(0);
                    }
                    "n" => {
                        n_arg = reader.uint().unwrap_or(0);
                    }
                    _ => {
                        if !reader.skip_field() {
                            return (0, PostAction::None);
                        }
                    }
                }
                if reader.read_byte_raw() != Some(b')') {
                    return (0, PostAction::None);
                }
            }
            Some(b']') => {
                reader.read_byte_raw();
                break;
            }
            _ => return (0, PostAction::None),
        }
    }

    let op = &op_buf[..op_len];

    // Action commands send no response — the disconnect is the answer.
    match op {
        b"bootsel" => return (0, PostAction::BootSel),
        b"reset" => return (0, PostAction::Reset),
        _ => {}
    }

    // Data commands: build a "resp" section.
    let mut writer = VsfWriter::new(output);
    if !writer.section_open("resp") {
        return (0, PostAction::None);
    }
    if !(writer.field_open("id") && writer.uint(id) && writer.field_close()) {
        return (0, PostAction::None);
    }

    let up_ms = Instant::now().as_millis();
    let ok = match op {
        b"ping" => {
            writer.field_open("op") && writer.label("pong") && writer.field_close()
        }
        b"info" => {
            writer.field_open("name")
                && writer.label("pipe-bridge-rp2040")
                && writer.field_close()
                && writer.field_open("ver")
                && writer.uint(FW_VERSION)
                && writer.field_close()
                && writer.field_open("did")
                && writer.hash_p(device_id)
                && writer.field_close()
                && writer.field_open("clk")
                && writer.uint(embassy_rp::clocks::clk_sys_freq() as u64)
                && writer.field_close()
                && writer.field_open("up")
                && writer.uint(up_ms)
                && writer.field_close()
        }
        b"uptime" => {
            writer.field_open("ms") && writer.uint(up_ms) && writer.field_close()
        }
        b"random" => {
            // Default to 32 bytes if no `n` arg; cap at 32 to fit in 64-byte CDC packet
            // alongside the surrounding section/field framing (~14 bytes overhead).
            let count = if n_arg == 0 { 32 } else { n_arg.min(32) } as usize;
            let mut buf = [0u8; 32];
            gather_random(&mut buf[..count]);
            writer.field_open("data") && writer.blob(&buf[..count]) && writer.field_close()
        }
        _ => writer.field_open("err") && writer.label("unknown_op") && writer.field_close(),
    };
    if !ok {
        return (0, PostAction::None);
    }

    if !writer.section_close() {
        return (0, PostAction::None);
    }
    (writer.pos(), PostAction::None)
}
