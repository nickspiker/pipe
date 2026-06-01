//! PIPE host-side library.
//!
//! Mirror-XOR codec (matches `rtl/codec.v` bit-for-bit), FT232H bit-bang driver, and CDR helpers.
//!
//! See `../../PROTOCOL.md` for the line-code spec. The codec here implements the same encode/decode rules as the Verilog module; both sides build against the same spec, so round-trip traffic between this code and the FPGA codec must agree by construction.

pub mod cdr;
pub mod codec;
pub mod ft232h;
pub mod l3;
