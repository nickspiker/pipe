//! Debug-print of the bidir latch behaviour.

use pipe_host::ft232h::{Ft232h, PIPE_PIN_MASK};
use std::thread::sleep;
use std::time::Duration;

const MPSSE_SET_BITS_LOW: u8 = 0x80;
const MPSSE_GET_BITS_LOW: u8 = 0x81;
const MPSSE_SEND_IMMEDIATE: u8 = 0x87;

fn drive_and_sample(
    ft: &mut Ft232h,
    drive_value: u8,
    drive_direction: u8,
    hold_ms: u64,
    label: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Drive the pin to the requested state.
    ft.set_low(drive_value, drive_direction)?;
    sleep(Duration::from_millis(hold_ms));

    // Sample once while still driving.
    let during = single_sample(ft)?;

    // Release (all inputs).
    ft.set_low(0x00, 0x00)?;
    sleep(Duration::from_millis(5));

    // Sample after release.
    let after_5ms = single_sample(ft)?;
    sleep(Duration::from_millis(50));
    let after_55ms = single_sample(ft)?;

    println!(
        "{}: during=0x{:02X} (bit7={})  +5ms=0x{:02X} (bit7={})  +55ms=0x{:02X} (bit7={})",
        label,
        during,
        (during >> 7) & 1,
        after_5ms,
        (after_5ms >> 7) & 1,
        after_55ms,
        (after_55ms >> 7) & 1
    );
    Ok(())
}

fn single_sample(ft: &mut Ft232h) -> Result<u8, ftdi_nusb::Error> {
    let s = ft.sample_low(16)?;
    Ok(s.last().copied().unwrap_or(0))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut ft = Ft232h::open(6_000_000)?;
    let _ = ft.sample_low(64)?; // drain FA AB

    let baseline = single_sample(&mut ft)?;
    println!(
        "baseline (no host drive): 0x{:02X} (bit7={})",
        baseline,
        (baseline >> 7) & 1
    );

    drive_and_sample(&mut ft, PIPE_PIN_MASK, PIPE_PIN_MASK, 50, "drive HIGH 50ms")?;
    drive_and_sample(&mut ft, 0x00, PIPE_PIN_MASK, 50, "drive  LOW 50ms")?;
    drive_and_sample(
        &mut ft,
        PIPE_PIN_MASK,
        PIPE_PIN_MASK,
        200,
        "drive HIGH 200ms",
    )?;
    drive_and_sample(&mut ft, 0x00, PIPE_PIN_MASK, 200, "drive  LOW 200ms")?;

    Ok(())
}

// Just for the unused warning
#[allow(dead_code)]
const _USE: u8 = MPSSE_SET_BITS_LOW | MPSSE_GET_BITS_LOW | MPSSE_SEND_IMMEDIATE;
