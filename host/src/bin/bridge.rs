//! bridge — host-side CLI for the RP2040-Zero USB-to-PIPE-wire bridge.
//!
//! Wire protocol is VSF over USB-CDC; same vsf-mini crate runs on both sides,
//! so encode/decode is identical by construction.
//!
//! Usage:
//!     bridge [--port /dev/ttyACM0] <subcommand> [args...]
//!
//! Subcommands:
//!     ping              round-trip "ping" → "pong"
//!     info              dump device identity + clock + uptime
//!     uptime            milliseconds since boot
//!     random [N]        N bytes of BLAKE3-conditioned ROSC entropy (1-32, default 32)
//!     bootsel           drop the bridge into UF2 mass-storage bootloader
//!     reset             soft-reset the bridge
//!
//! Default port: /dev/ttyACM0. Override with `--port <path>` anywhere on the line.

use std::io::{Read, Write};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use vsf_mini::{VsfReader, VsfWriter};

const DEFAULT_PORT: &str = "/dev/ttyACM0";

fn main() -> ExitCode {
    // Strip `--port <path>` from anywhere in argv; collect the remaining positional args.
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    let mut port_path = DEFAULT_PORT.to_string();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--port" {
            if i + 1 >= args.len() {
                eprintln!("error: --port requires an argument");
                return ExitCode::from(2);
            }
            port_path = args.remove(i + 1);
            args.remove(i);
            continue;
        }
        i += 1;
    }

    let cmd = match args.first() {
        Some(s) => s.clone(),
        None => {
            eprintln!("usage: bridge [--port <path>] <ping|info|uptime|random [N]|bootsel|reset>");
            return ExitCode::from(2);
        }
    };
    let cmd_args: &[String] = if args.len() > 1 { &args[1..] } else { &[] };

    let result = match cmd.as_str() {
        "ping" => cmd_ping(&port_path),
        "info" => cmd_info(&port_path),
        "uptime" => cmd_uptime(&port_path),
        "random" => cmd_random(&port_path, cmd_args),
        "bootsel" => cmd_action(&port_path, "bootsel"),
        "reset" => cmd_action(&port_path, "reset"),
        other => {
            eprintln!("error: unknown subcommand '{other}'");
            return ExitCode::from(2);
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

// ---------- helpers ---------------------------------------------------------

type Port = Box<dyn serialport::SerialPort>;

fn open_port(path: &str) -> Result<Port, String> {
    serialport::new(path, 115_200)
        .timeout(Duration::from_millis(500))
        .open()
        .map_err(|e| format!("opening {path}: {e}"))
}

/// Encode and send a command frame; read response bytes (closes on `]`).
/// Returns `(response_bytes, round_trip_time)`. For action commands that send
/// no response, expect a TimedOut → empty Vec.
fn send_cmd<F>(port_path: &str, build: F) -> Result<(Vec<u8>, Duration), String>
where
    F: FnOnce(&mut VsfWriter) -> bool,
{
    let mut port = open_port(port_path)?;
    let mut req = [0u8; 128];
    let req_len = {
        let mut w = VsfWriter::new(&mut req);
        if !build(&mut w) {
            return Err("encode failed".into());
        }
        w.pos()
    };

    let t0 = Instant::now();
    port.write_all(&req[..req_len])
        .map_err(|e| format!("write: {e}"))?;

    let mut resp = Vec::with_capacity(128);
    let mut chunk = [0u8; 128];
    loop {
        match port.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                resp.extend_from_slice(&chunk[..n]);
                if resp.last() == Some(&b']') {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            // BrokenPipe means the bridge yanked itself off the bus (bootsel/reset).
            // Treat it like a clean EOF — caller decides if that's success or failure.
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => break,
            Err(e) => return Err(format!("read: {e}")),
        }
    }
    Ok((resp, t0.elapsed()))
}

/// Build the canonical `[d"cmd"(d"op":l"<op>")(d"id":u<id>)...extras]` request.
fn build_cmd<F>(w: &mut VsfWriter, op: &str, id: u64, extras: F) -> bool
where
    F: FnOnce(&mut VsfWriter) -> bool,
{
    w.section_open("cmd")
        && w.field_open("op")
        && w.label(op)
        && w.field_close()
        && w.field_open("id")
        && w.uint(id)
        && w.field_close()
        && extras(w)
        && w.section_close()
}

/// Open and walk a "resp" section, calling `visit` for each `(d"name":<value>)`
/// field. `visit` is called with the field name and a reader positioned at the
/// value tag; it must consume the value and return true.
fn parse_resp<F>(bytes: &[u8], mut visit: F) -> Result<(), String>
where
    F: FnMut(&str, &mut VsfReader) -> Result<(), String>,
{
    let mut r = VsfReader::new(bytes);
    if r.read_byte_raw() != Some(b'[') {
        return Err("missing '['".into());
    }
    let name = r.dict_key_str().ok_or("missing section name")?;
    if name != "resp" {
        return Err(format!("expected 'resp' section, got '{name}'"));
    }
    while let Some(tag) = r.peek_tag() {
        match tag {
            b'(' => {
                r.read_byte_raw();
                let field = r
                    .dict_key_str()
                    .ok_or("missing field name")?
                    .to_string();
                if r.read_byte_raw() != Some(b':') {
                    return Err("missing ':'".into());
                }
                visit(&field, &mut r)?;
                if r.read_byte_raw() != Some(b')') {
                    return Err("missing ')'".into());
                }
            }
            b']' => {
                r.read_byte_raw();
                break;
            }
            _ => return Err(format!("unexpected tag {:?}", tag as char)),
        }
    }
    Ok(())
}

// ---------- subcommands -----------------------------------------------------

fn cmd_ping(port_path: &str) -> Result<(), String> {
    let (resp, rtt) = send_cmd(port_path, |w| build_cmd(w, "ping", 1, |_| true))?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let mut got_pong = false;
    parse_resp(&resp, |name, r| match name {
        "id" => {
            r.uint();
            Ok(())
        }
        "op" => {
            let bytes = r.label().ok_or("bad label")?;
            if bytes == b"pong" {
                got_pong = true;
            }
            Ok(())
        }
        _ => {
            r.skip_field();
            Ok(())
        }
    })?;
    if !got_pong {
        return Err("response did not contain op:pong".into());
    }
    println!("pong ({:.2?}, {} bytes)", rtt, resp.len());
    Ok(())
}

fn cmd_info(port_path: &str) -> Result<(), String> {
    let (resp, rtt) = send_cmd(port_path, |w| build_cmd(w, "info", 2, |_| true))?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    parse_resp(&resp, |name, r| {
        match name {
            "id" => {
                r.uint();
            }
            "name" => {
                let s = std::str::from_utf8(r.label().ok_or("bad name")?)
                    .map_err(|e| format!("name utf-8: {e}"))?;
                println!("name: {s}");
            }
            "ver" => {
                let v = r.uint().ok_or("bad ver")?;
                println!("ver:  {v}");
            }
            "did" => {
                let h = r.hash_p().ok_or("bad did")?;
                print!("did:  ");
                for b in h.iter() {
                    print!("{:02X}", b);
                }
                println!();
            }
            "clk" => {
                let hz = r.uint().ok_or("bad clk")?;
                println!("clk:  {} Hz ({:.2} MHz)", hz, hz as f64 / 1.0e6);
            }
            "up" => {
                let ms = r.uint().ok_or("bad up")?;
                println!("up:   {} ms", ms);
            }
            other => {
                println!("(skipping unknown field '{other}')");
                r.skip_field();
            }
        }
        Ok(())
    })?;
    println!("({:.2?})", rtt);
    Ok(())
}

fn cmd_uptime(port_path: &str) -> Result<(), String> {
    let (resp, _rtt) = send_cmd(port_path, |w| build_cmd(w, "uptime", 3, |_| true))?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    parse_resp(&resp, |name, r| {
        match name {
            "id" => {
                r.uint();
            }
            "ms" => {
                let ms = r.uint().ok_or("bad ms")?;
                println!("{} ms", ms);
            }
            _ => {
                r.skip_field();
            }
        }
        Ok(())
    })
}

fn cmd_random(port_path: &str, args: &[String]) -> Result<(), String> {
    let n: u64 = if args.is_empty() {
        32
    } else {
        args[0]
            .parse()
            .map_err(|e| format!("random N: parse error: {e}"))?
    };
    if !(1..=32).contains(&n) {
        return Err(format!("random N must be 1-32, got {n}"));
    }
    let (resp, _rtt) = send_cmd(port_path, |w| {
        build_cmd(w, "random", 4, |w| {
            w.field_open("n") && w.uint(n) && w.field_close()
        })
    })?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    parse_resp(&resp, |name, r| {
        match name {
            "id" => {
                r.uint();
            }
            "data" => {
                let bytes = r.blob().ok_or("bad data")?;
                for b in bytes {
                    print!("{:02X}", b);
                }
                println!();
            }
            _ => {
                r.skip_field();
            }
        }
        Ok(())
    })
}

/// `bootsel`/`reset` send no response — bridge disconnects from the bus.
/// We expect the read to time out with zero bytes; that's success.
fn cmd_action(port_path: &str, op: &str) -> Result<(), String> {
    let (resp, _rtt) = send_cmd(port_path, |w| build_cmd(w, op, 5, |_| true))?;
    if !resp.is_empty() {
        // If the device DID reply, it's likely an "unknown_op" error from older firmware.
        parse_resp(&resp, |name, r| {
            match name {
                "id" => {
                    r.uint();
                }
                "err" => {
                    let msg = r.label().ok_or("bad err")?;
                    return Err(format!(
                        "device returned err: {}",
                        std::str::from_utf8(msg).unwrap_or("<non-utf8>")
                    ));
                }
                _ => {
                    r.skip_field();
                }
            }
            Ok(())
        })?;
    }
    println!("{op}: sent (device disconnected)");
    Ok(())
}
