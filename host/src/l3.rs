//! PIPE Layer 3 host-side client.
//!
//! Implements PROTOCOL.md L3 from the host side: fresh-session, Message B
//! request/response encoding, pad ratcheting, mode-detection (SESSION vs
//! PERMANENT), and the Q_HEALTH state-vector commitment (Claim 9c).
//!
//! This module is wire-format only. It produces and consumes flat `Vec<bool>`
//! bit streams in the order they appear on the wire (first transmitted bit at
//! index 0). The transport — whether USB→RP2040→FPGA via the bridge, FT232H
//! bit-bang, or simulated — is the caller's problem. The module is fully
//! testable offline because it owns no I/O.
//!
//! Wire shapes (matches `rtl/l3_session_fsm.v` and PROTOCOL.md §"Frame bit"):
//! - Fresh-session: 1 (frame) + 256 zero data bits = 257 wire bits.
//! - Message B:     1 (frame) + 256 X1 + 256 X2    = 513 wire bits per direction.
//!
//! Inside a 256-bit message word the convention is **MSB-first transmission**:
//! the first wire bit is bit 255 (the most significant bit), the last is bit 0.
//! This matches the FSM's `rx_buf1 <= {rx_buf1[254:0], rx_data}` shift pattern,
//! which lands the first received bit at index 255 after 256 shifts.
//!
//! Cryptographic byte order: a "256-bit message" is represented as `[u8; 32]`
//! in big-endian byte order — `bytes[0]` is the most significant byte, and
//! `bytes[0] >> 7` is the MSB of the whole 256-bit value. This is also the
//! natural representation for canonical identifiers like
//! `BLAKE3("Kei te ora koe?")` whose canonical hex string is read left-to-right
//! as bytes 0..31.

use blake3::Hasher;

/// 256-bit value in big-endian byte order (`bytes[0]` is MSB).
pub type Word256 = [u8; 32];

/// Q_HEALTH domain identifier — `BLAKE3("Kei te ora koe?")`.
///
/// Issuing a Message B with this `message_req` triggers the chip's q/health
/// path: the BLAKE3 input becomes 64 bytes (= `message_req || state_block`),
/// numbytes=64, and the response commits to both the message and the chip's
/// current internal state under the active key (Claim 9c).
pub const Q_HEALTH_IDENT: Word256 = [
    0xc0, 0xa6, 0xca, 0xbf, 0x9f, 0x69, 0xf2, 0xaf, 0xf7, 0x8b, 0x51, 0x15,
    0x1e, 0x93, 0x00, 0xcd, 0x5b, 0xd3, 0x2d, 0xfb, 0xbe, 0xcf, 0x55, 0x06,
    0x00, 0x62, 0x54, 0x78, 0xff, 0xee, 0x8e, 0x80,
];

/// Total wire bits for a fresh-session request OR response (per direction).
pub const FRESH_SESSION_WIRE_BITS: usize = 1 + 256;

/// Total wire bits for one Message-B request OR response (per direction).
pub const MESSAGE_B_WIRE_BITS: usize = 1 + 256 + 256;

/// Which key the enclave should use for `BLAKE3.keyed(active_key, ...)`.
///
/// `Session` = wairua (per-session secret, gone after power cycle).
/// `Permanent` = ira (eFuse-backed lifetime identity).
///
/// On the wire, mode is encoded in the X2 invariant — SESSION uses `BLAKE3(msg)`
/// directly, PERMANENT uses `~BLAKE3(msg)` (bitwise complement). The receiver
/// tests both invariants and the matching one tells it which key to use.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Mode {
    Session,
    Permanent,
}

/// L3 client state. Holds the derived pads and the public copy of the wairua
/// + permanent IRA the host knows. Lives across many `request`/`response`
/// pairs within a session; reset by calling `fresh_session_encode` and
/// `fresh_session_decode` again.
#[derive(Clone, Debug)]
pub struct L3Client {
    /// Permanent identity (= chip's `ira`). Host learned this from a previous
    /// IRA dump (mode 1 on the chip OLED, or the legacy `meal_dump_ira` path).
    /// Required only for PERMANENT-mode exchanges — `Session`-only sessions
    /// can leave this zeroed.
    pub ira: Word256,
    /// Per-session secret recovered from the enclave's fresh-session response.
    /// Zero before `fresh_session_decode` has been called.
    pub wairua: Word256,
    /// Current pad for the message half of the next exchange.
    pub h_req: Word256,
    /// Current pad for the hash half of the next exchange.
    pub h_resp: Word256,
    /// True once a fresh-session has been completed and pads are derived.
    pub session_valid: bool,
}

impl L3Client {
    /// New client. Set `ira` if you intend to do PERMANENT-mode exchanges,
    /// otherwise it can be all-zero.
    pub fn new(ira: Word256) -> Self {
        Self {
            ira,
            wairua: [0u8; 32],
            h_req: [0u8; 32],
            h_resp: [0u8; 32],
            session_valid: false,
        }
    }

    // ----------------------------------------------------------------- //
    // Fresh-session (Message A)
    // ----------------------------------------------------------------- //

    /// Wire bits the host transmits to start a fresh session.
    ///
    /// Layout: frame-1, then 256 zero data bits. Total 257 wire bits.
    /// First element is the first transmitted bit.
    pub fn fresh_session_encode(&self) -> Vec<bool> {
        let mut bits = Vec::with_capacity(FRESH_SESSION_WIRE_BITS);
        bits.push(true);
        bits.extend(std::iter::repeat(false).take(256));
        bits
    }

    /// Decode the enclave's fresh-session response and derive H_req / H_resp.
    /// `wire_bits` must be exactly 257 bits, the first being the enclave's
    /// frame-1. The next 256 are `wairua` MSB-first. Returns `Err` if the
    /// frame bit was missing.
    pub fn fresh_session_decode(&mut self, wire_bits: &[bool]) -> Result<(), &'static str> {
        if wire_bits.len() != FRESH_SESSION_WIRE_BITS {
            return Err("wrong number of wire bits for fresh-session response");
        }
        if !wire_bits[0] {
            return Err("enclave fresh-session response missing frame bit");
        }
        let wairua = bits_to_word256_msb_first(&wire_bits[1..])?;
        let inv_wairua = bitwise_not_word256(&wairua);
        self.wairua = wairua;
        self.h_req = blake3_plain32(&wairua);
        self.h_resp = blake3_plain32(&inv_wairua);
        self.session_valid = true;
        Ok(())
    }

    // ----------------------------------------------------------------- //
    // Message B
    // ----------------------------------------------------------------- //

    /// Build the 513 wire bits the host transmits for a Message-B exchange.
    ///
    /// `message_req` is the host's chosen 256-bit message (any value;
    /// canonical identifiers like `Q_HEALTH_IDENT` are fine, no bit-0
    /// constraint — the leading frame bit is pure framing).
    /// `mode` chooses the X2 invariant; the enclave detects this and routes
    /// to `active_key = wairua` (SESSION) or `active_key = ira` (PERMANENT).
    pub fn message_b_encode(&self, message_req: &Word256, mode: Mode) -> Vec<bool> {
        assert!(
            self.session_valid,
            "L3Client::message_b_encode called before fresh_session_decode"
        );

        // X1 = message_req XOR H_req
        let mut x1 = [0u8; 32];
        for i in 0..32 {
            x1[i] = message_req[i] ^ self.h_req[i];
        }

        // X2 = BLAKE3(message_req) XOR H_resp (SESSION)
        //    = ~BLAKE3(message_req) XOR H_resp (PERMANENT)
        let h_msg = blake3_plain32(message_req);
        let mut x2 = [0u8; 32];
        match mode {
            Mode::Session => {
                for i in 0..32 {
                    x2[i] = h_msg[i] ^ self.h_resp[i];
                }
            }
            Mode::Permanent => {
                for i in 0..32 {
                    x2[i] = (!h_msg[i]) ^ self.h_resp[i];
                }
            }
        }

        let mut bits = Vec::with_capacity(MESSAGE_B_WIRE_BITS);
        bits.push(true); // frame bit
        push_word256_msb_first(&mut bits, &x1);
        push_word256_msb_first(&mut bits, &x2);
        bits
    }

    /// Decode the enclave's Message-B response and verify it.
    ///
    /// Inputs: the 513 captured wire bits, the original `message_req` that
    /// was sent (the host needs it to ratchet `h_req`), and the `mode` the
    /// host issued (the response MUST echo the same mode).
    ///
    /// On success: returns `(message_resp, mode_observed)` and ratchets the
    /// pads. On failure: returns `Err` with a reason — most commonly that
    /// the response's X2' invariant didn't match, indicating either the wire
    /// got corrupted, the chip dropped, or the session is desynced.
    pub fn message_b_decode(
        &mut self,
        wire_bits: &[bool],
        message_req: &Word256,
        mode: Mode,
    ) -> Result<Word256, MessageBError> {
        if wire_bits.len() != MESSAGE_B_WIRE_BITS {
            return Err(MessageBError::WrongBitCount {
                got: wire_bits.len(),
                expected: MESSAGE_B_WIRE_BITS,
            });
        }
        if !wire_bits[0] {
            return Err(MessageBError::MissingFrameBit);
        }

        // Split the 512-bit payload into X1' and X2'.
        let x1p = bits_to_word256_msb_first(&wire_bits[1..257])
            .map_err(|_| MessageBError::InternalUnpackError)?;
        let x2p = bits_to_word256_msb_first(&wire_bits[257..513])
            .map_err(|_| MessageBError::InternalUnpackError)?;

        // Recover message_resp = X1' XOR H_req (the H_req in effect when the
        // chip computed the response — i.e., the pre-ratchet value, which is
        // exactly what's still in `self.h_req` at this point).
        let mut message_resp = [0u8; 32];
        for i in 0..32 {
            message_resp[i] = x1p[i] ^ self.h_req[i];
        }

        // Verify X2' echoes the same mode the host issued.
        let h_resp_msg = blake3_plain32(&message_resp);
        let expected_x2p = match mode {
            Mode::Session => {
                let mut t = [0u8; 32];
                for i in 0..32 {
                    t[i] = h_resp_msg[i] ^ self.h_resp[i];
                }
                t
            }
            Mode::Permanent => {
                let mut t = [0u8; 32];
                for i in 0..32 {
                    t[i] = (!h_resp_msg[i]) ^ self.h_resp[i];
                }
                t
            }
        };
        if expected_x2p != x2p {
            return Err(MessageBError::X2Mismatch);
        }

        // Verified — advance the chain.
        self.h_req = blake3_plain32(message_req);
        self.h_resp = blake3_plain32(&message_resp);
        Ok(message_resp)
    }

    // ----------------------------------------------------------------- //
    // Q_HEALTH state-vector commitment (Claim 9c)
    // ----------------------------------------------------------------- //

    /// Compute the expected Q_HEALTH response for a given state hypothesis.
    ///
    /// The chip's response to `PIPE(Q_HEALTH, mode)` is
    ///   `BLAKE3.keyed(active_key, message_req || state_block, numbytes=64)`
    /// where `state_block` is packed per PROTOCOL.md §"Q_HEALTH state vector"
    /// and `active_key` is the IRA (PERMANENT) or WAIRUA (SESSION).
    ///
    /// The host that wants to authenticate a state hypothesis calls this with
    /// the state it expects to be true, then compares against the wire response.
    /// A match = "chip's permanent (or session) key just committed to that
    /// state at the time it composed the response."
    pub fn q_health_expected(&self, state: &StateBlock, mode: Mode) -> Word256 {
        let active_key = match mode {
            Mode::Session => &self.wairua,
            Mode::Permanent => &self.ira,
        };
        // Chip's BLAKE3 byte order:
        //   key:    chip's b3_chain[7:0] = canonical key byte 0
        //           → host byte 31 (because host stores in reversed byte order)
        //   mblock: chip's b3_mblock[7:0] = canonical input byte 0
        //           = chip's message_req[7:0] (low half of mblock, low 8 bits)
        //           → host's message_req byte 31
        //   layout: bytes [0..31] = canonical msg bytes in order, bytes
        //           [32..63] = canonical state bytes in order.
        // To match, reverse each Word256 before stuffing into the BLAKE3 input.
        let canonical_key = reverse_bytes(active_key);
        let canonical_msg = reverse_bytes(&Q_HEALTH_IDENT);
        let canonical_state = reverse_bytes(&state.pack());
        let mut mblock = [0u8; 64];
        mblock[0..32].copy_from_slice(&canonical_msg);
        mblock[32..64].copy_from_slice(&canonical_state);

        let mut hasher = Hasher::new_keyed(&canonical_key);
        hasher.update(&mblock);
        let mut canonical_out = [0u8; 32];
        canonical_out.copy_from_slice(hasher.finalize().as_bytes());
        reverse_bytes(&canonical_out)
    }
}

/// Failure modes when decoding the enclave's Message-B response.
#[derive(Debug, PartialEq, Eq)]
pub enum MessageBError {
    /// Captured a non-513-bit response.
    WrongBitCount { got: usize, expected: usize },
    /// Frame bit (first bit) was 0.
    MissingFrameBit,
    /// X2' didn't match either SESSION or PERMANENT invariant for the issued
    /// mode. Indicates wire corruption or the chip dropped the request.
    X2Mismatch,
    /// Internal unpack error (should not happen if the input is well-formed).
    InternalUnpackError,
}

// =================================================================== //
// State block (Claim 9c packing)
// =================================================================== //

/// 256-bit state vector the chip commits to in a Q_HEALTH response.
///
/// Field semantics and bit positions match `rtl/l3_session_fsm.v` and
/// PROTOCOL.md §"Q_HEALTH state vector". `pack()` produces the 32 bytes the
/// chip uses as the high half of its BLAKE3 input mblock.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StateBlock {
    /// 0=VIRGIN, 1=FUCKED, 2=DEGRADED-2, 3=DEGRADED-1, 4=HEALTHY (3 bits)
    pub chip_state: u8,
    /// Per-ring TRNG health pass bits (16 bits, LSB = ring 0)
    pub ring_health_mask: u16,
    /// Healthy-ring count (5 bits, 0..16)
    pub ring_health_cnt: u8,
    /// OTP slot burned bits (8 bits, LSB = slot 0)
    pub slot_burned_mask: u8,
    /// Ceremony FSM state debug (3 bits)
    pub fsm_state: u8,
    /// Verified Message-B exchanges in this session
    pub session_counter: u64,
    /// Enclave_clk cycles since power-on (free-running)
    pub boot_epoch: u64,
    /// Lifetime count of dropped exchanges
    pub drop_counter: u64,
}

impl StateBlock {
    /// Pack the state block into the 32-byte representation the chip emits.
    ///
    /// Bit layout (matches `wire [255:0] state_block = {...}` in
    /// `l3_session_fsm.v`):
    /// ```text
    /// bits   2:0  chip_state          (3 bits)
    /// bits  18:3  ring_health_mask    (16 bits)
    /// bits  23:19 ring_health_cnt     (5 bits)
    /// bits  31:24 slot_burned_mask    (8 bits)
    /// bits  34:32 fsm_state           (3 bits)
    /// bits  98:35 session_counter     (64 bits)
    /// bits 162:99 boot_epoch          (64 bits)
    /// bits 226:163 drop_counter       (64 bits)
    /// bits 255:227 reserved zero      (29 bits)
    /// ```
    /// Returned as `[u8; 32]` in big-endian byte order — `bytes[0]` holds bits
    /// 255..248, `bytes[31]` holds bits 7..0. This matches the byte ordering
    /// used for Q_HEALTH_IDENT and the rest of this module.
    pub fn pack(&self) -> Word256 {
        // Build as u256 in a [u64; 4] little-endian view (low quarter = bits
        // 0..63, high quarter = bits 192..255). Then byte-reverse to big-end.
        let mut limbs = [0u64; 4];

        // Helper closure: OR `width` bits of `value` (low-aligned) into the
        // bit-stream starting at absolute bit position `pos`.
        let mut place = |value: u64, pos: usize, width: usize| {
            let mask = if width == 64 { !0u64 } else { (1u64 << width) - 1 };
            let value = value & mask;
            let limb_lo = pos / 64;
            let bit_lo = pos % 64;
            limbs[limb_lo] |= value << bit_lo;
            if bit_lo + width > 64 && limb_lo + 1 < 4 {
                let shift = 64 - bit_lo;
                limbs[limb_lo + 1] |= value >> shift;
            }
        };

        place(self.chip_state as u64, 0, 3);
        place(self.ring_health_mask as u64, 3, 16);
        place(self.ring_health_cnt as u64, 19, 5);
        place(self.slot_burned_mask as u64, 24, 8);
        place(self.fsm_state as u64, 32, 3);
        place(self.session_counter, 35, 64);
        place(self.boot_epoch, 99, 64);
        place(self.drop_counter, 163, 64);
        // bits 227..255 reserved zero — left untouched

        // Serialize to big-endian byte array: byte 0 = bits 255..248 = high
        // bits of limbs[3].
        let mut out = [0u8; 32];
        for (i, limb) in limbs.iter().enumerate() {
            // limb i covers bits [64*i .. 64*i+64]. In big-endian byte order,
            // bytes [24-8*i .. 32-8*i] are filled by this limb's bytes
            // (limb-low → byte 31-8*i, limb-high → byte 24-8*i).
            let base = 32 - 8 * (i + 1);
            let be = limb.to_be_bytes();
            out[base..base + 8].copy_from_slice(&be);
        }
        out
    }
}

// =================================================================== //
// Bit-level helpers
// =================================================================== //

/// Convert a 256-bit value to MSB-first wire bits, appending to `out`.
fn push_word256_msb_first(out: &mut Vec<bool>, word: &Word256) {
    for byte in word {
        for shift in (0..8).rev() {
            out.push((byte >> shift) & 1 != 0);
        }
    }
}

/// Convert 256 MSB-first wire bits into a `Word256` (big-endian byte array).
fn bits_to_word256_msb_first(bits: &[bool]) -> Result<Word256, &'static str> {
    if bits.len() != 256 {
        return Err("expected exactly 256 bits");
    }
    let mut out = [0u8; 32];
    for (byte_idx, byte) in out.iter_mut().enumerate() {
        let mut acc = 0u8;
        for j in 0..8 {
            if bits[byte_idx * 8 + j] {
                acc |= 1 << (7 - j);
            }
        }
        *byte = acc;
    }
    Ok(out)
}

fn bitwise_not_word256(w: &Word256) -> Word256 {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = !w[i];
    }
    out
}

/// Byte-reversal between host's Word256 (MSB-first byte order, matching
/// MSB-first wire transmission) and BLAKE3's canonical byte order (where
/// byte 0 is at bit position [7:0]). The chip's `blake3.v` is little-endian
/// per BLAKE3 spec: `mblock[7:0]` is canonical input byte 0, `o_hash[7:0]`
/// is canonical output byte 0. The wire transmits the chip's value bit 255
/// first, which lands at host Word256 byte 0 bit 7 — i.e., host byte 0 holds
/// chip bits [255:248] = the chip's "highest" byte = canonical byte 31.
///
/// So a host Word256 holds its data in reversed byte order from canonical
/// BLAKE3 ordering. To compute hashes that match what the chip computes,
/// reverse input bytes before feeding to Rust BLAKE3, and reverse the output
/// before storing as a host Word256.
fn reverse_bytes(w: &Word256) -> Word256 {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = w[31 - i];
    }
    out
}

fn blake3_plain32(input: &Word256) -> Word256 {
    let canonical_input = reverse_bytes(input);
    let mut hasher = Hasher::new();
    hasher.update(&canonical_input);
    let mut canonical_out = [0u8; 32];
    canonical_out.copy_from_slice(hasher.finalize().as_bytes());
    reverse_bytes(&canonical_out)
}

// =================================================================== //
// Wire-bit ↔ USB byte packing
// =================================================================== //

/// Pack wire bits into a USB byte buffer, MSB-first within each byte.
///
/// `bits[0]` lands at byte 0's high bit (bit 7). Returned vector length is
/// `ceil(bits.len() / 8)`. Trailing bits are zero-padded.
///
/// This is the format the firmware's `pipe_l3_round` command expects in its
/// `tx_bits` blob — bridge's PIO consumes from FIFO MSB-first so this maps
/// directly onto wire transmission order.
pub fn pack_bits_msb_first(bits: &[bool]) -> Vec<u8> {
    let n = (bits.len() + 7) / 8;
    let mut out = vec![0u8; n];
    for (i, &b) in bits.iter().enumerate() {
        if b {
            out[i / 8] |= 1 << (7 - (i % 8));
        }
    }
    out
}

/// Inverse of `pack_bits_msb_first`. Reads `bit_count` bits out of `bytes`
/// (MSB-first within each byte). Errors if `bytes` is too short.
pub fn unpack_bits_msb_first(bytes: &[u8], bit_count: usize) -> Result<Vec<bool>, &'static str> {
    if bytes.len() * 8 < bit_count {
        return Err("byte buffer shorter than requested bit count");
    }
    let mut out = Vec::with_capacity(bit_count);
    for i in 0..bit_count {
        let b = (bytes[i / 8] >> (7 - (i % 8))) & 1 != 0;
        out.push(b);
    }
    Ok(out)
}

/// Pack wire bits into a USB byte buffer, LSB-first within each byte.
///
/// `bits[0]` lands at byte 0's bit 0. This matches the firmware's
/// `pipe_l3_round` tx/rx byte stream convention (PIO autopulls/pushes
/// LSB-first by default).
pub fn pack_bits_lsb_first(bits: &[bool]) -> Vec<u8> {
    let n = bits.len().div_ceil(8);
    let mut out = vec![0u8; n];
    for (i, &b) in bits.iter().enumerate() {
        if b {
            out[i / 8] |= 1 << (i % 8);
        }
    }
    out
}

/// Inverse of `pack_bits_lsb_first`. Reads `bit_count` bits out of `bytes`
/// (LSB-first within each byte).
pub fn unpack_bits_lsb_first(bytes: &[u8], bit_count: usize) -> Result<Vec<bool>, &'static str> {
    if bytes.len() * 8 < bit_count {
        return Err("byte buffer shorter than requested bit count");
    }
    let mut out = Vec::with_capacity(bit_count);
    for i in 0..bit_count {
        let b = (bytes[i / 8] >> (i % 8)) & 1 != 0;
        out.push(b);
    }
    Ok(out)
}

// =================================================================== //
// Transport trait + high-level meal commands
// =================================================================== //

/// One round-trip with the chip: drive `tx_bits` host slots, capture
/// `rx_bit_count` enclave slots, return the captured bits.
///
/// Implementors:
/// - `BridgeTransport` (bridge.rs) — production: USB → RP2040 → wire.
/// - `SimTransport` (this module's tests) — runs the L3 client against a
///   pure-Rust "chip emulator" that mirrors `rtl/l3_session_fsm.v`'s
///   wire-level behaviour. Useful for end-to-end test without hardware.
pub trait Transport {
    /// Execute one round-trip exchange. Returned vector length is
    /// `rx_bit_count`. Implementors must preserve slot phase across calls so
    /// fresh-session → Message B → Message B in sequence Just Works without
    /// re-acquiring CDR.
    fn round(&mut self, tx_bits: &[bool], rx_bit_count: usize) -> Result<Vec<bool>, String>;
}

/// Result of the `meal_health` orchestration: whether the chip's response
/// matched a Q_HEALTH commitment for the given (state, mode) hypothesis.
#[derive(Debug)]
pub struct MealHealthReport {
    pub state: StateBlock,
    pub mode: Mode,
    pub recovered_response: Word256,
    pub expected_response: Word256,
    pub q_health_pass: bool,
}

/// Run the q/health orchestration: fresh-session, then one Q_HEALTH
/// Message-B exchange with the given mode, then verify the response commits
/// to `expected_state` under the chip's active key.
///
/// Caller picks `mode`:
/// - `Mode::Permanent` proves the chip's eFuse-backed `ira` committed to
///   that state. Strongest evidence for the patent demo.
/// - `Mode::Session` proves the live session's `wairua` committed to it.
pub fn meal_health<T: Transport>(
    transport: &mut T,
    ira: Word256,
    mode: Mode,
    expected_state: StateBlock,
) -> Result<MealHealthReport, String> {
    let mut client = L3Client::new(ira);

    let req = client.fresh_session_encode();
    let resp = transport.round(&req, FRESH_SESSION_WIRE_BITS)?;
    client
        .fresh_session_decode(&resp)
        .map_err(|e| format!("fresh-session decode: {}", e))?;

    let req2 = client.message_b_encode(&Q_HEALTH_IDENT, mode);
    let resp2 = transport.round(&req2, MESSAGE_B_WIRE_BITS)?;
    let recovered = client
        .message_b_decode(&resp2, &Q_HEALTH_IDENT, mode)
        .map_err(|e| format!("Message-B decode (q/health): {:?}", e))?;

    let expected = client.q_health_expected(&expected_state, mode);
    Ok(MealHealthReport {
        state: expected_state,
        mode,
        recovered_response: recovered,
        expected_response: expected,
        q_health_pass: recovered == expected,
    })
}

/// Result of the `meal_motuhake` A/B/C/D orchestration. Each field captures
/// one of the four Message-B exchanges (two SESSION, two PERMANENT, all with
/// `message_req = BLAKE3("motuhake")`).
#[derive(Debug)]
pub struct MealMotuhakeReport {
    pub a_session_1: Word256,
    pub b_session_2: Word256,
    pub c_permanent_1: Word256,
    pub d_permanent_2: Word256,
    /// A == B (determinism under same key, same message)
    pub session_deterministic: bool,
    /// C == D
    pub permanent_deterministic: bool,
    /// A != C (SESSION and PERMANENT live in different keyspaces)
    pub modes_separated: bool,
    /// C == BLAKE3.keyed(IRA, MOTUHAKE) — host can recompute PERMANENT standalone
    pub permanent_matches_local_recompute: bool,
}

/// Run the motuhake A/B/C/D orchestration.
///
/// One fresh-session, then four Message-B exchanges with the same
/// `message_req = BLAKE3("motuhake")`: two SESSION, two PERMANENT. Verifies
/// the canonical "same message → same response within key" property and the
/// host's ability to recompute the PERMANENT response standalone.
pub fn meal_motuhake<T: Transport>(transport: &mut T, ira: Word256) -> Result<MealMotuhakeReport, String> {
    let motuhake = {
        let h = blake3::hash(b"motuhake");
        let mut w = [0u8; 32];
        w.copy_from_slice(h.as_bytes());
        w
    };

    let mut client = L3Client::new(ira);
    let req = client.fresh_session_encode();
    let resp = transport.round(&req, FRESH_SESSION_WIRE_BITS)?;
    client
        .fresh_session_decode(&resp)
        .map_err(|e| format!("fresh-session decode: {}", e))?;

    let mut do_one = |mode: Mode| -> Result<Word256, String> {
        let req = client.message_b_encode(&motuhake, mode);
        let resp = transport.round(&req, MESSAGE_B_WIRE_BITS)?;
        client
            .message_b_decode(&resp, &motuhake, mode)
            .map_err(|e| format!("Message-B decode ({:?}): {:?}", mode, e))
    };

    let a = do_one(Mode::Session)?;
    let b = do_one(Mode::Session)?;
    let c = do_one(Mode::Permanent)?;
    let d = do_one(Mode::Permanent)?;

    let local_permanent = {
        // Match the chip's BLAKE3 byte order: reverse the key and input
        // bytes before feeding to Rust BLAKE3, reverse the output before
        // storing as a host Word256. See `blake3_plain32` / `reverse_bytes`
        // doc for the why.
        let canonical_key = reverse_bytes(&ira);
        let canonical_msg = reverse_bytes(&motuhake);
        let mut h = Hasher::new_keyed(&canonical_key);
        h.update(&canonical_msg);
        let mut canonical_out = [0u8; 32];
        canonical_out.copy_from_slice(h.finalize().as_bytes());
        reverse_bytes(&canonical_out)
    };

    Ok(MealMotuhakeReport {
        a_session_1: a,
        b_session_2: b,
        c_permanent_1: c,
        d_permanent_2: d,
        session_deterministic: a == b,
        permanent_deterministic: c == d,
        modes_separated: a != c,
        permanent_matches_local_recompute: c == local_permanent,
    })
}

// =================================================================== //
// Tests
// =================================================================== //

#[cfg(test)]
mod tests {
    use super::*;

    /// Same fixed wairua the iverilog testbench uses, so cross-validation
    /// against `rtl/measure/l3_session_fsm_tb.v` results is bit-exact.
    const WAIRUA_FIXED: Word256 = [
        0xa5, 0xa5, 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x0f, 0xed, 0xcb, 0xa9, 0x87, 0x65, 0x43, 0x21,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
    ];

    /// Same fixed IRA the iverilog testbench uses.
    const IRA_FIXED: Word256 = [
        0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44,
        0x55, 0x55, 0x66, 0x66, 0x77, 0x77, 0x88, 0x88,
        0x99, 0x99, 0xaa, 0xaa, 0xbb, 0xbb, 0xcc, 0xcc,
        0xdd, 0xdd, 0xee, 0xee, 0xff, 0xff, 0x00, 0x00,
    ];

    #[test]
    fn debug_compare_blake3_to_chip_h_req() {
        // User's wairua from OLED MODE 4 (typed left-to-right as 64 hex chars):
        let wairua_hex = "948246a59d484cd671006042652d007476392783e84071df5395c87480da5ad9";
        // Chip's H_req[255:224] from OLED MODE 5 line 3:
        let chip_h_req_finger = "30a7c85a";

        let mut wairua = [0u8; 32];
        for i in 0..32 {
            wairua[i] = u8::from_str_radix(&wairua_hex[2*i..2*i+2], 16).unwrap();
        }
        // Try BLAKE3 in 4 orderings:
        let canon = blake3::hash(&wairua);
        let mut rev = [0u8; 32];
        for i in 0..32 { rev[i] = wairua[31 - i]; }
        let reversed_input = blake3::hash(&rev);

        eprintln!("\nChip's H_req[255:224] (per OLED MODE 5): {}", chip_h_req_finger);
        eprintln!("Wairua user typed (chip's OLED display, MSB-first): {}", wairua_hex);
        eprintln!();
        eprintln!("Rust BLAKE3(wairua_as_typed):");
        eprintln!("  canonical hex (byte[0]..byte[31]): {}", canon.to_hex());
        eprintln!("  first  4 bytes = {:02x}{:02x}{:02x}{:02x}",
            canon.as_bytes()[0], canon.as_bytes()[1], canon.as_bytes()[2], canon.as_bytes()[3]);
        eprintln!("  last   4 bytes = {:02x}{:02x}{:02x}{:02x}",
            canon.as_bytes()[28], canon.as_bytes()[29], canon.as_bytes()[30], canon.as_bytes()[31]);
        eprintln!("Rust BLAKE3(reverse(wairua_as_typed)):");
        eprintln!("  canonical hex: {}", reversed_input.to_hex());
        eprintln!("  first  4 bytes = {:02x}{:02x}{:02x}{:02x}",
            reversed_input.as_bytes()[0], reversed_input.as_bytes()[1], reversed_input.as_bytes()[2], reversed_input.as_bytes()[3]);
        eprintln!("  last   4 bytes = {:02x}{:02x}{:02x}{:02x}",
            reversed_input.as_bytes()[28], reversed_input.as_bytes()[29], reversed_input.as_bytes()[30], reversed_input.as_bytes()[31]);
        eprintln!();
        eprintln!("Match means: chip's H_req[255:224] = one of those 4 byte sequences");
    }

    #[test]
    fn debug_print_motuhake_hash_byteorder() {
        let h = blake3::hash(b"motuhake");
        eprintln!("\nRust BLAKE3(b\"motuhake\") canonical hex: {}", h.to_hex());
        eprintln!("  byte[0]=0x{:02x}  byte[1]=0x{:02x}  byte[30]=0x{:02x}  byte[31]=0x{:02x}",
                  h.as_bytes()[0], h.as_bytes()[1], h.as_bytes()[30], h.as_bytes()[31]);
        eprintln!("Verilog testbench %h MOTUHAKE: f428e3a9552aad2fc6202321b9e814b8fe653c8bf2d3dc53b410e65a57733697");
        eprintln!("  → verilog bits [255:248] = 0xf4 (leftmost 2 hex chars of %h)");
        eprintln!("  → verilog bits [7:0]     = 0x97 (rightmost 2 hex chars of %h)");
    }

    #[test]
    fn q_health_ident_matches_blake3_of_phrase() {
        let h = blake3::hash(b"Kei te ora koe?");
        assert_eq!(h.as_bytes(), &Q_HEALTH_IDENT);
    }

    #[test]
    fn fresh_session_encode_is_one_then_zeros() {
        let c = L3Client::new(IRA_FIXED);
        let bits = c.fresh_session_encode();
        assert_eq!(bits.len(), FRESH_SESSION_WIRE_BITS);
        assert!(bits[0]);
        assert!(bits[1..].iter().all(|&b| !b));
    }

    #[test]
    fn fresh_session_decode_derives_pads() {
        let mut c = L3Client::new(IRA_FIXED);
        // Construct the enclave's response: frame + 256 wairua MSB-first.
        let mut wire = Vec::with_capacity(FRESH_SESSION_WIRE_BITS);
        wire.push(true);
        push_word256_msb_first(&mut wire, &WAIRUA_FIXED);
        c.fresh_session_decode(&wire).expect("decode failed");
        assert_eq!(c.wairua, WAIRUA_FIXED);
        assert_eq!(c.h_req, blake3_plain32(&WAIRUA_FIXED));
        assert_eq!(c.h_resp, blake3_plain32(&bitwise_not_word256(&WAIRUA_FIXED)));
        assert!(c.session_valid);
    }

    #[test]
    fn fresh_session_decode_rejects_missing_frame() {
        let mut c = L3Client::new(IRA_FIXED);
        let bad = vec![false; FRESH_SESSION_WIRE_BITS];
        assert!(c.fresh_session_decode(&bad).is_err());
    }

    /// End-to-end: build the SAME X1/X2 the iverilog testbench builds, prove
    /// the encode/decode pair is self-consistent, and recover an arbitrary
    /// `message_resp` round-tripped thru a simulated enclave.
    #[test]
    fn message_b_roundtrip_session_and_permanent() {
        let mut client = L3Client::new(IRA_FIXED);
        let mut wire = Vec::with_capacity(FRESH_SESSION_WIRE_BITS);
        wire.push(true);
        push_word256_msb_first(&mut wire, &WAIRUA_FIXED);
        client.fresh_session_decode(&wire).unwrap();

        let motuhake = {
            let h = blake3::hash(b"motuhake");
            let mut w = [0u8; 32];
            w.copy_from_slice(h.as_bytes());
            w
        };

        for mode in [Mode::Permanent, Mode::Session] {
            // Snapshot pads before the exchange (the enclave uses these).
            let h_req_pre = client.h_req;
            let h_resp_pre = client.h_resp;
            let req_bits = client.message_b_encode(&motuhake, mode);
            assert_eq!(req_bits.len(), MESSAGE_B_WIRE_BITS);
            assert!(req_bits[0], "frame bit must be 1");

            // Simulate the enclave: extract X1 / X2, recover message_req,
            // pick active_key, compute message_resp = BLAKE3.keyed(key, msg).
            let x1 = bits_to_word256_msb_first(&req_bits[1..257]).unwrap();
            let x2 = bits_to_word256_msb_first(&req_bits[257..513]).unwrap();
            let mut recovered = [0u8; 32];
            for i in 0..32 {
                recovered[i] = x1[i] ^ h_req_pre[i];
            }
            assert_eq!(recovered, motuhake, "enclave recovers original message");

            // Verify mode-detection: expected X2 under the chosen mode.
            let h_msg = blake3_plain32(&motuhake);
            let expected_x2 = match mode {
                Mode::Session => {
                    let mut t = [0u8; 32];
                    for i in 0..32 {
                        t[i] = h_msg[i] ^ h_resp_pre[i];
                    }
                    t
                }
                Mode::Permanent => {
                    let mut t = [0u8; 32];
                    for i in 0..32 {
                        t[i] = (!h_msg[i]) ^ h_resp_pre[i];
                    }
                    t
                }
            };
            assert_eq!(x2, expected_x2);

            // Compute enclave's response.
            let key = match mode {
                Mode::Session => WAIRUA_FIXED,
                Mode::Permanent => IRA_FIXED,
            };
            let message_resp = {
                let mut h = Hasher::new_keyed(&key);
                h.update(&motuhake);
                let mut w = [0u8; 32];
                w.copy_from_slice(h.finalize().as_bytes());
                w
            };

            // Build the enclave's wire reply: frame + X1' + X2'.
            let mut x1p = [0u8; 32];
            for i in 0..32 {
                x1p[i] = message_resp[i] ^ h_req_pre[i];
            }
            let h_resp_msg = blake3_plain32(&message_resp);
            let x2p = match mode {
                Mode::Session => {
                    let mut t = [0u8; 32];
                    for i in 0..32 {
                        t[i] = h_resp_msg[i] ^ h_resp_pre[i];
                    }
                    t
                }
                Mode::Permanent => {
                    let mut t = [0u8; 32];
                    for i in 0..32 {
                        t[i] = (!h_resp_msg[i]) ^ h_resp_pre[i];
                    }
                    t
                }
            };
            let mut reply_bits = Vec::with_capacity(MESSAGE_B_WIRE_BITS);
            reply_bits.push(true);
            push_word256_msb_first(&mut reply_bits, &x1p);
            push_word256_msb_first(&mut reply_bits, &x2p);

            // Decode and verify.
            let recovered_resp = client
                .message_b_decode(&reply_bits, &motuhake, mode)
                .expect("decode should succeed");
            assert_eq!(recovered_resp, message_resp, "recovered response matches");

            // Pads must have ratcheted.
            assert_eq!(client.h_req, blake3_plain32(&motuhake));
            assert_eq!(client.h_resp, blake3_plain32(&message_resp));
        }
    }

    #[test]
    fn message_b_single_bit_fault_x1_is_caught() {
        let mut client = L3Client::new(IRA_FIXED);
        let mut wire = Vec::with_capacity(FRESH_SESSION_WIRE_BITS);
        wire.push(true);
        push_word256_msb_first(&mut wire, &WAIRUA_FIXED);
        client.fresh_session_decode(&wire).unwrap();
        let motuhake = {
            let h = blake3::hash(b"motuhake");
            let mut w = [0u8; 32];
            w.copy_from_slice(h.as_bytes());
            w
        };
        // We'd flip a bit before sending — but on the host side the wire-
        // corruption test happens on RX (we receive a corrupted response).
        // Build a malformed reply: correct frame bit and X1', wrong X2'.
        let mut reply = vec![false; MESSAGE_B_WIRE_BITS];
        reply[0] = true;
        let _ = client.message_b_encode(&motuhake, Mode::Permanent); // populate state expectations
        // Fill X1' with whatever (won't matter; X2' mismatch caught first)
        for i in 1..513 {
            reply[i] = (i % 3) == 0;
        }
        let err = client
            .message_b_decode(&reply, &motuhake, Mode::Permanent)
            .unwrap_err();
        assert_eq!(err, MessageBError::X2Mismatch);
        // Pads must NOT have advanced.
        assert_eq!(client.h_req, blake3_plain32(&WAIRUA_FIXED));
    }

    #[test]
    fn state_block_pack_layout_matches_fsm() {
        // Known-vector: same values the iverilog testbench plugs into the
        // chip_state_in / ring_*_in / ... ports for Test 6. Hand-computed
        // the expected bit layout per PROTOCOL.md.
        let s = StateBlock {
            chip_state: 4,
            ring_health_mask: 0xFFFC,
            ring_health_cnt: 14,
            slot_burned_mask: 0xFF,
            fsm_state: 0,
            session_counter: 3,
            boot_epoch: 0,
            drop_counter: 0,
        };
        let bytes = s.pack();
        // bits[2:0] = chip_state = 4 = 100b
        // bits[18:3] = mask = 0xFFFC = ...1111111100b
        // Spot-check the low byte (bits 7..0):
        //   bit 0 = chip_state bit 0 = 0
        //   bit 1 = chip_state bit 1 = 0
        //   bit 2 = chip_state bit 2 = 1
        //   bit 3 = mask bit 0       = 0  (0xFFFC LSB)
        //   bit 4 = mask bit 1       = 0
        //   bit 5 = mask bit 2       = 1
        //   bit 6 = mask bit 3       = 1
        //   bit 7 = mask bit 4       = 1
        // low byte = 11100100 = 0xE4
        assert_eq!(bytes[31], 0xE4);
        // bits[15:8] = mask bits 12..5 = all 1 → 0xFF
        assert_eq!(bytes[30], 0xFF);
        // bits[23:16] = mask bits 15..13 (3 bits = 111) || ring_cnt bits 4..0
        // = 14 → 0...01110 (5 bits) → 01110_111b = 0x77
        assert_eq!(bytes[29], 0x77);
        // bits[31:24] = slot_burned_mask = 0xFF
        assert_eq!(bytes[28], 0xFF);
        // bits[34:32] = fsm_state = 0
        // bits[39:35] = session_counter bits 4..0 = 00011
        // bits[39:32] = 00011_000 = 0x18
        assert_eq!(bytes[27], 0x18);
        // High end zeros (drop=0, boot=0, reserved=0).
        assert_eq!(bytes[0], 0);
        assert_eq!(bytes[1], 0);
        assert_eq!(bytes[2], 0);
    }

    /// Pure-Rust emulation of `rtl/l3_session_fsm.v` at the wire-bit level.
    /// Lets `meal_health` / `meal_motuhake` be exercised end-to-end without
    /// hardware, so we can prove the orchestration logic is correct before
    /// the firmware lands.
    struct SimTransport {
        ira: Word256,
        wairua: Word256,
        h_req: Word256,
        h_resp: Word256,
        session_valid: bool,
        session_counter: u64,
        drop_counter: u64,
        // Free-running counter so q/health responses have a varying boot_epoch
        sim_clock_at_response: u64,
    }

    impl SimTransport {
        fn new(ira: Word256, wairua: Word256) -> Self {
            Self {
                ira,
                wairua,
                h_req: [0u8; 32],
                h_resp: [0u8; 32],
                session_valid: false,
                session_counter: 0,
                drop_counter: 0,
                sim_clock_at_response: 0,
            }
        }
    }

    impl Transport for SimTransport {
        fn round(&mut self, tx_bits: &[bool], rx_bit_count: usize) -> Result<Vec<bool>, String> {
            // Inspect first bit (frame) + rest of payload to decide which path.
            if tx_bits.is_empty() || !tx_bits[0] {
                return Err("sim: missing frame bit".into());
            }
            let payload = &tx_bits[1..];
            self.sim_clock_at_response += 1000; // arbitrary increment

            // Fresh-session: 256 zero data bits.
            if payload.len() == 256 && payload.iter().all(|b| !b) {
                // Pretend we just drew wairua from TRNG; emit it.
                self.h_req = blake3_plain32(&self.wairua);
                self.h_resp = blake3_plain32(&bitwise_not_word256(&self.wairua));
                self.session_valid = true;
                self.session_counter = 0;
                let mut out = Vec::with_capacity(rx_bit_count);
                out.push(true);
                push_word256_msb_first(&mut out, &self.wairua);
                if out.len() != rx_bit_count {
                    return Err(format!(
                        "sim: fresh-session expects rx_bit_count={}, got {}",
                        out.len(),
                        rx_bit_count
                    ));
                }
                return Ok(out);
            }

            // Message B: 512 data bits = X1 (256) || X2 (256).
            if payload.len() == 512 {
                if !self.session_valid {
                    self.drop_counter += 1;
                    return Err("sim: Message B before fresh-session".into());
                }
                let x1 = bits_to_word256_msb_first(&payload[..256]).unwrap();
                let x2 = bits_to_word256_msb_first(&payload[256..]).unwrap();
                // Recover message_req
                let mut message_req = [0u8; 32];
                for i in 0..32 {
                    message_req[i] = x1[i] ^ self.h_req[i];
                }
                let h_msg = blake3_plain32(&message_req);
                // Try both invariants
                let mut x2_session = [0u8; 32];
                let mut x2_permanent = [0u8; 32];
                for i in 0..32 {
                    x2_session[i] = h_msg[i] ^ self.h_resp[i];
                    x2_permanent[i] = (!h_msg[i]) ^ self.h_resp[i];
                }
                let (mode, active_key) = if x2 == x2_session {
                    (Mode::Session, &self.wairua)
                } else if x2 == x2_permanent {
                    (Mode::Permanent, &self.ira)
                } else {
                    self.drop_counter += 1;
                    return Err("sim: X2 mismatch → DROP".into());
                };
                let is_query = message_req == Q_HEALTH_IDENT;
                // Compute response
                let message_resp = if is_query {
                    let state = StateBlock {
                        chip_state: 4,
                        ring_health_mask: 0xFFFC,
                        ring_health_cnt: 14,
                        slot_burned_mask: 0xFF,
                        fsm_state: 0,
                        session_counter: self.session_counter,
                        boot_epoch: self.sim_clock_at_response,
                        drop_counter: self.drop_counter,
                    };
                    let state_bytes = state.pack();
                    let mut mblock = [0u8; 64];
                    mblock[0..32].copy_from_slice(&message_req);
                    mblock[32..64].copy_from_slice(&state_bytes);
                    let mut hasher = Hasher::new_keyed(active_key);
                    hasher.update(&mblock);
                    let mut out = [0u8; 32];
                    out.copy_from_slice(hasher.finalize().as_bytes());
                    out
                } else {
                    let mut hasher = Hasher::new_keyed(active_key);
                    hasher.update(&message_req);
                    let mut out = [0u8; 32];
                    out.copy_from_slice(hasher.finalize().as_bytes());
                    out
                };
                // Build wire reply
                let h_resp_msg = blake3_plain32(&message_resp);
                let mut x1p = [0u8; 32];
                for i in 0..32 {
                    x1p[i] = message_resp[i] ^ self.h_req[i];
                }
                let x2p = match mode {
                    Mode::Session => {
                        let mut t = [0u8; 32];
                        for i in 0..32 {
                            t[i] = h_resp_msg[i] ^ self.h_resp[i];
                        }
                        t
                    }
                    Mode::Permanent => {
                        let mut t = [0u8; 32];
                        for i in 0..32 {
                            t[i] = (!h_resp_msg[i]) ^ self.h_resp[i];
                        }
                        t
                    }
                };
                // Ratchet
                self.h_req = blake3_plain32(&message_req);
                self.h_resp = blake3_plain32(&message_resp);
                self.session_counter += 1;
                let mut out = Vec::with_capacity(rx_bit_count);
                out.push(true);
                push_word256_msb_first(&mut out, &x1p);
                push_word256_msb_first(&mut out, &x2p);
                if out.len() != rx_bit_count {
                    return Err(format!(
                        "sim: Message-B expects rx_bit_count={}, got {}",
                        out.len(),
                        rx_bit_count
                    ));
                }
                return Ok(out);
            }

            Err(format!(
                "sim: unrecognized request shape (frame + {} payload bits)",
                payload.len()
            ))
        }
    }

    #[test]
    fn meal_motuhake_against_sim_passes_all_properties() {
        let mut sim = SimTransport::new(IRA_FIXED, WAIRUA_FIXED);
        let report = meal_motuhake(&mut sim, IRA_FIXED).expect("orchestration succeeded");
        assert!(report.session_deterministic, "A == B");
        assert!(report.permanent_deterministic, "C == D");
        assert!(report.modes_separated, "A != C");
        assert!(
            report.permanent_matches_local_recompute,
            "C == BLAKE3.keyed(IRA, MOTUHAKE)"
        );
    }

    #[test]
    fn meal_health_against_sim_passes_for_matching_state() {
        let mut sim = SimTransport::new(IRA_FIXED, WAIRUA_FIXED);
        // Mirror what the sim will fill in.
        let expected = StateBlock {
            chip_state: 4,
            ring_health_mask: 0xFFFC,
            ring_health_cnt: 14,
            slot_burned_mask: 0xFF,
            fsm_state: 0,
            session_counter: 0,
            boot_epoch: 2000, // sim_clock_at_response increments per call; q-health is the 2nd call
            drop_counter: 0,
        };
        let report = meal_health(&mut sim, IRA_FIXED, Mode::Permanent, expected)
            .expect("orchestration succeeded");
        assert!(
            report.q_health_pass,
            "q/health commitment matched: recovered={:?} expected={:?}",
            report.recovered_response, report.expected_response
        );
    }

    #[test]
    fn meal_health_against_sim_fails_for_mismatched_state() {
        let mut sim = SimTransport::new(IRA_FIXED, WAIRUA_FIXED);
        let wrong = StateBlock {
            chip_state: 1, // FUCKED — but sim claims HEALTHY (4)
            ring_health_mask: 0xFFFC,
            ring_health_cnt: 14,
            slot_burned_mask: 0xFF,
            fsm_state: 0,
            session_counter: 0,
            boot_epoch: 2000,
            drop_counter: 0,
        };
        let report = meal_health(&mut sim, IRA_FIXED, Mode::Permanent, wrong)
            .expect("orchestration succeeded");
        assert!(!report.q_health_pass, "wrong state must produce mismatch");
    }

    #[test]
    fn bit_packing_roundtrip() {
        let bits = vec![true, false, true, true, false, false, false, true, true, false];
        let packed = pack_bits_msb_first(&bits);
        let unpacked = unpack_bits_msb_first(&packed, bits.len()).unwrap();
        assert_eq!(bits, unpacked);
        // First byte = 10110001 = 0xB1
        assert_eq!(packed[0], 0xB1);
    }

    #[test]
    fn bit_packing_lsb_first_roundtrip() {
        let bits = vec![true, false, true, true, false, false, false, true, true, false];
        let packed = pack_bits_lsb_first(&bits);
        let unpacked = unpack_bits_lsb_first(&packed, bits.len()).unwrap();
        assert_eq!(bits, unpacked);
        // First byte = bit7..bit0 = 1_0_0_0_1_1_0_1 = 0x8D
        assert_eq!(packed[0], 0x8D);
    }
}
