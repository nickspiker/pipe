//! bridge_ping — send a VSF "ping" command to the RP2040 bridge over USB-CDC, print the response.
//!
//! Usage:
//!     cargo run --bin bridge_ping            # uses /dev/ttyACM0
//!     cargo run --bin bridge_ping /dev/ttyACM1
//!
//! Wire format (matches firmware's handle_frames in pipe-bridge-rp2040):
//!     request:  [d"cmd"(d"op":l"ping")(d"id":u<n>)]
//!     response: [d"resp"(d"id":u<n>)(d"op":l"pong")]
//!
//! Build the request with vsf-mini's writer, parse the response with vsf-mini's reader. Same crate both sides → wire format is identical.

use std::io::{Read, Write};
use std::time::{Duration, Instant};

use vsf_mini::{VsfReader, VsfWriter};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port_path = std::env::args().nth(1).unwrap_or_else(|| "/dev/ttyACM0".to_string());

    println!("opening {port_path}");
    let mut port = serialport::new(&port_path, 115_200) // baud ignored over CDC
        .timeout(Duration::from_millis(500))
        .open()?;

    // Build the request: [d"cmd"(d"op":l"ping")(d"id":u3 42)]
    let mut req = [0u8; 64];
    let req_len = {
        let mut w = VsfWriter::new(&mut req);
        let ok = w.section_open("cmd")
            && w.field_open("op")
            && w.label("ping")
            && w.field_close()
            && w.field_open("id")
            && w.uint(42)
            && w.field_close()
            && w.section_close();
        if !ok {
            return Err("encode failed".into());
        }
        w.pos()
    };

    println!("→ {} bytes: {:02x?}", req_len, &req[..req_len]);

    let t0 = Instant::now();
    port.write_all(&req[..req_len])?;

    // Read response
    let mut resp = [0u8; 64];
    let mut total = 0usize;
    loop {
        match port.read(&mut resp[total..]) {
            Ok(0) => break,
            Ok(n) => {
                total += n;
                // Crude end-of-frame detect: closing ']' of outer section
                if total > 0 && resp[total - 1] == b']' {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            Err(e) => return Err(e.into()),
        }
    }
    let rtt = t0.elapsed();

    if total == 0 {
        println!("no response (timeout)");
        return Ok(());
    }

    println!("← {} bytes ({:?}): {:02x?}", total, rtt, &resp[..total]);

    // Parse response
    let mut r = VsfReader::new(&resp[..total]);
    if r.read_byte_raw() != Some(b'[') {
        println!("malformed: expected '['");
        return Ok(());
    }
    let name = r.dict_key_str().ok_or("missing section name")?;
    println!("  section: {name}");

    while let Some(tag) = r.peek_tag() {
        match tag {
            b'(' => {
                r.read_byte_raw();
                let field = r.dict_key_str().ok_or("missing field name")?;
                if r.read_byte_raw() != Some(b':') {
                    return Err("missing ':'".into());
                }
                match r.peek_tag() {
                    Some(b'u') => {
                        let v = r.uint().ok_or("bad uint")?;
                        println!("  {field}: u{v}");
                    }
                    Some(b'l') => {
                        let bytes = r.label().ok_or("bad label")?;
                        let s = std::str::from_utf8(bytes).unwrap_or("<non-utf8>");
                        println!("  {field}: l\"{s}\"");
                    }
                    other => {
                        println!("  {field}: <skip tag {:?}>", other.map(|b| b as char));
                        r.skip_field();
                    }
                }
                if r.read_byte_raw() != Some(b')') {
                    return Err("missing ')'".into());
                }
            }
            b']' => {
                r.read_byte_raw();
                break;
            }
            _ => return Err(format!("unexpected tag {:?}", tag as char).into()),
        }
    }

    Ok(())
}
