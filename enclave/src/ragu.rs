//! PIPE ragu pipeline — the silicon's keyed authentication primitive.
//!
//! PIPE silicon is a *primitive*, not a protocol. It computes:
//!
//! ```text
//! ragu = BLAKE3_keyed(key, chaos_amp(input) || input)
//! ```
//!
//! where `input` is a 64-byte block supplied by the caller. The semantics of the input — what it represents, how it's layered, what domain it belongs to — is the kernel's responsibility.
//!
//! "Ragu" rather than "MAC" because the construction is more than a textbook Message Authentication Code: it's a chaos-amplified, defense-in-depth, silicon-bound oracle output that happens to satisfy the MAC properties. Naming-by-metaphor (chaos amp = the slow-cooked sauce; ragu = the finished dish) keeps the construction's identity clear and parallels `ihi::spaghettify`.
//!
//! This matches BLAKE3's own design: `keyed_hash(key, msg)` doesn't take domain-tag arguments. The caller prefixes context. PIPE follows the same convention. Domain separation is *policy*, policy belongs in software (mutable), not silicon (immutable).
//!
//! # Defense in depth
//!
//! The ragu hashes `chaos_amp(input) || input` (chaos output **concatenated with the original input**), not just the chaos output. This is the spaghettify pattern: if chaos_amp has a structural weakness — e.g., the v2 design exhibits ~2% single-bit-flip absorption from data-dependent op selection — the original input is still mixed into the BLAKE3 call directly, and BLAKE3's collision-resistance applies to the full `(chaos_output, input)` tuple. Even if `chaos_amp(a) == chaos_amp(b)`, as long as `a != b`, the ragus differ.
//!
//! Two stacked security properties: chaos_amp's path-explosion + bit-destruction (structural, audit-by-counting), and BLAKE3's cryptographic uniformity (empirical, well-validated). Both must fall to forge a ragu.
//!
//! # Caller responsibility
//!
//! The caller hands the silicon 64 bytes of challenge. The silicon doesn't interpret them — silicon-identity is implicit in the key (eFuse-derived, possibly mixed with boot_nonce). If the kernel wants per-purpose domain separation it can prepend a tag itself; absent that, the input is whatever the kernel wants attested.

use crate::chaos_amp_v2::{chaos_amp_v2, state_to_bytes_v2};

/// PIPE primitive: chaos_amp v2 + keyed-BLAKE3 with input append.
///
/// `key` is the 256-bit secret in the silicon's key register (write-once). `input` is a 64-byte caller-prepared block (kernel layers semantics here). Returns 256 bits.
///
/// Computes `BLAKE3_keyed(key, chaos_amp_v2(input) || input)` — the chaos output (48 bytes) and the original input (64 bytes) are concatenated and fed to BLAKE3 keyed-hash, totalling 112 bytes of message.
pub fn ragu(key: &[u8; 32], input: &[u8; 64]) -> [u8; 32] {
    let chaos_state = chaos_amp_v2(input);
    let chaos_bytes = state_to_bytes_v2(&chaos_state);

    let mut hasher = blake3::Hasher::new_keyed(key);
    hasher.update(&chaos_bytes);
    hasher.update(input);
    *hasher.finalize().as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ragu_deterministic() {
        let key = [0xAA; 32];
        let input = [0xBB; 64];
        assert_eq!(ragu(&key, &input), ragu(&key, &input));
    }

    #[test]
    fn ragu_changes_with_key() {
        let input = [0u8; 64];
        let r1 = ragu(&[0; 32], &input);
        let r2 = ragu(&[1; 32], &input);
        assert_ne!(r1, r2);
    }

    #[test]
    fn ragu_changes_with_input() {
        let key = [0u8; 32];
        let mut a = [0u8; 64];
        let mut b = [0u8; 64];
        b[0] = 1;
        assert_ne!(ragu(&key, &a), ragu(&key, &b));
        a[0] = 1; // suppress unused_mut warning
    }

    /// Avalanche on the full ragu: 1-bit input flip → ~50% output bit flips. With the input-append defense-in-depth pattern, even if chaos_amp_v2 absorbs a bit flip, BLAKE3 still sees the input difference directly, so ragu avalanche reflects BLAKE3's well-validated 50% target. Loose tolerance: 45-55%.
    #[test]
    fn ragu_avalanche() {
        const TRIALS: usize = 200;
        let key = [0x42; 32];

        let mut total_diff: u64 = 0;
        let mut total_bits: u64 = 0;

        for trial in 0..TRIALS {
            let h = blake3::hash(&trial.to_le_bytes());
            let mut input = [0u8; 64];
            input[..32].copy_from_slice(h.as_bytes());
            input[32..].copy_from_slice(h.as_bytes());

            let mut input_flipped = input;
            let bit_pos = trial % 512;
            input_flipped[bit_pos / 8] ^= 1 << (bit_pos % 8);

            let r1 = ragu(&key, &input);
            let r2 = ragu(&key, &input_flipped);

            let diff: u32 = r1
                .iter()
                .zip(r2.iter())
                .map(|(a, b)| (a ^ b).count_ones())
                .sum();
            total_diff += diff as u64;
            total_bits += 256;
        }

        let avalanche_pct = 100.0 * total_diff as f64 / total_bits as f64;
        eprintln!(
            "ragu avalanche: {} / {} bits flipped ({:.2}%)",
            total_diff, total_bits, avalanche_pct
        );
        assert!(
            avalanche_pct > 45.0 && avalanche_pct < 55.0,
            "ragu avalanche outside 45-55%: {:.2}%",
            avalanche_pct
        );
    }

    /// Defense-in-depth check: even if chaos_amp_v2 absorbs a bit flip (≤3% of cases per the absorption test), the ragu must still differ because BLAKE3 sees the input directly.
    #[test]
    fn ragu_avalanche_survives_chaos_absorption() {
        const TRIALS: usize = 1000;
        let key = [0x42; 32];

        let mut ragu_collisions = 0;

        for trial in 0..TRIALS {
            let h = blake3::hash(&trial.to_le_bytes());
            let mut input = [0u8; 64];
            input[..32].copy_from_slice(h.as_bytes());
            input[32..].copy_from_slice(h.as_bytes());

            let mut input_flipped = input;
            let bit_pos = trial % 512;
            input_flipped[bit_pos / 8] ^= 1 << (bit_pos % 8);

            if ragu(&key, &input) == ragu(&key, &input_flipped) {
                ragu_collisions += 1;
            }
        }

        eprintln!("ragu collisions on 1-bit flips: {} / {}", ragu_collisions, TRIALS);
        assert_eq!(
            ragu_collisions, 0,
            "ragu must produce different output for any 1-bit input flip — defense-in-depth pattern broken"
        );
    }
}
