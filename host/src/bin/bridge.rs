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
use vsf::schema::{pipe_message_schema, SectionBuilder};
use vsf::types::VsfType;
use vsf::verification::is_original;
use vsf::vsf_builder::VsfBuilder;

const DEFAULT_PORT: &str = "/dev/ttyACM0";

/// Global `--inspect` flag — set once during arg parsing, read by send_cmd to optionally pretty-print every request and response.
static INSPECT: AtomicBool = AtomicBool::new(false);

/// Global `--no-time` flag — when set, the host pretends to be a clockless device and omits `creation_time` from the cmd.
/// Useful for testing the bridge's honest-when-clockless behaviour.
static NO_TIME: AtomicBool = AtomicBool::new(false);

/// Global `--save <prefix>` — set once during arg parsing; if non-empty, send_cmd writes raw request to `{prefix}_req.vsf` and raw response to `{prefix}_resp.vsf`.
/// Useful for running `vsfinfo <path> verify` against the captured wire bytes.
static SAVE_PREFIX: std::sync::OnceLock<String> = std::sync::OnceLock::new();

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
        if args[i] == "--no-time" {
            NO_TIME.store(true, Ordering::Relaxed);
            args.remove(i);
            continue;
        }
        if args[i] == "--save" {
            if i + 1 >= args.len() {
                eprintln!("error: --save requires a prefix argument");
                return ExitCode::from(2);
            }
            let prefix = args.remove(i + 1);
            args.remove(i);
            let _ = SAVE_PREFIX.set(prefix);
            continue;
        }
        i += 1;
    }

    let cmd = match args.first() {
        Some(s) => s.clone(),
        None => {
            eprintln!(
                "usage: bridge [--port <path>] [--inspect] <ping|info|uptime|random [N]|wire_status|wire_trace [SAMPLES [PERIOD_NS]]|bootsel|reset|flash <uf2>>"
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
        "wire_status" => cmd_wire_status(&port_path),
        "wire_trace" => cmd_wire_trace(&port_path, cmd_args),
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

    let mut builder = VsfBuilder::new().version(7, 7).provenance_only();
    if !NO_TIME.load(Ordering::Relaxed) {
        builder = builder.creation_time_oscillations(now_eagle_oscillations());
    }
    builder.add_section("pipe_message", fields).build()
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

    if let Some(prefix) = SAVE_PREFIX.get() {
        let p = format!("{prefix}_req.vsf");
        std::fs::write(&p, &req).map_err(|e| format!("save {p}: {e}"))?;
        println!("(saved request → {p})");
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

    if !resp.is_empty() {
        if let Some(prefix) = SAVE_PREFIX.get() {
            let p = format!("{prefix}_resp.vsf");
            std::fs::write(&p, &resp).map_err(|e| format!("save {p}: {e}"))?;
            println!("(saved response → {p})");
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
        .find(|f| f.name == "pipe_message")
        .ok_or_else(|| "response missing 'pipe_message' section".to_string())?;
    let end = field.offset_bytes + field.size_bytes;
    if end > bytes.len() {
        return Err("section bounds out of range".into());
    }
    SectionBuilder::parse(pipe_message_schema(), &bytes[field.offset_bytes..end])
        .map_err(|e| format!("resp schema validation: {e}"))
}

/// Pull a `u64` from a resp field, returning `None` if absent or wrong type.
/// Uses VsfType::as_u64 so it accepts the full set of unsigned variants (u/u0/u3/u4/u5/u6).
fn resp_u64(resp: &SectionBuilder, name: &str) -> Option<u64> {
    resp.get(name).ok()?.first().and_then(|v| v.as_u64())
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

fn cmd_wire_status(port_path: &str) -> Result<(), String> {
    let (resp, _rtt) = send_cmd(port_path, "wire_status", 6, vec![])?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    let data = section
        .get("data")
        .map_err(|e| format!("missing data: {e}"))?
        .first()
        .and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()),
            _ => None,
        })
        .ok_or_else(|| "data field not a binary blob".to_string())?;
    if data.len() != 24 {
        return Err(format!("expected 24 bytes of stats, got {}", data.len()));
    }
    let u32_at = |i: usize| -> u32 {
        u32::from_le_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]])
    };
    let samples = u32_at(0);
    let high = u32_at(4);
    let low = u32_at(8);
    let zeros = u32_at(12);
    let ones = u32_at(16);
    let toggles = u32_at(20);
    let pct = |n: u32, d: u32| if d == 0 { 0.0 } else { 100.0 * n as f64 / d as f64 };
    println!("PIPE wire status:");
    println!("  samples:            {}", samples);
    println!("  high:               {} ({:.1}%)", high, pct(high, samples));
    println!("  low:                {} ({:.1}%)", low, pct(low, samples));
    println!("  toggles (sample→sample): {} ({:.1}% of intervals)",
             toggles, pct(toggles, samples.saturating_sub(1).max(1)));
    println!("  decoded zeros:      {} ({:.1}%)", zeros, pct(zeros, zeros + ones));
    println!("  decoded ones:       {} ({:.1}%)", ones, pct(ones, zeros + ones));
    println!();
    println!("Diagnosis:");
    if samples < 100 {
        println!("  Need more samples — wait longer between flash and wire_status.");
    } else if high < 10 || low < 10 {
        println!("  Wire is stuck (essentially all-high or all-low).");
        println!("  → FPGA not driving, wire not connected, or pull-down absent.");
    } else if toggles < samples / 4 {
        println!("  Wire has activity but not alternating reliably.");
        println!("  → check slot rate (20 µs/sample), FPGA might be running at different clk.");
    } else if pct(toggles, samples - 1) > 90.0 && zeros > 10 * ones {
        println!("  IDEAL: ~50% high, ~50% low, ~100% alternation, decode = all-zeros.");
        println!("  → FPGA enclave idle pattern detected, codec locked, mirror-XOR working.");
    } else if pct(toggles, samples - 1) > 90.0 && ones > 10 * zeros {
        println!("  Wire alternating but decoded as all-ones — phase off by one slot.");
        println!("  → flip my_slot initial state in pipe_wire_task and reflash.");
    } else {
        println!("  Partial activity, no clean pattern — slot rate off or wire noisy.");
    }
    Ok(())
}

/// Capture 256 consecutive raw GP0 samples and print the bit pattern.
/// Tells us instantly what's actually on the wire (idle 1010, stuck-HIGH, noisy, etc.)
/// without depending on the codec interpretation or slot phase guessing.
///
/// Payload format from firmware: [slot_us u32 LE][32 bytes packed bits, LSB-first per byte].
/// `wire_trace [SAMPLES [PERIOD_NS]]` — captures up to 8192 raw GP0 samples at
/// the bridge's native loop rate (~8-12 MS/s) or at a host-specified period.
/// Defaults: 8192 samples, native rate. Response carries the measured elapsed
/// wall time so we report the true sample rate the device actually achieved.
fn cmd_wire_trace(port_path: &str, args: &[String]) -> Result<(), String> {
    const TRACE_MAX_SAMPLES: u32 = 8192;
    let samples: u32 = args
        .first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SAMPLES: {e}")))
        .transpose()?
        .unwrap_or(TRACE_MAX_SAMPLES)
        .clamp(1, TRACE_MAX_SAMPLES);
    let period_ns: u32 = args
        .get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(0);

    let mut params = Vec::with_capacity(8);
    params.extend_from_slice(&samples.to_le_bytes());
    params.extend_from_slice(&period_ns.to_le_bytes());

    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_trace",
        7,
        vec![("data".to_string(), VsfType::v(b'b', params))],
    )?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    let data = section
        .get("data")
        .map_err(|e| format!("missing data: {e}"))?
        .first()
        .and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()),
            _ => None,
        })
        .ok_or_else(|| "data field not a binary blob".to_string())?;
    if data.len() < 8 {
        return Err(format!("trace response too short: {} bytes", data.len()));
    }
    let captured = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let elapsed_us = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as u64;
    let expected_bytes = (captured + 7) >> 3;
    if data.len() < 8 + expected_bytes {
        return Err(format!(
            "trace truncated: header says {captured} samples ({expected_bytes} bytes) but blob has only {} bytes after the 8-byte header",
            data.len() - 8
        ));
    }
    let bits = &data[8..8 + expected_bytes];
    let samples_vec: Vec<u8> = (0..captured)
        .map(|i| (bits[i >> 3] >> (i & 7)) & 1)
        .collect();
    let high = samples_vec.iter().filter(|&&b| b == 1).count();
    let low = captured - high;
    let toggles = samples_vec.windows(2).filter(|w| w[0] != w[1]).count();
    let total_ms = elapsed_us as f64 / 1000.0;
    let rate_mhz = if elapsed_us > 0 {
        captured as f64 / elapsed_us as f64
    } else {
        0.0
    };
    let avg_period_ns = if captured > 0 {
        (elapsed_us as f64 * 1000.0) / captured as f64
    } else {
        0.0
    };

    println!(
        "PIPE wire trace ({} samples, {:.3} ms wall time, {:.3} MS/s, {:.1} ns/sample):",
        captured, total_ms, rate_mhz, avg_period_ns
    );
    if period_ns == 0 {
        println!("  mode: native loop rate");
    } else {
        println!("  mode: requested {} ns period", period_ns);
    }
    println!(
        "  high: {} ({:.1}%)   low: {} ({:.1}%)   toggles: {}",
        high,
        100.0 * high as f64 / captured.max(1) as f64,
        low,
        100.0 * low as f64 / captured.max(1) as f64,
        toggles,
    );
    if toggles > 0 {
        let avg_interval_ns = (captured as f64 - 1.0) / toggles as f64 * avg_period_ns;
        let est_freq_hz = if avg_interval_ns > 0.0 {
            1_000_000_000.0 / (2.0 * avg_interval_ns)
        } else {
            0.0
        };
        println!(
            "  avg gap between toggles: {:.1} ns → estimated signal freq: {:.0} Hz",
            avg_interval_ns, est_freq_hz
        );
    }
    println!();

    // Hex dump — 16 bytes per row (= 128 samples per row), LSB-first within each
    // byte so byte order on the page matches time order. Each row labels its
    // µs-from-start offset using the *measured* per-sample period.
    let bytes_per_row: usize = 16;
    println!(
        "  offset(µs)    hex (16 bytes = {} samples per row)",
        bytes_per_row * 8
    );
    let mut byte_idx = 0;
    while byte_idx < bits.len() {
        let row_end = (byte_idx + bytes_per_row).min(bits.len());
        let row_start_us = ((byte_idx * 8) as f64 * avg_period_ns / 1000.0) as usize;
        let mut line = String::with_capacity(48);
        for (i, b) in bits[byte_idx..row_end].iter().enumerate() {
            if i > 0 && i % 4 == 0 {
                line.push(' ');
            }
            line.push_str(&format!("{:02X}", b));
        }
        println!("  {:>6}        {}", row_start_us, line);
        byte_idx += bytes_per_row;
    }
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
