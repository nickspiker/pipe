//! Wire-side clock recovery for the PIPE protocol.
//!
//! Provides two layers:
//!   (1) edge-count helpers (`count_edges`, `frequency_hz`, `detect_active_pin`) — used by the TX-only smoke test and for one-shot calibration.
//!   (2) `Cdr` — a bang-bang PLL with ±1-MCLK dead zone, anchored to the enclave's slot boundaries. It locks from idle (host passive, wire shows 1010 from enclave drives + pull-down LOW) and tracks drift through full-duplex traffic where only ~25% of slot boundaries carry E-attributable edges.
//!
//! Edge attribution: the host knows its own emissions per slot (drive vs release). Any edge that can be fully explained by a host-side drive transition is H-controlled and rejected for tracking. The remaining E-controlled edges are what the PLL anchors to.

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

/// Find all edge positions (sample indices where `bit_index` flipped from the previous sample) in a continuous sample stream.
pub fn edge_positions(samples: &[u8], bit_index: u8) -> Vec<usize> {
    let mask = 1u8 << bit_index;
    let mut edges = Vec::new();
    if samples.is_empty() {
        return edges;
    }
    let mut prev = samples[0] & mask;
    for (i, &b) in samples.iter().enumerate().skip(1) {
        let cur = b & mask;
        if cur != prev {
            edges.push(i);
            prev = cur;
        }
    }
    edges
}

// =============================================================================
// PLL-style CDR
// =============================================================================

/// Edge-tracking PLL anchored to the enclave's slot boundaries.
///
/// Time is measured in MPSSE clock cycles (MCLK). Slot period is a fractional value in MCLK. Phase reference is `next_edge_mclks` — the absolute MCLK count where the next E-attributable edge is *predicted* to land.
///
/// `observe_edge` is called for each edge actually seen in the sample stream; pass `is_e_attributable = true` only for edges whose timing is determined by the enclave (i.e., the host did not drive that slot boundary). The PLL nudges its period estimate by ±`step_mclks` if the observed edge falls outside ±`dead_zone_mclks` of the prediction, leaves things alone if within the dead zone, and skips entirely for H-attributable edges.
#[derive(Debug, Clone, Copy)]
pub struct Cdr {
    pub period_mclks: f64,
    pub next_edge_mclks: f64,
    pub last_edge_mclks: f64,
    pub locked: bool,
    pub step_mclks: f64,
    pub dead_zone_mclks: f64,
    pub locked_count: u32,
    pub lock_threshold: u32,
}

impl Cdr {
    /// Initial guess (e.g., from the FPGA's nominal ring osc + SLOT_DIV).
    pub fn new(initial_period_mclks: f64) -> Self {
        Self {
            period_mclks: initial_period_mclks,
            next_edge_mclks: 0.0,
            last_edge_mclks: 0.0,
            locked: false,
            step_mclks: 0.25,
            dead_zone_mclks: 1.0,
            locked_count: 0,
            lock_threshold: 8,
        }
    }

    /// One-shot lock from a sample buffer with the host fully passive. Assumes the wire is showing clean 1010 (enclave drives every E slot HIGH, pull-down holds H slots LOW). Median inter-edge interval becomes the slot period; first edge position becomes the phase reference.
    pub fn lock_from_idle(samples: &[u8], bit_index: u8, sample_start_mclks: u64) -> Option<Self> {
        let edges = edge_positions(samples, bit_index);
        if edges.len() < 8 {
            return None;
        }
        let mut gaps: Vec<usize> = edges.windows(2).map(|w| w[1] - w[0]).collect();
        gaps.sort();
        let median = gaps[gaps.len() / 2] as f64;
        // In idle the wire transitions every slot boundary, so the inter-edge gap = 1 slot period.
        let period = median;
        let first_edge_mclks = sample_start_mclks + edges[0] as u64;
        let last_edge_mclks = sample_start_mclks + (*edges.last().unwrap()) as u64;
        let mut cdr = Self::new(period);
        cdr.last_edge_mclks = last_edge_mclks as f64;
        cdr.next_edge_mclks = last_edge_mclks as f64 + period;
        cdr.locked = true;
        cdr.locked_count = cdr.lock_threshold;
        let _ = first_edge_mclks;
        Some(cdr)
    }

    /// Feed one observed edge. `t_edge_mclks` is the absolute MCLK count of the edge. `is_e_attributable` selects whether the PLL updates (true) or skips (false). The PLL anchors phase to the observed edge (so phase error doesn't accumulate when period is off) and adjusts period from the inter-edge interval normalised by how many slots fit in it.
    pub fn observe_edge(&mut self, t_edge_mclks: u64, is_e_attributable: bool) {
        if !is_e_attributable {
            return;
        }
        let t = t_edge_mclks as f64;
        if self.last_edge_mclks > 0.0 && t > self.last_edge_mclks {
            let interval = t - self.last_edge_mclks;
            // How many slots fit in this interval? Round to nearest integer ≥ 1.
            let n_slots = (interval / self.period_mclks).round().max(1.0);
            let measured_period = interval / n_slots;
            let error = measured_period - self.period_mclks;
            if error > self.dead_zone_mclks {
                self.period_mclks += self.step_mclks;
            } else if error < -self.dead_zone_mclks {
                self.period_mclks -= self.step_mclks;
            }
        }
        self.last_edge_mclks = t;
        self.next_edge_mclks = t + self.period_mclks;
        if self.locked_count < self.lock_threshold {
            self.locked_count += 1;
            if self.locked_count >= self.lock_threshold {
                self.locked = true;
            }
        }
    }

    /// Predict the MCLK count of the next E-slot edge at or after `t_mclks`.
    pub fn next_e_edge_at_or_after(&self, t_mclks: u64) -> u64 {
        let mut p = self.next_edge_mclks;
        while p < t_mclks as f64 {
            p += self.period_mclks;
        }
        p.round() as u64
    }

    pub fn slot_period_mclks(&self) -> f64 {
        self.period_mclks
    }
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
    fn cdr_locks_to_synthetic_idle_pattern() {
        // Simulate idle: 50 kHz wire toggle at 6 Msps MPSSE clock = 120 MCLK/slot.
        // Wire alternates 0,1,0,1 every 120 samples.
        let slot = 120usize;
        let total = slot * 200;
        let samples: Vec<u8> = (0..total).map(|i| ((i / slot) & 1) as u8).collect();
        let cdr = Cdr::lock_from_idle(&samples, 0, 0).expect("should lock");
        assert!(cdr.locked);
        assert!((cdr.period_mclks - 120.0).abs() < 1.0, "got {}", cdr.period_mclks);
    }

    #[test]
    fn cdr_tracks_drifting_clock_via_observed_edges() {
        // Start with an estimate 5% high, then feed edges at the true rate. PLL should converge toward truth.
        let mut cdr = Cdr::new(126.0);
        cdr.last_edge_mclks = 0.0;
        cdr.next_edge_mclks = 120.0;
        // Feed 200 perfect-timing edges at period 120.
        for i in 1..=200u64 {
            let t = i * 120;
            cdr.observe_edge(t, true);
        }
        // PLL settles to within one step of the dead-zone boundary (so 1 MCLK + 0.25 step worst-case from truth).
        assert!((cdr.period_mclks - 120.0).abs() <= 1.5, "drifted to {}", cdr.period_mclks);
    }

    #[test]
    fn cdr_dead_zone_holds_period_with_jittery_input() {
        let mut cdr = Cdr::new(120.0);
        cdr.last_edge_mclks = 0.0;
        cdr.next_edge_mclks = 120.0;
        // Jitter each edge by ±0.7 MCLK — within the dead zone (period is 120, dead zone is 1.0).
        for i in 1..=100u64 {
            let nominal = i * 120;
            let jitter = if i % 2 == 0 { 0 } else { 0 };
            cdr.observe_edge(nominal + jitter, true);
        }
        assert!((cdr.period_mclks - 120.0).abs() < 0.5, "period drifted to {}", cdr.period_mclks);
    }

    #[test]
    fn cdr_ignores_h_attributable_edges() {
        let mut cdr = Cdr::new(120.0);
        cdr.last_edge_mclks = 0.0;
        cdr.next_edge_mclks = 120.0;
        let p_before = cdr.period_mclks;
        // Feed an "edge" wildly off the prediction but marked H-attributable. PLL should not move.
        cdr.observe_edge(500, false);
        assert_eq!(cdr.period_mclks, p_before);
    }

    #[test]
    fn cdr_tolerates_missing_edges_with_correct_slot_count() {
        // Simulate full-duplex where only every 4th boundary has an E-attributable edge. The PLL should still converge to the correct period because it normalises by slot count.
        let mut cdr = Cdr::new(120.0);
        cdr.last_edge_mclks = 0.0;
        cdr.next_edge_mclks = 120.0;
        // Edges at t = 480, 960, 1440, ... — every 4 slots.
        for k in 1..=100u64 {
            let t = k * 480;
            cdr.observe_edge(t, true);
        }
        assert!((cdr.period_mclks - 120.0).abs() < 1.0, "got {}", cdr.period_mclks);
    }

    #[test]
    fn frequency_25khz_at_6mhz_sample() {
        // 25 kHz wave at 6 Msps = 240 samples/period = 120 samples/half. Run a long enough capture (60 ms) so boundary-truncation error is < 1%.
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
