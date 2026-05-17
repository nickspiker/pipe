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
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
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

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    info!("pipe-bridge-rp2040 boot");

    // ---- GPIO setup ------------------------------------------------------
    // GP0 = the wire output. Phase 2 will hand this to PIO; for now it's a
    // plain GPIO bit-banged by the USB task.
    let mut wire = Output::new(p.PIN_0, Level::Low);

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

    // ---- Run USB device task + echo+bit-bang loop concurrently ----------
    let usb_fut = usb.run();
    let echo_fut = async {
        loop {
            class.wait_connection().await;
            info!("host connected");
            let _ = echo(&mut class, &mut wire).await;
            info!("host disconnected");
        }
    };

    embassy_futures::join::join(usb_fut, echo_fut).await;
}

struct Disconnected {}

impl From<EndpointError> for Disconnected {
    fn from(val: EndpointError) -> Self {
        match val {
            EndpointError::BufferOverflow => panic!("Buffer overflow"),
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
