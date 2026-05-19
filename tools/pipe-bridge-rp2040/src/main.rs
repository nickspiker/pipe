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

use defmt::*;
use embassy_executor::{Executor, Spawner};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Drive, Level, Output};
use embassy_rp::multicore::{spawn_core1, Stack};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_usb::class::cdc_acm::{CdcAcmClass, State};
use embassy_usb::driver::EndpointError;
use embassy_usb::{Builder, Config};
use static_cell::StaticCell;
use {defmt_rtt as _, panic_probe as _};

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

    loop {
        // 1. Mix in fresh hardware entropy
        let trng = pac::ROSC.randombit().read().randombit() as u32;
        state ^= trng;

        // 2. Galois LFSR step (Fibonacci-form-equivalent, single conditional XOR)
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

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    info!("pipe-bridge-rp2040 boot");

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
            let _ = echo(&mut class, &mut wire).await;
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

/// Phase 1 loop: read a chunk from USB, toggle the wire GPIO for each byte (LSB-first), echo the bytes back. Replace with the PIO codec in Phase 2.
async fn echo<'d, T: embassy_usb::driver::Driver<'d>>(
    class: &mut CdcAcmClass<'d, T>,
    wire: &mut Output<'_>,
) -> Result<(), Disconnected> {
    let mut buf = [0u8; 64];
    loop {
        let n = class.read_packet(&mut buf).await?;
        for byte in &buf[..n] {
            for bit_idx in 0..8 {
                let bit = (byte >> bit_idx) & 1;
                if bit != 0 {
                    wire.set_high();
                } else {
                    wire.set_low();
                }
                // No precise timing yet — Phase 2 PIO program handles that.
            }
        }
        class.write_packet(&buf[..n]).await?;
    }
}
