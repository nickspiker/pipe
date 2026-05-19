//! Bake a printable-ASCII glyph atlas + per-glyph advance widths from a TTF, for use by a runtime FPGA text renderer.
//!
//! Output is a fixed-cell layout: each of the 95 glyphs (ASCII 0x20..0x7E) occupies a CELL_W × CELL_H byte block of the atlas, with the glyph's bitmap positioned within the cell so the cell origin (top-left, pixel 0,0) maps to a virtual `(cursor_x - PAD_LEFT, baseline_y - MAX_ASCENT)` at render time. The renderer just blits the cell at that position; positioning is fully baked in.
//!
//! Files written into `<out_dir>/`:
//!   glyph_atlas.mem  — 95 × CELL_H × CELL_W bytes hex ($readmemh, 16 per line)
//!   glyph_advance.mem — 95 bytes hex (advance width per glyph)
//!   glyph_dims.vh    — Verilog `include with CELL_W, CELL_H, etc. as `define
//!
//! CLI: `oled-bake-atlas <font.ttf> <px_size> <out_dir> [--pow2]`
//!   --pow2 rounds CELL_W and CELL_H up to the next power of 2 for clean BRAM addressing (recommended).

use fontdue::{Font, FontSettings};
use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;

const FIRST_CHAR: u8 = 0x20;
const LAST_CHAR: u8 = 0x7E;
const NUM_CHARS: usize = (LAST_CHAR - FIRST_CHAR + 1) as usize;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: oled-bake-atlas <font.ttf> <px_size> <out_dir> [--pow2]");
        std::process::exit(2);
    }
    let font_path = &args[1];
    let px: f32 = args[2].parse()?;
    let out_dir = Path::new(&args[3]);
    let pow2 = args.iter().any(|s| s == "--pow2");

    fs::create_dir_all(out_dir)?;
    let font_data = fs::read(font_path)?;
    let font = Font::from_bytes(font_data, FontSettings::default())
        .map_err(|e| format!("font load: {e}"))?;

    // First pass: rasterize every glyph, learn extents.
    let mut rasters = Vec::with_capacity(NUM_CHARS);
    let mut tight_w = 0i32;
    let mut max_ascent = 0i32;
    let mut max_descent = 0i32;
    let mut pad_left = 0i32;
    for c in FIRST_CHAR..=LAST_CHAR {
        let (metrics, bitmap) = font.rasterize(c as char, px);
        if metrics.xmin < 0 {
            pad_left = pad_left.max(-metrics.xmin);
        }
        // Where the bitmap's top edge sits above the baseline (positive Y up).
        let top_above = metrics.ymin + metrics.height as i32;
        max_ascent = max_ascent.max(top_above);
        max_descent = max_descent.max(-metrics.ymin);
        // Furthest right pixel of any glyph from the advance origin.
        tight_w = tight_w.max(pad_left + metrics.xmin + metrics.width as i32);
        rasters.push((metrics, bitmap));
    }

    let tight_h = max_ascent + max_descent;
    let (cell_w, cell_h) = if pow2 {
        (
            next_pow2(tight_w as u32) as i32,
            next_pow2(tight_h as u32) as i32,
        )
    } else {
        (tight_w, tight_h)
    };

    eprintln!(
        "oled-bake-atlas: pad_left={pad_left} max_ascent={max_ascent} max_descent={max_descent} tight={tight_w}×{tight_h} → cell={cell_w}×{cell_h}",
    );

    // Second pass: render each glyph into its cell.
    let cell_size = (cell_w * cell_h) as usize;
    let mut atlas = vec![0u8; NUM_CHARS * cell_size];
    let mut advance = vec![0u8; NUM_CHARS];

    for (idx, (metrics, bitmap)) in rasters.iter().enumerate() {
        advance[idx] = metrics.advance_width.round().clamp(0.0, 255.0) as u8;
        if metrics.width == 0 || metrics.height == 0 {
            continue; // space etc. — leave cell as zeros
        }
        // Where this glyph's bitmap top-left lands inside its cell:
        let cell_x = (pad_left + metrics.xmin).max(0) as usize;
        let cell_y = (max_ascent - metrics.ymin - metrics.height as i32).max(0) as usize;
        let base = idx * cell_size;
        for j in 0..metrics.height {
            for i in 0..metrics.width {
                let dx = cell_x + i;
                let dy = cell_y + j;
                if dx >= cell_w as usize || dy >= cell_h as usize {
                    continue;
                }
                atlas[base + dy * cell_w as usize + dx] = bitmap[j * metrics.width + i];
            }
        }
    }

    write_memh(&atlas, &out_dir.join("glyph_atlas.mem"))?;
    write_memh(&advance, &out_dir.join("glyph_advance.mem"))?;
    write_dims_vh(
        &out_dir.join("glyph_dims.vh"),
        cell_w as u32,
        cell_h as u32,
        pad_left as u32,
        max_ascent as u32,
        max_descent as u32,
    )?;

    eprintln!(
        "oled-bake-atlas: wrote atlas {} bytes ({} chars × {}×{}), advance {} bytes",
        atlas.len(),
        NUM_CHARS,
        cell_w,
        cell_h,
        advance.len()
    );
    Ok(())
}

fn next_pow2(mut n: u32) -> u32 {
    if n <= 1 {
        return 1;
    }
    n -= 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n + 1
}

fn write_memh(buf: &[u8], path: &Path) -> std::io::Result<()> {
    let mut f = fs::File::create(path)?;
    for chunk in buf.chunks(16) {
        let mut line = String::new();
        for (i, b) in chunk.iter().enumerate() {
            if i > 0 {
                line.push(' ');
            }
            line.push_str(&format!("{:02x}", b));
        }
        writeln!(f, "{}", line)?;
    }
    Ok(())
}

fn write_dims_vh(
    path: &Path,
    cell_w: u32,
    cell_h: u32,
    pad_left: u32,
    max_ascent: u32,
    max_descent: u32,
) -> std::io::Result<()> {
    let mut f = fs::File::create(path)?;
    writeln!(f, "// auto-generated by oled-bake-atlas — do not edit")?;
    writeln!(f, "`define GLYPH_CELL_W {}", cell_w)?;
    writeln!(f, "`define GLYPH_CELL_H {}", cell_h)?;
    writeln!(f, "`define GLYPH_CELL_W_LOG2 {}", log2(cell_w))?;
    writeln!(f, "`define GLYPH_CELL_H_LOG2 {}", log2(cell_h))?;
    writeln!(f, "`define GLYPH_PAD_LEFT {}", pad_left)?;
    writeln!(f, "`define GLYPH_MAX_ASCENT {}", max_ascent)?;
    writeln!(f, "`define GLYPH_MAX_DESCENT {}", max_descent)?;
    writeln!(f, "`define GLYPH_FIRST_CHAR 8'h{:02X}", FIRST_CHAR)?;
    writeln!(f, "`define GLYPH_LAST_CHAR  8'h{:02X}", LAST_CHAR)?;
    writeln!(f, "`define GLYPH_NUM_CHARS  {}", NUM_CHARS)?;
    Ok(())
}

fn log2(mut n: u32) -> u32 {
    let mut r = 0;
    while n > 1 {
        n >>= 1;
        r += 1;
    }
    r
}
