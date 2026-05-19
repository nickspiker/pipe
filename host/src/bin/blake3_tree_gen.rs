// blake3_tree_gen — generate the 8 KB test vector for blake3_tree.v differential test
//
// Builds a deterministic 8192-byte input pattern (ASCII-art header + xorshift32 fill),
// computes its BLAKE3 hash with the reference Rust impl, and writes both as hex files
// for the iverilog testbench to $readmemh.
//
// Usage: blake3_tree_gen <out_dir>
//   Writes <out_dir>/blake3_tree_input.hex     (8192 lines, one byte per line)
//          <out_dir>/blake3_tree_expected.hex  (32  lines, one byte per line)

use std::fs::{self, File};
use std::io::Write;
use std::path::PathBuf;

fn main() -> std::io::Result<()> {
    let out_dir: PathBuf = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "build/blake3_tree_test".to_string())
        .into();
    fs::create_dir_all(&out_dir)?;

    let mut buf = vec![0u8; 8192];

    // Identifiable header — easy to spot in waveform dumps and hex prints.
    // Length isn't critical; whatever this is, both sides see the same bytes.
    let art: &[u8] = b"\
+================================+\n\
|   PIPE TRNG -> BLAKE3 TREE     |\n\
|   8 rings, 4-of-8 healthy OK   |\n\
|   65536-bit XOR'd buffer       |\n\
|   8 chunks of 1024 bytes       |\n\
|   parents: 4 -> 2 -> 1 (ROOT)  |\n\
|   ferros oracle  2026-05-13    |\n\
+================================+\n\
\n\
Below: 8064 bytes of xorshift32(seed=0xCAFE_BABE) fill.\n\
Any spec-correct BLAKE3 over these 8192 bytes produces the\n\
hash in blake3_tree_expected.hex. Both must match for PASS.\n\
\n\
=== fill ===\n";
    let n = art.len().min(buf.len());
    buf[..n].copy_from_slice(&art[..n]);

    // xorshift32, low byte each step. Deterministic, well-known, doesn't
    // touch BLAKE3 itself (so we're not testing BLAKE3 with BLAKE3 output).
    let mut state: u32 = 0xCAFE_BABE;
    for byte in &mut buf[n..] {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        *byte = state as u8;
    }

    let hash = blake3::hash(&buf);

    let mut f = File::create(out_dir.join("blake3_tree_input.hex"))?;
    for &b in &buf {
        writeln!(f, "{:02x}", b)?;
    }

    let mut g = File::create(out_dir.join("blake3_tree_expected.hex"))?;
    for &b in hash.as_bytes() {
        writeln!(g, "{:02x}", b)?;
    }

    println!(
        "Generated {} bytes of test input ({} header + {} fill).",
        buf.len(),
        n,
        buf.len() - n
    );
    println!("Output dir: {}", out_dir.display());
    println!("Expected BLAKE3 hash: {}", hash.to_hex());

    Ok(())
}
