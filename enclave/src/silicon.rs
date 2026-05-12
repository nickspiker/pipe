//! Silicon runtime model — two key registers populated at boot, two ragu modes exposed.
//!
//! Models the post-boot state of the PIPE silicon: an eFuse (silicon's birth identity, OTP, set at manufacture) and a boot_nonce (TRNG burst captured during boot_fsm). From these, the boot FSM derives two distinct 256-bit keys that live in two write-once key registers and feed two parallel ragu pipelines:
//!
//! ```text anchor_key  = BLAKE3(eFuse)              — stable across power cycles session_key = BLAKE3(eFuse, boot_nonce)  — fresh per power cycle ```
//!
//! Both registers populate during boot. The kernel then invokes either:
//!
//! - `silicon.anchor_ragu(challenge)`  — for long-lived identity / enrollment fingerprints
//! - `silicon.session_ragu(challenge)` — for per-session attestation / replay-resistant proofs
//!
//! Each call computes `BLAKE3_keyed(key, chaos_amp_v2(challenge) || challenge)` with the appropriate key. The silicon mux selects which key_register feeds blake3 based on a 1-bit mode signal asserted by the kernel per call.
//!
//! # Why both available simultaneously
//!
//! Some attestations need stability (does this silicon match the one we enrolled?), others need freshness (is this attestation from the *current* power cycle, not a recorded replay?). Holding both keys post-boot means the kernel doesn't have to reboot to switch modes. The cost is minimal: one extra 256-bit key register, a 256-bit mux, and a 1-bit mode wire.
//!
//! # Key derivation matches boot_fsm.v (when written)
//!
//! `Silicon::boot` here is the bit-exact reference for what `boot_fsm.v` will compute in silicon: hash eFuse alone for the anchor key, hash eFuse + boot_nonce for the session key. The Verilog FSM will follow the same hash structure.

use crate::ragu::ragu;

/// Post-boot silicon state — the two 256-bit keys that live in the silicon's pair of write-once registers.
#[derive(Debug, Clone)]
pub struct Silicon {
    /// Anchor key — `BLAKE3(eFuse)`. Stable across power cycles. Same eFuse always derives the same anchor key.
    pub anchor_key: [u8; 32],
    /// Session key — `BLAKE3(eFuse || boot_nonce)`. Fresh per power cycle. Different boot_nonce → different session key, even with the same eFuse.
    pub session_key: [u8; 32],
}

impl Silicon {
    /// Reproduce the boot_fsm key derivation. Called once per power-on by the silicon; here it's a deterministic function of (eFuse, boot_nonce).
    ///
    /// `efuse` is the silicon's 64-byte birth identity (OTP, set at manufacture). `boot_nonce` is a 32-byte value the silicon's TRNG accumulates during boot. In static-only deployments the boot_nonce can be all-zeros, in which case `session_key = BLAKE3(eFuse || 0)` and is also stable across boots — but that's a deliberate kernel choice, not the default.
    pub fn boot(efuse: &[u8; 64], boot_nonce: &[u8; 32]) -> Self {
        let anchor_key = *blake3::hash(efuse).as_bytes();

        let mut hasher = blake3::Hasher::new();
        hasher.update(efuse);
        hasher.update(boot_nonce);
        let session_key = *hasher.finalize().as_bytes();

        Self {
            anchor_key,
            session_key,
        }
    }

    /// Anchor-mode ragu — uses the static (eFuse-only) key. Stable across boots: same challenge always produces the same ragu on this silicon.
    pub fn anchor_ragu(&self, challenge: &[u8; 64]) -> [u8; 32] {
        ragu(&self.anchor_key, challenge)
    }

    /// Session-mode ragu — uses the boot_nonce-mixed key. Fresh per power cycle: same challenge produces a different ragu after every boot, replay-proof.
    pub fn session_ragu(&self, challenge: &[u8; 64]) -> [u8; 32] {
        ragu(&self.session_key, challenge)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_efuse(seed: u8) -> [u8; 64] {
        let mut e = [0u8; 64];
        for i in 0..64 {
            e[i] = seed.wrapping_add(i as u8);
        }
        e
    }

    fn make_nonce(seed: u8) -> [u8; 32] {
        let mut n = [0u8; 32];
        for i in 0..32 {
            n[i] = seed.wrapping_add(i as u8);
        }
        n
    }

    /// Same (eFuse, nonce) → same Silicon state. Boot derivation is deterministic.
    #[test]
    fn boot_deterministic() {
        let efuse = make_efuse(0x42);
        let nonce = make_nonce(0xAB);
        let s1 = Silicon::boot(&efuse, &nonce);
        let s2 = Silicon::boot(&efuse, &nonce);
        assert_eq!(s1.anchor_key, s2.anchor_key);
        assert_eq!(s1.session_key, s2.session_key);
    }

    /// Anchor key depends only on eFuse, NOT on boot_nonce.
    #[test]
    fn anchor_key_is_nonce_independent() {
        let efuse = make_efuse(0x33);
        let s1 = Silicon::boot(&efuse, &make_nonce(0x00));
        let s2 = Silicon::boot(&efuse, &make_nonce(0xFF));
        assert_eq!(
            s1.anchor_key, s2.anchor_key,
            "anchor key must not depend on boot_nonce"
        );
    }

    /// Session key changes when boot_nonce changes (and eFuse is held constant).
    #[test]
    fn session_key_changes_with_nonce() {
        let efuse = make_efuse(0x33);
        let s1 = Silicon::boot(&efuse, &make_nonce(0x00));
        let s2 = Silicon::boot(&efuse, &make_nonce(0xFF));
        assert_ne!(
            s1.session_key, s2.session_key,
            "session key must depend on boot_nonce"
        );
    }

    /// Different eFuses produce different anchor keys and different session keys (fingerprintability).
    #[test]
    fn distinct_silicons_distinct_keys() {
        let nonce = make_nonce(0x01);
        let s1 = Silicon::boot(&make_efuse(0x10), &nonce);
        let s2 = Silicon::boot(&make_efuse(0x20), &nonce);
        assert_ne!(s1.anchor_key, s2.anchor_key);
        assert_ne!(s1.session_key, s2.session_key);
    }

    /// Anchor and session ragus differ for the same challenge — the keys are different so the outputs must be different.
    #[test]
    fn anchor_and_session_ragus_differ() {
        let efuse = make_efuse(0x55);
        let nonce = make_nonce(0xAA);
        let silicon = Silicon::boot(&efuse, &nonce);
        let challenge = [0xC3u8; 64];
        assert_ne!(silicon.anchor_ragu(&challenge), silicon.session_ragu(&challenge));
    }

    /// Anchor ragu is stable across simulated reboots (same eFuse, any nonce).
    #[test]
    fn anchor_ragu_stable_across_reboots() {
        let efuse = make_efuse(0x77);
        let challenge = [0xA5u8; 64];
        let s1 = Silicon::boot(&efuse, &make_nonce(0x11));
        let s2 = Silicon::boot(&efuse, &make_nonce(0x22));
        assert_eq!(s1.anchor_ragu(&challenge), s2.anchor_ragu(&challenge));
    }

    /// Session ragu changes across simulated reboots (same eFuse, different nonces).
    #[test]
    fn session_ragu_fresh_per_reboot() {
        let efuse = make_efuse(0x77);
        let challenge = [0xA5u8; 64];
        let s1 = Silicon::boot(&efuse, &make_nonce(0x11));
        let s2 = Silicon::boot(&efuse, &make_nonce(0x22));
        assert_ne!(s1.session_ragu(&challenge), s2.session_ragu(&challenge));
    }
}
