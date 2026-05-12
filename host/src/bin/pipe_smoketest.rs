//! TX-only PIPE wire smoke test.
//!
//! Samples ADBUS7 via batched MPSSE GET_BITS_LOW commands, counts edges, and converts to wire frequency. Expected: ~25 kHz (slot rate / 2) at default SLOT_DIV=12.
//!
//! Hardware: FPGA E16 (bridged to F15) → 400 Ω → header D7 → FT232H ADBUS7. Bit-bang doesn't work on this FT232H (blank EEPROM), so we use MPSSE batched polling instead. Effective sample rate ≈ MPSSE_CLOCK_HZ / 5.

use pipe_host::cdr;
use pipe_host::ft232h::{Ft232h, PIPE_ADBUS_BIT};
use std::time::Instant;

const MPSSE_CLOCK_HZ: u32 = 6_000_000;
const BATCH_SAMPLES: usize = 256;
const NUM_BATCHES: usize = 128;
const EXPECTED_HZ: f64 = 25_000.0;
const TOLERANCE: f64 = 0.15;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut ft = Ft232h::open(MPSSE_CLOCK_HZ)?;
    eprintln!(
        "FT232H opened, MPSSE clock = {} MHz",
        ft.mpsse_clock_hz() / 1_000_000
    );

    // Throw away the first batch (contains the 0xFA 0xAB bad-cmd echo).
    let _ = ft.sample_low(64)?;

    // Per-batch capture: time and edge-count each batch independently so the
    // frequency reading isn't poisoned by inter-batch USB gaps.
    let mut total_edges_wire = 0u64;
    let mut total_within_batch_secs = 0.0f64;
    let mut total_samples = 0usize;
    let mut per_bit_edges = [0u64; 8];
    for _ in 0..NUM_BATCHES {
        let t0 = Instant::now();
        let batch = ft.sample_low(BATCH_SAMPLES)?;
        let dt = t0.elapsed();
        if batch.len() < 2 {
            continue;
        }
        total_within_batch_secs += dt.as_secs_f64();
        total_samples += batch.len();
        total_edges_wire += cdr::count_edges(&batch, PIPE_ADBUS_BIT);
        for i in 0u8..8 {
            per_bit_edges[i as usize] += cdr::count_edges(&batch, i);
        }
    }

    let within_batch_rate = total_samples as f64 / total_within_batch_secs;
    eprintln!(
        "Sampled {} bytes across {} batches in {:.1} ms (within-batch ≈ {:.2} Msps)",
        total_samples,
        NUM_BATCHES,
        total_within_batch_secs * 1000.0,
        within_batch_rate / 1_000_000.0
    );
    for (i, &e) in per_bit_edges.iter().enumerate() {
        if e > 0 {
            let f = (e as f64 / 2.0) / total_within_batch_secs;
            eprintln!("  ADBUS{}: {} edges → {:.0} Hz", i, e, f);
        }
    }

    let freq_wire = (total_edges_wire as f64 / 2.0) / total_within_batch_secs;
    let dev = (freq_wire - EXPECTED_HZ).abs() / EXPECTED_HZ;
    if total_edges_wire > 100 && dev <= TOLERANCE {
        println!(
            "PASS: {:.0} Hz on ADBUS{} ({:.1}% from {:.0} Hz)",
            freq_wire,
            PIPE_ADBUS_BIT,
            dev * 100.0,
            EXPECTED_HZ
        );
        Ok(())
    } else {
        println!(
            "FAIL: {:.0} Hz on ADBUS{} ({} edges; {:.1}% from {:.0} Hz)",
            freq_wire,
            PIPE_ADBUS_BIT,
            total_edges_wire,
            dev * 100.0,
            EXPECTED_HZ
        );
        std::process::exit(1);
    }
}
