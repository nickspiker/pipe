//! Live PIPE wire monitor. Continuously samples the wire and redraws a status panel showing frequency, edge count, current pin state, and capture rate. Refreshes a few times per second; quit with Ctrl-C.

use pipe_host::{
    cdr,
    ft232h::{Ft232h, PIPE_ADBUS_BIT},
};
use std::io::Write;
use std::time::{Duration, Instant};

const MPSSE_CLOCK_HZ: u32 = 6_000_000;
const SAMPLES_PER_PASS: usize = 4096; // ~2.7 ms of capture at within-batch rate
const REFRESH_DELAY: Duration = Duration::from_millis(200);

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut ft = Ft232h::open(MPSSE_CLOCK_HZ)?;
    // Throw away the first batch — first read after open contains the 0xFA/0xAB bad-cmd echo from MPSSE sync.
    let _ = ft.sample_low(64)?;

    print!("\x1b[2J");
    std::io::stdout().flush().ok();

    let started = Instant::now();
    let mut frame: u64 = 0;
    loop {
        let t0 = Instant::now();
        // FT232H MPSSE response buffer is ~1 KB; chunk to keep the chip from stalling.
        let mut samples = Vec::with_capacity(SAMPLES_PER_PASS);
        for _ in 0..(SAMPLES_PER_PASS / 256) {
            let chunk = ft.sample_low(256)?;
            if chunk.is_empty() {
                break;
            }
            samples.extend_from_slice(&chunk);
        }
        let capture_dt = t0.elapsed();

        let n = samples.len();
        let rate_hz = if capture_dt.as_secs_f64() > 0.0 {
            (n as f64 / capture_dt.as_secs_f64()) as u32
        } else {
            0
        };

        let (active_bit, active_edges) = cdr::detect_active_pin(&samples);
        let wire_edges = cdr::count_edges(&samples, PIPE_ADBUS_BIT);
        let wire_freq = cdr::frequency_hz(wire_edges, n, rate_hz);
        let last_byte = samples.last().copied().unwrap_or(0);
        let bit_now = (last_byte >> PIPE_ADBUS_BIT) & 1;

        // Repaint: home cursor, clear from cursor down, draw panel.
        print!("\x1b[H\x1b[J");
        println!("┌─ PIPE wire monitor ──────────────────────────────────────┐");
        println!(
            "│ uptime        {:>8.1} s                                  │",
            started.elapsed().as_secs_f64()
        );
        println!(
            "│ frame         {:>8}                                      │",
            frame
        );
        println!(
            "│ samples       {:>8} in {:>5.1} ms  ({:.2} Msps)            │",
            n,
            capture_dt.as_secs_f64() * 1000.0,
            rate_hz as f64 / 1.0e6
        );
        println!("├──────────────────────────────────────────────────────────┤");
        println!(
            "│ wire ADBUS{}   freq {:>8.0} Hz   edges {:>5}             │",
            PIPE_ADBUS_BIT, wire_freq, wire_edges
        );
        println!(
            "│ pin level     {}                                          │",
            if bit_now == 1 { "HIGH" } else { "low " }
        );
        println!("├──────────────────────────────────────────────────────────┤");
        println!(
            "│ noisiest pin  ADBUS{}  ({} edges)                         │",
            active_bit, active_edges
        );
        println!("└──────────────────────────────────────────────────────────┘");
        println!("Ctrl-C to exit.");
        std::io::stdout().flush().ok();

        frame += 1;
        std::thread::sleep(REFRESH_DELAY);
    }
}
