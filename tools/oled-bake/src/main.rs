//! Rasterise a few lines of text (variable-width, anti-aliased) into a 128×64 8bpp framebuffer and emit a $readmemh-compatible dump for the OLED top.
//!
//! CLI: `oled-bake <font.ttf> <px_size> <output.mem> [line1] [line2] ...`
//!
//! The framebuffer is 8192 bytes (128 cols × 64 rows, row-major). Each byte is the greyscale alpha from the font rasterizer (0 = black, 255 = full intensity). The FPGA dithers it against TRNG and pumps it to the SSD1306.

use fontdue::layout::{CoordinateSystem, Layout, LayoutSettings, TextStyle};
use fontdue::{Font, FontSettings};
use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;

const W: usize = 128;
const H: usize = 64;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: oled-bake <font.ttf> <px_size> <out.mem> [line1] [line2] ...");
        std::process::exit(2);
    }
    let font_path = &args[1];
    let px: f32 = args[2].parse()?;
    let out_path = &args[3];
    let lines: Vec<&str> = if args.len() > 4 {
        args[4..].iter().map(|s| s.as_str()).collect()
    } else {
        vec!["PIPE"]
    };

    // LINE_GAP: extra pixels of empty space between consecutive lines on top of fontdue's measured glyph-run height. Default 2. LINE_HEIGHT: if set, override the per-line vertical advance entirely (uniform grid regardless of glyph extents). Y_START: vertical offset of the first baseline-ish position from row 0.
    let line_gap: f32 = env::var("LINE_GAP")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.0);
    let line_height_override: Option<f32> =
        env::var("LINE_HEIGHT").ok().and_then(|s| s.parse().ok());
    let y_start: f32 = env::var("Y_START")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.0);

    let font_data = fs::read(font_path)?;
    let font = Font::from_bytes(font_data, FontSettings::default())
        .map_err(|e| format!("font load: {e}"))?;
    let fonts = [&font];

    let mut fb = vec![0u8; W * H];

    let mut y_cursor: f32 = y_start;
    for line in &lines {
        let mut layout = Layout::new(CoordinateSystem::PositiveYDown);
        layout.reset(&LayoutSettings {
            x: 0.0,
            y: y_cursor,
            ..LayoutSettings::default()
        });
        layout.append(&fonts, &TextStyle::new(line, px, 0));

        let line_height = layout.height();

        for g in layout.glyphs() {
            let (metrics, bitmap) = font.rasterize_indexed(g.key.glyph_index, g.key.px);
            let gw = metrics.width;
            let gh = metrics.height;
            let x0 = g.x.round() as i32;
            let y0 = g.y.round() as i32;
            for j in 0..gh {
                let dy = y0 + j as i32;
                if dy < 0 || dy >= H as i32 {
                    continue;
                }
                for i in 0..gw {
                    let dx = x0 + i as i32;
                    if dx < 0 || dx >= W as i32 {
                        continue;
                    }
                    let src = bitmap[j * gw + i];
                    let idx = (dy as usize) * W + (dx as usize);
                    // Max-blend so overlapping glyphs (italic descenders etc.) don't punch holes.
                    if src > fb[idx] {
                        fb[idx] = src;
                    }
                }
            }
        }

        let advance = line_height_override.unwrap_or(line_height) + line_gap;
        y_cursor += advance;
        if y_cursor >= H as f32 {
            break;
        }
    }

    write_memh(&fb, Path::new(out_path))?;
    eprintln!(
        "oled-bake: wrote {} bytes ({}×{}) to {}",
        fb.len(),
        W,
        H,
        out_path
    );
    Ok(())
}

fn write_memh(fb: &[u8], path: &Path) -> std::io::Result<()> {
    let mut f = fs::File::create(path)?;
    for chunk in fb.chunks(16) {
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
