//! Wire-side edge counting and frequency measurement.
//!
//! For the TX-only smoke test, the FPGA drives a square wave at slot_rate / 2.
//! Sampling at ~6 Msps, we count transitions on each ADBUS bit, pick the
//! noisiest pin (= the one wired to the FPGA), and convert edge count to Hz.

pub fn count_edges(samples: &[u8], bit_index: u8) -> u64 {
    let mask = 1u8 << bit_index;
    let mut edges = 0u64;
    if samples.is_empty() {
        return 0;
    }
    let mut prev = samples[0] & mask;
    for &b in &samples[1..] {
        let cur = b & mask;
        if cur != prev {
            edges += 1;
        }
        prev = cur;
    }
    edges
}

pub fn frequency_hz(edges: u64, samples: usize, sample_rate_hz: u32) -> f64 {
    if samples == 0 {
        return 0.0;
    }
    let duration_s = samples as f64 / sample_rate_hz as f64;
    (edges as f64) / 2.0 / duration_s
}

/// Scan all 8 ADBUS bits, return (bit_index, edge_count) for the one with the most transitions.
pub fn detect_active_pin(samples: &[u8]) -> (u8, u64) {
    let mut best = (0u8, 0u64);
    for i in 0..8 {
        let e = count_edges(samples, i);
        if e > best.1 {
            best = (i, e);
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_edges_in_constant_stream() {
        let samples = vec![0xFFu8; 100];
        assert_eq!(count_edges(&samples, 0), 0);
    }

    #[test]
    fn every_byte_toggle_counts_as_edges() {
        let samples: Vec<u8> = (0..100).map(|i| if i & 1 == 0 { 0x00 } else { 0x01 }).collect();
        assert_eq!(count_edges(&samples, 0), 99);
        assert_eq!(count_edges(&samples, 1), 0);
    }

    #[test]
    fn frequency_25khz_at_6mhz_sample() {
        // 25 kHz wave at 6 Msps = 240 samples/period = 120 samples/half. Run a
        // long enough capture (60 ms) so boundary-truncation error is < 1%.
        let half = 6_000_000 / 25_000 / 2; // 120
        let total = 60 * 6_000;            // 360_000 samples = 60 ms
        let samples: Vec<u8> = (0..total)
            .map(|i| ((i / half) & 1) as u8)
            .collect();
        let edges = count_edges(&samples, 0);
        let f = frequency_hz(edges, samples.len(), 6_000_000);
        assert!((f - 25_000.0).abs() < 100.0, "got {f} Hz");
    }
}
