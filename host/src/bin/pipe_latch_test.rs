//! Bidirectional PIPE wire smoke test (host ↔ enclave).
//!
//! Prerequisite: FPGA flashed with `build_pipe_latch.sh --program`. The FPGA continuously samples the wire and drives it with the last sampled value; whatever the host writes persists after the host releases.
//!
//! This test:
//!   1. Sample wire — record V0.
//!   2. Drive wire HIGH for 10 ms, release.
//!   3. Sample — expect HIGH (proves host → FPGA).
//!   4. Drive wire LOW for 10 ms, release.
//!   5. Sample — expect LOW.
//!   6. Drive HIGH again, sample, expect HIGH.
//!
//! All steps via MPSSE on FT232H ADBUS7 (the bit physically connected to the bridged E16/F15 pad thru 400 Ω + header D7).

use pipe_host::ft232h::{Ft232h, PIPE_ADBUS_BIT, PIPE_PIN_MASK};
use std::thread::sleep;
use std::time::Duration;

const MPSSE_CLOCK_HZ: u32 = 6_000_000;
const HOLD_MS: u64 = 20;

fn sample(ft: &mut Ft232h) -> Result<u8, ftdi_nusb::Error> {
    // Read once, but throw away a couple of samples first to let the chip settle after a direction change.
    let _ = ft.sample_low(8)?;
    let s = ft.sample_low(16)?;
    let bit = s.last().copied().unwrap_or(0) & PIPE_PIN_MASK;
    Ok(if bit != 0 { 1 } else { 0 })
}

fn drive(ft: &mut Ft232h, level: u8) -> Result<(), ftdi_nusb::Error> {
    let value = if level != 0 { PIPE_PIN_MASK } else { 0x00 };
    ft.hold_drive(value, PIPE_PIN_MASK, HOLD_MS)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut ft = Ft232h::open(MPSSE_CLOCK_HZ)?;
    eprintln!(
        "FT232H opened, MPSSE clock = {} MHz",
        ft.mpsse_clock_hz() / 1_000_000
    );

    // Drain the FA AB bad-cmd echo from sync_mpsse.
    let _ = ft.sample_low(64)?;

    let v0 = sample(&mut ft)?;
    eprintln!("V0 (initial) = {}", v0);

    let mut pass = true;
    for &target in &[1u8, 0u8, 1u8, 0u8] {
        drive(&mut ft, target)?;
        sleep(Duration::from_millis(2)); // let the wire settle
        let v = sample(&mut ft)?;
        let ok = v == target;
        eprintln!(
            "drove {} for {} ms → sampled {}  {}",
            target,
            HOLD_MS,
            v,
            if ok { "OK" } else { "MISMATCH" }
        );
        if !ok {
            pass = false;
        }
    }

    if pass {
        println!(
            "PASS: host ↔ enclave bidirectional on ADBUS{}",
            PIPE_ADBUS_BIT
        );
        Ok(())
    } else {
        println!("FAIL: latch did not echo host drive — wiring or bitstream issue");
        std::process::exit(1);
    }
}
