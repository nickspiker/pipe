//! bridge — host-side CLI for the RP2040-Zero USB-to-PIPE-wire bridge.
//!
//! Wire protocol: complete VSF documents over USB-CDC.
//! Both sides use the unified `vsf` crate so encode/decode shapes match by construction.
//! Each cmd carries the host's current Eagle Time (via `nunc-time` → eu6 oscillation count) in the document header's `creation_time` field; the bridge uses the first such timestamp to anchor its monotonic clock for `resp` headers.
//!
//! Usage:
//!     bridge [--port /dev/ttyACM0] [--inspect] <subcommand> [args...]
//!
//! Subcommands:
//!     ping              round-trip "ping" → "pong"
//!     info              dump device identity + clock + uptime
//!     uptime            milliseconds since boot
//!     random [N]        N bytes of BLAKE3-conditioned ROSC entropy (1-32, default 32)
//!     bootsel           drop the bridge into UF2 mass-storage bootloader
//!     reset             soft-reset the bridge
//!     flash <uf2>       full upgrade loop: bootsel → wait mount → cp → wait boot
//!
//! Default port: /dev/ttyACM0.
//! `--inspect` dumps request + response as coloured VSF via `vsf::inspect::inspect_vsf`.

use std::io::{Read, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use vsf::file_format::VsfHeader;
use vsf::schema::{bridge_cmd_schema, bridge_resp_schema, SectionBuilder};
use vsf::types::VsfType;
use vsf::verification::is_original;
use vsf::vsf_builder::VsfBuilder;

const DEFAULT_PORT: &str = "/dev/ttyACM0";

/// Global `--inspect` flag — set once during arg parsing, read by send_cmd to optionally pretty-print every request and response.
static INSPECT: AtomicBool = AtomicBool::new(false);

fn main() -> ExitCode {
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
        if args[i] == "--inspect" {
            INSPECT.store(true, Ordering::Relaxed);
            args.remove(i);
            continue;
        }
        i += 1;
    }

    let cmd = match args.first() {
        Some(s) => s.clone(),
        None => {
            eprintln!(
                "usage: bridge [--port <path>] [--inspect] <ping|info|uptime|random [N]|bootsel|reset|flash <uf2>>"
            );
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
        "flash" => cmd_flash(&port_path, cmd_args),
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

/// Current Eagle Time as a 64-bit oscillation count (eu6), sourced from the host's wall clock via nunc-time's local conversion.
/// The bridge firmware anchors its own clock on the first cmd's creation_time, so monotonicity within a session comes from the firmware-side `next_eagle_time` bump.
fn now_eagle_oscillations() -> i64 {
    nunc::eagle::from_system_time(SystemTime::now())
}

/// Build a complete VSF document containing a single `cmd` section with the given fields, hp-stamped via VsfBuilder.provenance_only().
fn build_cmd_doc(
    op: &str,
    id: u64,
    extras: Vec<(String, VsfType)>,
) -> Result<Vec<u8>, String> {
    let mut fields = Vec::with_capacity(2 + extras.len());
    fields.push(("op".to_string(), VsfType::a(op.to_string())));
    fields.push(("id".to_string(), VsfType::u(id as usize, false)));
    fields.extend(extras);

    VsfBuilder::new()
        .version(7, 7)
        .creation_time_oscillations(now_eagle_oscillations())
        .provenance_only()
        .add_section("cmd", fields)
        .build()
}

/// Send a cmd packet, read the response bytes (closes on `]`), return `(response_bytes, round_trip_time)`.
/// Action commands that send no response surface as TimedOut/BrokenPipe → empty Vec.
fn send_cmd(
    port_path: &str,
    op: &str,
    id: u64,
    extras: Vec<(String, VsfType)>,
) -> Result<(Vec<u8>, Duration), String> {
    let mut port = open_port(port_path)?;
    let req = build_cmd_doc(op, id, extras)?;

    if INSPECT.load(Ordering::Relaxed) {
        println!("─── request ({} bytes) ───", req.len());
        match vsf::inspect::inspect_vsf(&req) {
            Ok(s) => println!("{s}"),
            Err(e) => println!("(inspect failed: {e})\n{:02x?}", &req[..]),
        }
    }

    let t0 = Instant::now();
    port.write_all(&req).map_err(|e| format!("write: {e}"))?;

    let mut resp = Vec::with_capacity(256);
    let mut chunk = [0u8; 128];
    loop {
        match port.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                resp.extend_from_slice(&chunk[..n]);
                // A complete VSF document ends with `]` (the closing of the single section body).
                if resp.last() == Some(&b']') {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => break,
            Err(e) => return Err(format!("read: {e}")),
        }
    }
    let elapsed = t0.elapsed();

    if INSPECT.load(Ordering::Relaxed) {
        if resp.is_empty() {
            println!("─── response (0 bytes, device disconnected) ───");
        } else {
            println!("─── response ({} bytes, {:.2?}) ───", resp.len(), elapsed);
            match vsf::inspect::inspect_vsf(&resp) {
                Ok(s) => println!("{s}"),
                Err(e) => println!("(inspect failed: {e})\n{:02x?}", &resp[..]),
            }
        }
    }

    Ok((resp, elapsed))
}

/// Verify hp on a complete response document and return the schema-validated `resp` section.
fn parse_resp(bytes: &[u8]) -> Result<SectionBuilder, String> {
    is_original(bytes).map_err(|e| format!("hp mismatch: {e}"))?;
    let (header, _) = VsfHeader::decode(bytes).map_err(|e| format!("header decode: {e}"))?;
    let field = header
        .fields
        .iter()
        .find(|f| f.name == "resp")
        .ok_or_else(|| "response missing 'resp' section".to_string())?;
    let end = field.offset_bytes + field.size_bytes;
    if end > bytes.len() {
        return Err("section bounds out of range".into());
    }
    SectionBuilder::parse(bridge_resp_schema(), &bytes[field.offset_bytes..end])
        .map_err(|e| format!("resp schema validation: {e}"))
}

/// Pull a `u64` from a resp field, returning `None` if absent or wrong type.
fn resp_u64(resp: &SectionBuilder, name: &str) -> Option<u64> {
    resp.get(name).ok()?.first().and_then(|v| match v {
        VsfType::u(n, _) => Some(*n as u64),
        _ => None,
    })
}

/// Pull an `&str` from a resp ASCII field, returning `None` if absent or wrong type.
fn resp_ascii<'a>(resp: &'a SectionBuilder, name: &str) -> Option<&'a str> {
    resp.get(name).ok()?.first().and_then(|v| match v {
        VsfType::a(s) => Some(s.as_str()),
        _ => None,
    })
}

// ---------- subcommands -----------------------------------------------------

fn cmd_ping(port_path: &str) -> Result<(), String> {
    let (resp, rtt) = send_cmd(port_path, "ping", 1, vec![])?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    if resp_ascii(&section, "op") != Some("pong") {
        return Err("response did not contain op:pong".into());
    }
    println!("pong ({:.2?}, {} bytes)", rtt, resp.len());
    Ok(())
}

fn cmd_info(port_path: &str) -> Result<(), String> {
    let (resp, rtt) = send_cmd(port_path, "info", 2, vec![])?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    if let Some(name) = resp_ascii(&section, "name") {
        println!("name: {name}");
    }
    if let Some(ver) = resp_u64(&section, "ver") {
        println!("ver:  {ver}");
    }
    if let Some(values) = section.get("did").ok() {
        if let Some(VsfType::hp(bytes)) = values.first() {
            print!("did:  ");
            for b in bytes.iter() {
                print!("{:02X}", b);
            }
            println!();
        }
    }
    if let Some(hz) = resp_u64(&section, "clk") {
        println!("clk:  {} Hz ({:.2} MHz)", hz, hz as f64 / 1.0e6);
    }
    if let Some(up) = resp_u64(&section, "up") {
        println!("up:   {} ms", up);
    }
    println!("({:.2?})", rtt);
    Ok(())
}

fn cmd_uptime(port_path: &str) -> Result<(), String> {
    let (resp, _rtt) = send_cmd(port_path, "uptime", 3, vec![])?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    let ms = resp_u64(&section, "ms").ok_or("response missing 'ms' field")?;
    println!("{} ms", ms);
    Ok(())
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
    let extras = vec![("n".to_string(), VsfType::u(n as usize, false))];
    let (resp, _rtt) = send_cmd(port_path, "random", 4, extras)?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    let data = section
        .get("data")
        .map_err(|e| format!("missing data: {e}"))?
        .first()
        .and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes),
            _ => None,
        })
        .ok_or_else(|| "data field not a binary blob".to_string())?;
    for b in data {
        print!("{:02X}", b);
    }
    println!();
    Ok(())
}

/// Wait for a path to (dis)appear by polling with a short interval.
fn wait_for<P, F>(deadline: Instant, mut check: F, descr: &str) -> Result<P, String>
where
    F: FnMut() -> Option<P>,
{
    while Instant::now() < deadline {
        if let Some(v) = check() {
            return Ok(v);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err(format!("timed out waiting for {descr}"))
}

/// Full upgrade loop. Triggers bootsel, waits for the RPI-RP2 mount, copies the UF2, waits for the bridge to re-enumerate as CDC, verifies with a ping.
fn cmd_flash(port_path: &str, args: &[String]) -> Result<(), String> {
    let uf2_path = args.first().ok_or("usage: bridge flash <path/to/uf2>")?;
    let uf2_path = std::path::Path::new(uf2_path);
    if !uf2_path.exists() {
        return Err(format!("UF2 not found: {}", uf2_path.display()));
    }

    println!("→ requesting bootsel");
    cmd_action(port_path, "bootsel")?;

    let user = std::env::var("USER").unwrap_or_else(|_| "nick".to_string());
    let media_dir = std::path::PathBuf::from(format!("/run/media/{user}/RPI-RP2"));
    print!("→ waiting for RPI-RP2 mount at {} ", media_dir.display());
    let _ = std::io::stdout().flush();
    let mount = wait_for(
        Instant::now() + Duration::from_secs(15),
        || {
            if media_dir.is_dir() {
                Some(media_dir.clone())
            } else {
                None
            }
        },
        "RPI-RP2 mount",
    )?;
    println!("(found)");

    let dst = mount.join(uf2_path.file_name().unwrap_or_default());
    print!("→ copying {} → {} ", uf2_path.display(), dst.display());
    let _ = std::io::stdout().flush();
    std::fs::copy(uf2_path, &dst).map_err(|e| format!("\ncp failed: {e}"))?;
    nix_sync();
    println!("(done)");

    let port_pb = std::path::PathBuf::from(port_path);
    print!("→ waiting for {} to re-enumerate ", port_pb.display());
    let _ = std::io::stdout().flush();
    wait_for(
        Instant::now() + Duration::from_secs(15),
        || if port_pb.exists() { Some(()) } else { None },
        "serial device",
    )?;
    println!("(found)");

    println!("→ verifying with ping");
    std::thread::sleep(Duration::from_millis(500));
    cmd_ping(port_path)?;
    println!("flash: success");
    Ok(())
}

/// Best-effort fsync of all dirty buffers — equivalent to `sync(1)`.
/// The RP2 bootloader needs every byte landed before it'll boot.
fn nix_sync() {
    extern "C" {
        fn sync();
    }
    unsafe { sync() };
}

/// `bootsel`/`reset` send no response — bridge disconnects from the bus.
/// We expect the read to time out with zero bytes; that's success.
/// If the device DID reply, it's likely an `unknown_op` error from older firmware — surface it.
fn cmd_action(port_path: &str, op: &str) -> Result<(), String> {
    let (resp, _rtt) = send_cmd(port_path, op, 5, vec![])?;
    if !resp.is_empty() {
        let section = parse_resp(&resp)?;
        if let Some(err) = resp_ascii(&section, "err") {
            return Err(format!("device returned err: {err}"));
        }
    }
    println!("{op}: sent (device disconnected)");
    Ok(())
}
