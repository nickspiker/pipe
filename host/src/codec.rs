//! Mirror-XOR line-code codec, host side.
//!
//! Bit-exact match to `rtl/codec.v`. Both sides follow the encode/decode rules in `PROTOCOL.md`:
//!
//! ```text
//! wire    = own_idle   ^ tx_data ^ other_last
//! decoded = wire       ^ other_idle ^ own_last
//! ```
//!
//! `own_idle` is `1` for the enclave instance and `0` for the host instance. Each side keeps two single-bit registers (`own_last`, `other_last`) initialised to 0; they update at slot boundaries based on whose slot it was.

/// One side of a mirror-XOR codec. Stateless on its inputs except for the two `last` bits, which are mutated each tick.
#[derive(Debug, Clone, Copy)]
pub struct Codec {
    own_idle: u8,
    other_idle: u8,
    own_last: u8,
    other_last: u8,
}

impl Codec {
    /// Construct an enclave-side codec (`own_idle = 1`).
    pub fn enclave() -> Self {
        Self {
            own_idle: 1,
            other_idle: 0,
            own_last: 0,
            other_last: 0,
        }
    }

    /// Construct a host-side codec (`own_idle = 0`).
    pub fn host() -> Self {
        Self {
            own_idle: 0,
            other_idle: 1,
            own_last: 0,
            other_last: 0,
        }
    }

    /// Encode the value to drive on the wire during this side's slot.
    ///
    /// Updates `own_last` to the transmitted bit so the next decode call can subtract it.
    pub fn tx(&mut self, data: u8) -> u8 {
        let data = data & 1;
        let wire = self.own_idle ^ data ^ self.other_last;
        self.own_last = data;
        wire & 1
    }

    /// Decode a wire sample taken during the OTHER side's slot.
    ///
    /// Returns the other side's data bit and updates `other_last` so the next `tx` call can XOR it into our own emission.
    pub fn rx(&mut self, wire: u8) -> u8 {
        let wire = wire & 1;
        let data = wire ^ self.other_idle ^ self.own_last;
        self.other_last = data;
        data
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Run a bidirectional exchange. Each round = one enclave slot + one host slot. Returns the wire trace and decoded streams from both sides.
    fn paired_exchange(
        enc_tx: &[u8],
        host_tx: &[u8],
    ) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        assert_eq!(enc_tx.len(), host_tx.len());
        let mut enc = Codec::enclave();
        let mut host = Codec::host();

        let mut wire = Vec::with_capacity(enc_tx.len() * 2);
        let mut enc_decoded_host = Vec::with_capacity(enc_tx.len());
        let mut host_decoded_enc = Vec::with_capacity(enc_tx.len());

        for i in 0..enc_tx.len() {
            // Even slot: enclave drives, host listens
            let w_e = enc.tx(enc_tx[i]);
            let dec_e = host.rx(w_e);
            wire.push(w_e);
            host_decoded_enc.push(dec_e);

            // Odd slot: host drives, enclave listens
            let w_h = host.tx(host_tx[i]);
            let dec_h = enc.rx(w_h);
            wire.push(w_h);
            enc_decoded_host.push(dec_h);
        }

        (wire, enc_decoded_host, host_decoded_enc)
    }

    #[test]
    fn idle_wire_is_alternating_1010() {
        let zeros = vec![0u8; 16];
        let (wire, _, _) = paired_exchange(&zeros, &zeros);
        let expected: Vec<u8> = (0..32).map(|i| if i % 2 == 0 { 1 } else { 0 }).collect();
        assert_eq!(wire, expected, "idle wire should be 1010… by slot ownership");
    }

    #[test]
    fn idle_decodes_as_zeros_both_sides() {
        let zeros = vec![0u8; 16];
        let (_, enc_dec, host_dec) = paired_exchange(&zeros, &zeros);
        assert_eq!(enc_dec, zeros, "enc should decode host's idle as all zeros");
        assert_eq!(host_dec, zeros, "host should decode enc's idle as all zeros");
    }

    #[test]
    fn host_single_one_round_trips() {
        let enc_tx = vec![0u8; 16];
        let mut host_tx = vec![0u8; 16];
        host_tx[5] = 1;

        let (_, enc_dec, host_dec) = paired_exchange(&enc_tx, &host_tx);
        assert_eq!(enc_dec, host_tx, "enc must decode host's single 1");
        assert_eq!(host_dec, enc_tx, "host must decode enc's all-zero stream");
    }

    #[test]
    fn enc_single_one_round_trips() {
        let mut enc_tx = vec![0u8; 16];
        enc_tx[7] = 1;
        let host_tx = vec![0u8; 16];

        let (_, enc_dec, host_dec) = paired_exchange(&enc_tx, &host_tx);
        assert_eq!(host_dec, enc_tx, "host must decode enc's single 1");
        assert_eq!(enc_dec, host_tx, "enc must decode host's all-zero stream");
    }

    #[test]
    fn both_inject_one_simultaneously_round_trips() {
        let mut enc_tx = vec![0u8; 16];
        let mut host_tx = vec![0u8; 16];
        enc_tx[5] = 1;
        host_tx[5] = 1;

        let (_, enc_dec, host_dec) = paired_exchange(&enc_tx, &host_tx);
        assert_eq!(enc_dec, host_tx);
        assert_eq!(host_dec, enc_tx);
    }

    #[test]
    fn random_streams_round_trip() {
        // BLAKE3-derived random for reproducibility.
        let h = blake3::hash(b"PIPE codec round-trip test");
        let bytes = h.as_bytes();
        let mut enc_tx = Vec::with_capacity(256);
        let mut host_tx = Vec::with_capacity(256);
        for &b in bytes.iter() {
            for j in 0..8 {
                enc_tx.push((b >> j) & 1);
            }
        }
        // Use a second hash for the host stream so the two streams are independent.
        let h2 = blake3::hash(b"PIPE codec round-trip test - host");
        let bytes2 = h2.as_bytes();
        for &b in bytes2.iter() {
            for j in 0..8 {
                host_tx.push((b >> j) & 1);
            }
        }

        let (wire, enc_dec, host_dec) = paired_exchange(&enc_tx, &host_tx);

        assert_eq!(enc_dec, host_tx, "enc must recover host's random stream");
        assert_eq!(host_dec, enc_tx, "host must recover enc's random stream");

        // Sanity: wire length == 2 × stream length, DC roughly balanced.
        assert_eq!(wire.len(), 2 * enc_tx.len());
        let ones: usize = wire.iter().map(|&b| b as usize).sum();
        let pct = 100.0 * ones as f64 / wire.len() as f64;
        assert!(
            (pct - 50.0).abs() < 5.0,
            "random data wire DC should be near 50%; got {:.2}%",
            pct
        );
    }

    /// Reproduces the wire pattern in `PROTOCOL.md` "Host injects one `1` at slot 11" example.
    /// The 8-slot window starting at slot 8 should read: E h E H e h E h.
    #[test]
    fn protocol_md_example_host_injects_one() {
        let mut enc = Codec::enclave();
        let mut host = Codec::host();
        let mut wire = Vec::new();
        for slot in 0..16 {
            if slot % 2 == 0 {
                let w = enc.tx(0);
                let _ = host.rx(w);
                wire.push(w);
            } else {
                let host_data = if slot == 11 { 1 } else { 0 };
                let w = host.tx(host_data);
                let _ = enc.rx(w);
                wire.push(w);
            }
        }
        // Expected wire (from PROTOCOL.md example):
        // slot:  0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
        // wire:  1 0 1 0 1 0 1 0 1 0  1  1  0  0  1  0
        let expected = vec![1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0];
        assert_eq!(wire, expected);
    }

    /// Reproduces the "both inject 1 in same window" example.
    #[test]
    fn protocol_md_example_both_inject() {
        let mut enc = Codec::enclave();
        let mut host = Codec::host();
        let mut wire = Vec::new();
        for slot in 0..16 {
            if slot % 2 == 0 {
                let enc_data = if slot == 12 { 1 } else { 0 };
                let w = enc.tx(enc_data);
                let _ = host.rx(w);
                wire.push(w);
            } else {
                let host_data = if slot == 11 { 1 } else { 0 };
                let w = host.tx(host_data);
                let _ = enc.rx(w);
                wire.push(w);
            }
        }
        // Expected per PROTOCOL.md: slots 10-14 read E H E H E = 1 1 1 1 1.
        assert_eq!(wire[10..15], [1, 1, 1, 1, 1]);
    }
}
