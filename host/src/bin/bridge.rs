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
                "usage: bridge [--port <path>] [--inspect] <ping|info|uptime|random [N]|wire_trace [SAMPLES [PERIOD_NS]]|wire_stats [SAMPLES]|wire_sync [MAX_ITER]|bootsel|reset|flash <uf2>>"
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
        "wire_trace" => cmd_wire_trace(&port_path, cmd_args),
        "wire_stats" => cmd_wire_stats(&port_path, cmd_args),
        "wire_sync" => cmd_wire_sync(&port_path, cmd_args),
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

/// Capture raw GP0 samples and print the bit pattern. Tells us what's actually on the wire (idle 1010, stuck-HIGH, noisy, etc.) without depending on codec interpretation or slot phase guessing.
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

/// `wire_stats [SAMPLES]` — runs a tight bit-bang at the bridge's native loop rate over the requested sample budget, then reports duty cycle, average frequency, and per-state pulse-width stats (mean ± stddev, min, max). No buffer is held on the device — sample count caps wall-clock time only.
fn cmd_wire_stats(port_path: &str, args: &[String]) -> Result<(), String> {
    const STATS_MAX_SAMPLES: u32 = 1 << 22;
    let samples: u32 = args
        .first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SAMPLES: {e}")))
        .transpose()?
        .unwrap_or(1 << 20)
        .clamp(2, STATS_MAX_SAMPLES);

    let mut params = Vec::with_capacity(4);
    params.extend_from_slice(&samples.to_le_bytes());

    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_stats",
        10,
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
    // Firmware layout (LE), 200 bytes total: u32 elapsed_us, u32 samples_taken, u32 final_state, u32 final_run, u32 hi_count, u32 hi_min, u32 hi_max, u64 hi_sum, u64 hi_sumsq, u32 lo_count, u32 lo_min, u32 lo_max, u64 lo_sum, u64 lo_sumsq, 16 × u32 hi_hist, 16 × u32 lo_hist.
    const HIST_BINS: usize = 16;
    const SCALAR_BYTES: usize = 72;
    const HIST_BYTES: usize = HIST_BINS * 4;
    if data.len() < SCALAR_BYTES + 2 * HIST_BYTES {
        return Err(format!(
            "stats response too short: {} bytes (want {})",
            data.len(),
            SCALAR_BYTES + 2 * HIST_BYTES
        ));
    }
    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let g64 = |off: usize| u64::from_le_bytes([
        data[off], data[off+1], data[off+2], data[off+3],
        data[off+4], data[off+5], data[off+6], data[off+7],
    ]);
    let elapsed_us = g32(0) as u64;
    let samples_taken = g32(4) as u64;
    let final_state = g32(8);
    let final_run = g32(12) as u64;
    let hi_count = g32(16) as u64;
    let hi_min = g32(20) as u64;
    let hi_max = g32(24) as u64;
    let hi_sum = g64(28);
    let hi_sumsq = g64(36);
    let lo_count = g32(44) as u64;
    let lo_min = g32(48) as u64;
    let lo_max = g32(52) as u64;
    let lo_sum = g64(56);
    let lo_sumsq = g64(64);
    let hi_hist: Vec<u32> = (0..HIST_BINS)
        .map(|i| g32(SCALAR_BYTES + i * 4))
        .collect();
    let lo_hist: Vec<u32> = (0..HIST_BINS)
        .map(|i| g32(SCALAR_BYTES + HIST_BYTES + i * 4))
        .collect();

    let ns_per_sample = if samples_taken > 0 {
        (elapsed_us as f64 * 1000.0) / samples_taken as f64
    } else {
        0.0
    };
    let rate_mhz = if elapsed_us > 0 {
        samples_taken as f64 / elapsed_us as f64
    } else {
        0.0
    };

    // Duty cycle includes the final (unclosed) run so the total sample count matches samples_taken exactly. Run-length stats below exclude it (partial-run bias toward shorter values).
    let total_hi_samples = hi_sum + if final_state == 1 { final_run } else { 0 };
    let total_lo_samples = lo_sum + if final_state == 0 { final_run } else { 0 };
    let total = (total_hi_samples + total_lo_samples).max(1);
    let duty_hi = 100.0 * total_hi_samples as f64 / total as f64;
    let duty_lo = 100.0 * total_lo_samples as f64 / total as f64;

    // Average signal frequency: each full cycle has one closed HIGH run AND one closed LOW run, so we take the min — that's the count of complete cycles inside our window. Divide by elapsed seconds.
    let full_cycles = hi_count.min(lo_count);
    let elapsed_s = elapsed_us as f64 / 1_000_000.0;
    let avg_freq_hz = if elapsed_s > 0.0 {
        full_cycles as f64 / elapsed_s
    } else {
        0.0
    };

    let stats = |count: u64, sum: u64, sumsq: u64, min: u64, max: u64| -> (f64, f64, f64, f64) {
        if count == 0 {
            return (0.0, 0.0, 0.0, 0.0);
        }
        let n = count as f64;
        let mean = sum as f64 / n;
        // Population variance: E[X²] − (E[X])². Clamp tiny negatives from float roundoff before sqrt.
        let var = (sumsq as f64 / n - mean * mean).max(0.0);
        let stddev = var.sqrt();
        (mean * ns_per_sample, stddev * ns_per_sample,
         min as f64 * ns_per_sample, max as f64 * ns_per_sample)
    };
    let (hi_mean_ns, hi_std_ns, hi_min_ns, hi_max_ns) =
        stats(hi_count, hi_sum, hi_sumsq, hi_min, hi_max);
    let (lo_mean_ns, lo_std_ns, lo_min_ns, lo_max_ns) =
        stats(lo_count, lo_sum, lo_sumsq, lo_min, lo_max);

    let fmt_ns = |ns: f64| -> String {
        if ns >= 1_000_000.0 {
            format!("{:.3} ms", ns / 1_000_000.0)
        } else if ns >= 1_000.0 {
            format!("{:.3} µs", ns / 1_000.0)
        } else {
            format!("{:.1} ns", ns)
        }
    };

    println!(
        "PIPE wire stats ({} samples, {:.3} ms wall time, {:.3} MS/s, {:.1} ns/sample):",
        samples_taken,
        elapsed_us as f64 / 1000.0,
        rate_mhz,
        ns_per_sample,
    );
    println!(
        "  duty:       HIGH {:.2}%   LOW {:.2}%",
        duty_hi, duty_lo,
    );
    println!(
        "  full cycles: {}  →  avg signal freq: {:.1} Hz",
        full_cycles, avg_freq_hz,
    );
    println!(
        "  HIGH runs:  count {:>7}  mean {:>10}  ± {:>10}  min {:>10}  max {:>10}",
        hi_count,
        fmt_ns(hi_mean_ns), fmt_ns(hi_std_ns),
        fmt_ns(hi_min_ns), fmt_ns(hi_max_ns),
    );
    println!(
        "  LOW runs:   count {:>7}  mean {:>10}  ± {:>10}  min {:>10}  max {:>10}",
        lo_count,
        fmt_ns(lo_mean_ns), fmt_ns(lo_std_ns),
        fmt_ns(lo_min_ns), fmt_ns(lo_max_ns),
    );
    println!(
        "  final:      state {}  run {} ({})",
        if final_state == 1 { "HIGH" } else { "LOW" },
        final_run,
        fmt_ns(final_run as f64 * ns_per_sample),
    );

    // Run-length distribution. Bin i = runs of length [2^i, 2^(i+1)) samples. Bar width scales to the larger of the two histograms so HIGH and LOW are visually comparable.
    let max_bin_count = hi_hist.iter().chain(lo_hist.iter()).copied().max().unwrap_or(0);
    if max_bin_count > 0 {
        let bar_max = 40usize;
        println!();
        println!("  run-length distribution (log2 bins of samples, time = bin × ns/sample):");
        println!(
            "    {:>22}   {:>5}  HIGH  |  {:>5}   LOW",
            "bin range (time)", "count", "count",
        );
        // Trim leading/trailing all-zero bins; show only the populated range.
        let first = (0..HIST_BINS).find(|&i| hi_hist[i] > 0 || lo_hist[i] > 0).unwrap_or(0);
        let last = (0..HIST_BINS).rev().find(|&i| hi_hist[i] > 0 || lo_hist[i] > 0).unwrap_or(HIST_BINS - 1);
        for i in first..=last {
            let lo_s = 1u64 << i;
            let hi_s = (1u64 << (i + 1)) - 1;
            let range_label = format!(
                "{}-{}",
                fmt_ns(lo_s as f64 * ns_per_sample),
                fmt_ns(hi_s as f64 * ns_per_sample),
            );
            let h = hi_hist[i];
            let l = lo_hist[i];
            let h_bar = (h as f64 / max_bin_count as f64 * bar_max as f64).round() as usize;
            let l_bar = (l as f64 / max_bin_count as f64 * bar_max as f64).round() as usize;
            println!(
                "    {:>22}   {:>5}  {:<bar_max$}  |  {:>5}   {:<bar_max$}",
                range_label,
                h,
                "#".repeat(h_bar),
                l,
                "#".repeat(l_bar),
                bar_max = bar_max,
            );
        }
    }

    Ok(())
}

/// `wire_sync [MAX_ITER]` — runs the CDR sync loop on the bridge: locks to the enclave's idle 1010 pattern via 256-edge acquisition + bounded-slew tracking. Reports the locked slot period, lock quality (phase error stddev), and how much slot_cycles drifted during tracking.
fn cmd_wire_sync(port_path: &str, args: &[String]) -> Result<(), String> {
    const SYNC_MAX_ITER: u32 = 1 << 22;
    let max_iter: u32 = args
        .first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad MAX_ITER: {e}")))
        .transpose()?
        .unwrap_or(SYNC_MAX_ITER)
        .clamp(2048, SYNC_MAX_ITER);

    let mut params = Vec::with_capacity(4);
    params.extend_from_slice(&max_iter.to_le_bytes());

    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_sync",
        9,
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
    if data.len() < 60 {
        return Err(format!("sync response too short: {} bytes (want 60)", data.len()));
    }

    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let gi32 = |off: usize| i32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let g64 = |off: usize| u64::from_le_bytes([
        data[off], data[off+1], data[off+2], data[off+3],
        data[off+4], data[off+5], data[off+6], data[off+7],
    ]);
    let gi64 = |off: usize| i64::from_le_bytes([
        data[off], data[off+1], data[off+2], data[off+3],
        data[off+4], data[off+5], data[off+6], data[off+7],
    ]);

    let elapsed_us = g32(0) as u64;
    let total_iter = g32(4) as u64;
    let status = g32(8);
    let edges_total = g32(12);
    let acq_slot = g32(16);
    let final_slot = g32(20);
    let slot_min = g32(24);
    let slot_max = g32(28);
    let track_edges = g32(32);
    let err_sum = gi64(36);
    let err_sumsq = g64(44);
    let err_min = gi32(52);
    let err_max = gi32(56);

    // Iteration → ns: total wall time / total iterations.
    let ns_per_iter = if total_iter > 0 {
        (elapsed_us as f64 * 1000.0) / total_iter as f64
    } else {
        0.0
    };
    let iter_mhz = if elapsed_us > 0 {
        total_iter as f64 / elapsed_us as f64
    } else {
        0.0
    };

    let status_str = match status {
        0 => "LOCKED",
        1 => "acquisition timeout (not enough edges in budget)",
        2 => "no edges seen — wire dead?",
        _ => "unknown",
    };
    println!(
        "PIPE wire sync ({} iterations, {:.3} ms wall time, {:.3} Miter/s, {:.1} ns/iter):",
        total_iter, elapsed_us as f64 / 1000.0, iter_mhz, ns_per_iter,
    );
    println!("  status: {}", status_str);
    println!("  edges seen: {} ({} acquisition + {} tracking)",
        edges_total, edges_total.saturating_sub(track_edges), track_edges);

    if status != 0 && status != 1 {
        return Ok(());
    }

    let slot_ns = acq_slot as f64 * ns_per_iter;
    let slot_hz = if slot_ns > 0.0 { 1e9 / slot_ns } else { 0.0 };
    let final_slot_ns = final_slot as f64 * ns_per_iter;
    let slot_drift = final_slot as i64 - acq_slot as i64;
    let slot_drift_ppm = if acq_slot > 0 {
        slot_drift as f64 * 1_000_000.0 / acq_slot as f64
    } else {
        0.0
    };

    println!();
    println!("  initial lock (after 256-edge acquisition):");
    println!("    slot_cycles: {} iterations = {:.3} µs/slot", acq_slot, slot_ns / 1000.0);
    println!("    slot rate:   {:.1} Hz", slot_hz);

    if track_edges > 0 {
        let n = track_edges as f64;
        let err_mean = err_sum as f64 / n;
        let err_var = (err_sumsq as f64 / n - err_mean * err_mean).max(0.0);
        let err_std = err_var.sqrt();
        let err_mean_ns = err_mean * ns_per_iter;
        let err_std_ns = err_std * ns_per_iter;
        let slot_excursion_min_ns = (slot_min as i64 - acq_slot as i64) as f64 * ns_per_iter;
        let slot_excursion_max_ns = (slot_max as i64 - acq_slot as i64) as f64 * ns_per_iter;

        println!();
        println!("  tracking ({} edges):", track_edges);
        println!(
            "    final slot_cycles: {} ({:.3} µs/slot)  →  drift from acq: {:+} iter ({:+.1} ppm)",
            final_slot, final_slot_ns / 1000.0, slot_drift, slot_drift_ppm,
        );
        println!(
            "    slot_cycles range during track: [{}, {}] ({:+.1} ns, {:+.1} ns from acq)",
            slot_min, slot_max, slot_excursion_min_ns, slot_excursion_max_ns,
        );
        println!(
            "    phase error per edge: mean {:+.2} iter ({:+.1} ns)  ± stddev {:.2} iter ({:.1} ns)",
            err_mean, err_mean_ns, err_std, err_std_ns,
        );
        println!(
            "    phase error range: [{}, {}] iter ([{:+.1}, {:+.1}] ns)",
            err_min, err_max,
            err_min as f64 * ns_per_iter, err_max as f64 * ns_per_iter,
        );

        // Lock quality interpretation: a clean lock has stddev << slot_cycles. >25% of slot → not really locked, <1% of slot → tight lock.
        if acq_slot > 0 {
            let std_frac = err_std / acq_slot as f64;
            let quality = if std_frac < 0.01 {
                "tight lock"
            } else if std_frac < 0.05 {
                "good lock"
            } else if std_frac < 0.25 {
                "loose lock"
            } else {
                "unlocked / noise dominated"
            };
            println!("    lock quality: {} (stddev = {:.2}% of slot)", quality, std_frac * 100.0);
        }
    } else {
        println!();
        println!("  no tracking edges within budget — increase MAX_ITER");
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
