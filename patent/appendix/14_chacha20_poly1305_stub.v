// ============================================================================
// chacha20_poly1305.v -- AEAD construction (PORT-INTERFACE STUB)
// ============================================================================
//
// PORT-INTERFACE STUB. The full ChaCha20-Poly1305 authenticated-encryption-with-associated-data construction is published at:
//
//   IETF RFC 8439: "ChaCha20 and Poly1305 for IETF Protocols," June 2018.
//
// This stub depicts the port interface by which the chip-side modules invoke ChaCha20-Poly1305 authenticated encryption and decryption of the per-message ciphertext field following the ephemeral session public key.
// The ChaCha20 stream cipher quarter-round, the Poly1305 universal-hash authenticator, and the AEAD nonce-handling logic are omitted from this appendix as they are published prior art not material to the novelty of the present invention.
//
// USAGE: assert `encrypt_valid` for encrypt-and-authenticate, or `decrypt_valid` for verify-and-decrypt.
// The 256-bit `key` is the session key derived from the X25519 scalar multiplication of x25519.v.
//
// ============================================================================

`timescale 1ns / 1ps

module chacha20_poly1305 #(
    parameter integer PLAINTEXT_BITS  = 256,
    parameter integer ASSOC_DATA_BITS = 256
) (
    input  wire                          clk,
    input  wire                          reset_n,

    input  wire [255:0]                  key,
    input  wire [95:0]                   nonce,
    input  wire [ASSOC_DATA_BITS-1:0]    assoc_data,

    // Encrypt path
    input  wire                          encrypt_valid,
    input  wire [PLAINTEXT_BITS-1:0]     plaintext_in,
    output wire [PLAINTEXT_BITS-1:0]     ciphertext_out,
    output wire [127:0]                  tag_out,
    output wire                          encrypt_done,

    // Decrypt path
    input  wire                          decrypt_valid,
    input  wire [PLAINTEXT_BITS-1:0]     ciphertext_in,
    input  wire [127:0]                  tag_in,
    output wire [PLAINTEXT_BITS-1:0]     plaintext_out,
    output wire                          tag_ok,
    output wire                          decrypt_done
);

    // Reference implementation omitted. See cited specification.

endmodule
