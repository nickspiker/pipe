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
                "usage: bridge [--port <path>] [--inspect] <ping|info|uptime|random [N]|wire_trace [SAMPLES [PERIOD_NS]]|wire_stats [SAMPLES]|wire_sync [MAX_ITER [FRAC_BITS [SETTLE_ITER]]]|wire_decode [MAX_ITER [FRAC_BITS]]|bootsel|reset|flash <uf2>|load_dev <elf-or-bin>>"
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
        "wire_decode" => cmd_wire_decode(&port_path, cmd_args),
        "bootsel" => cmd_action(&port_path, "bootsel"),
        "reset" => cmd_action(&port_path, "reset"),
        "flash" => cmd_flash(&port_path, cmd_args),
        "load_dev" => cmd_load_dev(&port_path, cmd_args),
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
    // 150s read timeout — wire_sync with the full 2^28 iteration budget can run up to ~90s on the bridge before responding. Other commands respond quickly and won't care.
    serialport::new(path, 115_200)
        .timeout(Duration::from_secs(150))
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

/// `wire_sync [MAX_ITER [FRAC_BITS]]` — runs the bridge CDR: same-polarity acquisition (128 rise-to-rise + 128 fall-to-fall, slot = sum >> 9), then a per-polarity bang-bang tracker slews interval_fp by ±1 fp unit per edge (slew = slot/2^FRAC_BITS). Bins per-polarity phase_err. Defaults: MAX_ITER = 2^25 (~6 s), FRAC_BITS = 11.
fn cmd_wire_sync(port_path: &str, args: &[String]) -> Result<(), String> {
    const SYNC_MAX_ITER: u32 = 1 << 28;
    let max_iter: u32 = args
        .first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad MAX_ITER: {e}")))
        .transpose()?
        .unwrap_or(1 << 25)
        .clamp(2048, SYNC_MAX_ITER);
    let frac_bits: u32 = args
        .get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad FRAC_BITS: {e}")))
        .transpose()?
        .unwrap_or(13)
        .clamp(2, 19);
    let settle_iter: u32 = args
        .get(2)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SETTLE_ITER: {e}")))
        .transpose()?
        .unwrap_or(0);

    let mut params = Vec::with_capacity(12);
    params.extend_from_slice(&max_iter.to_le_bytes());
    params.extend_from_slice(&frac_bits.to_le_bytes());
    params.extend_from_slice(&settle_iter.to_le_bytes());

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
    // Scalar header is 17 × u32 + 3 × i64 = 92 bytes; then 2 × hist_bins × u16.
    if data.len() < 92 {
        return Err(format!("sync response too short: {} bytes (want >= 92 scalar header)", data.len()));
    }
    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let gi64 = |off: usize| i64::from_le_bytes([
        data[off], data[off+1], data[off+2], data[off+3],
        data[off+4], data[off+5], data[off+6], data[off+7],
    ]);
    let g16 = |off: usize| u16::from_le_bytes([data[off], data[off+1]]);

    let elapsed_us = g32(0) as u64;
    let total_iter = g32(4) as u64;
    let status = g32(8);
    let frac_bits = g32(12);
    let acquisition_slot_iter = g32(16);
    let final_interval_fp = g32(20);
    let acquisition_iter_count = g32(24);
    let measurement_iter_count = g32(28);
    let acq_rising = g32(32);
    let acq_falling = g32(36);
    let rising_total = g32(40);
    let falling_total = g32(44);
    let rising_neg_overflow = g32(48);
    let rising_pos_overflow = g32(52);
    let falling_neg_overflow = g32(56);
    let falling_pos_overflow = g32(60);
    let hist_bins = g32(64) as usize;
    let hist_half_range = (hist_bins / 2) as i32;
    let phase_sum = gi64(68);
    let fall_to_rise_offset_sum = gi64(76);
    let rise_to_fall_offset_sum = gi64(84);

    let hist_off = 92;
    let hist_bytes = hist_bins * 2;
    if data.len() < hist_off + 2 * hist_bytes {
        return Err(format!(
            "sync response truncated: have {} bytes, need {} (scalars + 2 × {} bins)",
            data.len(), hist_off + 2 * hist_bytes, hist_bins,
        ));
    }
    let rising_hist: Vec<u16> = (0..hist_bins).map(|i| g16(hist_off + i * 2)).collect();
    let falling_hist: Vec<u16> = (0..hist_bins).map(|i| g16(hist_off + hist_bytes + i * 2)).collect();

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
        1 => "acquisition incomplete (not enough same-polarity intervals in budget)",
        2 => "no edges seen — wire dead?",
        _ => "unknown",
    };
    println!(
        "PIPE wire sync ({} iterations, {:.3} ms wall time, {:.3} Miter/s, {:.1} ns/iter):",
        total_iter, elapsed_us as f64 / 1000.0, iter_mhz, ns_per_iter,
    );
    println!("  status: {}", status_str);

    if status == 2 {
        return Ok(());
    }

    let fp_scale = (1u64 << frac_bits) as f64;
    let acq_ns = acquisition_slot_iter as f64 * ns_per_iter;
    let acq_hz = if acq_ns > 0.0 { 1e9 / acq_ns } else { 0.0 };
    let final_slot_iter = final_interval_fp as f64 / fp_scale;
    let final_ns = final_slot_iter * ns_per_iter;
    let drift_iter = final_slot_iter - acquisition_slot_iter as f64;
    let drift_ppm = if acquisition_slot_iter > 0 {
        drift_iter * 1_000_000.0 / acquisition_slot_iter as f64
    } else {
        0.0
    };

    println!();
    println!("  acquisition: {} edges ({} rise-to-rise + {} fall-to-fall) in {} iter ({:.3} ms); seed slot {} iter = {:.3} µs ({:.1} Hz)",
        acq_rising + acq_falling, acq_rising, acq_falling,
        acquisition_iter_count,
        acquisition_iter_count as f64 * ns_per_iter / 1_000_000.0,
        acquisition_slot_iter, acq_ns / 1000.0, acq_hz,
    );

    let total_edges = rising_total + falling_total;
    let total_ov = rising_neg_overflow + rising_pos_overflow + falling_neg_overflow + falling_pos_overflow;

    println!("  tracking:    {} edges ({} rising + {} falling) in {} iter ({:.3} ms); {} hist overflow; FRAC={} (slew ±slot/{} per edge)",
        total_edges, rising_total, falling_total,
        measurement_iter_count,
        measurement_iter_count as f64 * ns_per_iter / 1_000_000.0,
        total_ov, frac_bits, 1u32 << frac_bits,
    );

    if total_edges == 0 {
        println!("  no tracking edges — increase MAX_ITER or check wire");
        return Ok(());
    }

    println!();
    println!("  final interval (fp): {} = {:.4} iter = {:.3} µs/slot   drift from acquisition: {:+.4} iter ({:+.1} ppm)",
        final_interval_fp, final_slot_iter, final_ns / 1000.0,
        drift_iter, drift_ppm,
    );

    let phase_mean = phase_sum as f64 / total_edges as f64;
    println!("  mean phase_err: {:+.3} iter ({:+.1} ns) over {} edges (trends to 0 when lock matches wire)",
        phase_mean, phase_mean * ns_per_iter, total_edges);

    if rising_total > 0 && falling_total > 0 {
        let fr_mean = fall_to_rise_offset_sum as f64 / rising_total as f64;
        let rf_mean = rise_to_fall_offset_sum as f64 / falling_total as f64;
        let delta_rc = (rf_mean - fr_mean) / 2.0;
        println!("  RC offset: rise→fall {:+.3} iter, fall→rise {:+.3} iter  →  Δrc = {:+.3} iter ({:+.1} ns)",
            rf_mean, fr_mean, delta_rc, delta_rc * ns_per_iter);
    }

    // Per-polarity phase_err histograms. Bin i represents phase_err = (i - hist_half_range) iter.
    let render_hist = |label: &str, hist: &[u16], neg_ov: u32, pos_ov: u32| {
        let total: u64 = hist.iter().map(|&v| v as u64).sum::<u64>() + neg_ov as u64 + pos_ov as u64;
        if total == 0 {
            println!("    {} hist: (no edges)", label);
            return;
        }
        let first = hist.iter().position(|&v| v > 0);
        let last = hist.iter().rposition(|&v| v > 0);
        println!("    {} hist (signed iter offset → count, total {}, overflow {} neg / {} pos):",
            label, total, neg_ov, pos_ov);
        if let (Some(f), Some(l)) = (first, last) {
            for i in f..=l {
                let count = hist[i];
                if count == 0 { continue; }
                let signed_off = i as i32 - hist_half_range;
                println!("      {:+5} iter ({:+8.1} ns)  {:>6}",
                    signed_off,
                    signed_off as f64 * ns_per_iter,
                    count,
                );
            }
        }
    };

    println!();
    render_hist("rising", &rising_hist, rising_neg_overflow, rising_pos_overflow);
    println!();
    render_hist("falling", &falling_hist, falling_neg_overflow, falling_pos_overflow);

    Ok(())
}

/// `wire_decode [MAX_ITER [FRAC_BITS]]` — runs the bridge decoder: same acquisition + bang-bang CDR as wire_sync, plus a continuous slot clock driven by interval_fp that ticks every slot regardless of edge density. Samples mid-slot, decodes via codec.rx during enclave slots, codec.tx(0) during host slots. Reports the locked slot, per-polarity HIGH/LOW widths (RC asymmetry), slot count, and last 256 decoded bits.
fn cmd_wire_decode(port_path: &str, args: &[String]) -> Result<(), String> {
    const DECODE_MAX_ITER: u32 = 1 << 28;
    let max_iter: u32 = args
        .first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad MAX_ITER: {e}")))
        .transpose()?
        .unwrap_or(5_000_000)
        .clamp(2048, DECODE_MAX_ITER);
    let frac_bits: u32 = args
        .get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad FRAC_BITS: {e}")))
        .transpose()?
        .unwrap_or(13)
        .clamp(2, 19);

    let mut params = Vec::with_capacity(8);
    params.extend_from_slice(&max_iter.to_le_bytes());
    params.extend_from_slice(&frac_bits.to_le_bytes());

    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_decode",
        14,
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
    // Layout (LE): 16 × u32 + 2 × u64 (hi/lo sums) + 4 × u64 (recent_bits) = 112 bytes.
    if data.len() < 112 {
        return Err(format!("decode response too short: {} bytes (want 112)", data.len()));
    }

    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let g64 = |off: usize| u64::from_le_bytes([
        data[off], data[off+1], data[off+2], data[off+3],
        data[off+4], data[off+5], data[off+6], data[off+7],
    ]);

    let elapsed_us = g32(0) as u64;
    let total_iter = g32(4) as u64;
    let status = g32(8);
    let frac_bits = g32(12);
    let acquisition_slot_iter = g32(16);
    let final_interval_fp = g32(20);
    let hi_count = g32(24);
    let hi_sum = g64(28);
    let hi_min = g32(36);
    let hi_max = g32(40);
    let lo_count = g32(44);
    let lo_sum = g64(48);
    let lo_min = g32(56);
    let lo_max = g32(60);
    let slots_total = g32(64);
    let bits_decoded = g32(68);
    let ones = g32(72);
    let zeros = g32(76);
    let recent_bits: [u64; 4] = [g64(80), g64(88), g64(96), g64(104)];

    let ns_per_iter = if total_iter > 0 {
        (elapsed_us as f64 * 1000.0) / total_iter as f64
    } else {
        0.0
    };

    let status_str = match status {
        0 => "DECODED",
        1 => "acquisition incomplete",
        2 => "no edges seen",
        3 => "phase anchor not found (no rising edge after acquisition)",
        _ => "unknown",
    };
    println!(
        "PIPE wire decode ({} iterations, {:.3} ms wall time, {:.1} ns/iter):",
        total_iter, elapsed_us as f64 / 1000.0, ns_per_iter,
    );
    println!("  status: {} (frac_bits={})", status_str, frac_bits);

    if status == 2 {
        return Ok(());
    }

    let fp_scale = (1u64 << frac_bits) as f64;
    let final_slot_iter = final_interval_fp as f64 / fp_scale;
    let final_slot_ns = final_slot_iter * ns_per_iter;
    let final_slot_hz = if final_slot_ns > 0.0 { 1e9 / final_slot_ns } else { 0.0 };
    let acq_slot_ns = acquisition_slot_iter as f64 * ns_per_iter;
    let drift_iter = final_slot_iter - acquisition_slot_iter as f64;

    println!();
    println!("  acquisition seed slot: {} iter ({:.3} µs)",
        acquisition_slot_iter, acq_slot_ns / 1000.0);
    println!("  final locked slot:     {:.4} iter ({:.3} µs, {:.1} Hz)   drift: {:+.4} iter",
        final_slot_iter, final_slot_ns / 1000.0, final_slot_hz, drift_iter);
    println!("  slots ticked:          {} (slot clock fires every slot regardless of edge density)",
        slots_total);

    if hi_count > 0 && lo_count > 0 {
        let hi_avg_iter = hi_sum as f64 / hi_count as f64;
        let lo_avg_iter = lo_sum as f64 / lo_count as f64;
        let hi_avg_ns = hi_avg_iter * ns_per_iter;
        let lo_avg_ns = lo_avg_iter * ns_per_iter;
        let asym_ns = (lo_avg_ns - hi_avg_ns).abs();
        let asym_pct = 100.0 * asym_ns / (hi_avg_ns + lo_avg_ns);
        println!();
        println!("  HIGH width: count {}, mean {:.3} µs (range [{:.3}, {:.3}] µs)",
            hi_count, hi_avg_ns / 1000.0,
            hi_min as f64 * ns_per_iter / 1000.0,
            hi_max as f64 * ns_per_iter / 1000.0);
        println!("  LOW width:  count {}, mean {:.3} µs (range [{:.3}, {:.3}] µs)",
            lo_count, lo_avg_ns / 1000.0,
            lo_min as f64 * ns_per_iter / 1000.0,
            lo_max as f64 * ns_per_iter / 1000.0);
        println!("  RC asymmetry: |HIGH-LOW| = {:.2} µs ({:.2}% of cycle)",
            asym_ns / 1000.0, asym_pct);
    }

    println!();
    println!("  bits decoded: {} ({} zeros, {} ones)", bits_decoded, zeros, ones);
    if bits_decoded > 0 {
        let pct_ones = 100.0 * ones as f64 / bits_decoded as f64;
        println!("  ones ratio:   {:.1}%  (idle wire decodes to all zeros)", pct_ones);
    }

    if bits_decoded == 0 {
        return Ok(());
    }

    let to_show = (bits_decoded as usize).min(256);
    println!();
    println!("  last {} decoded bits (oldest → newest):", to_show);
    let mut bitstr = String::with_capacity(256 + 64);
    for i in (0..256).rev() {
        let word = i / 64;
        let pos = i % 64;
        let bit = (recent_bits[word] >> pos) & 1;
        if !bitstr.is_empty() && bitstr.len() % 64 == 0 {
            bitstr.push('\n');
            bitstr.push_str("    ");
        } else if bitstr.len() % 8 == 0 && !bitstr.is_empty() && bitstr.chars().last() != Some('\n') {
            bitstr.push(' ');
        }
        bitstr.push(if bit == 1 { '1' } else { '0' });
        if to_show < 256 && (255 - i) >= to_show { break; }
    }
    println!("    {}", bitstr);

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

/// `load_dev <path-to-elf-or-bin>` — hot-loads a dev image into the bridge's SRAM via the running manager firmware (no PICOBOOT, no chip reset, no boot ROM dance). Flow: objcopy the ELF to flat binary if needed; BLAKE3-hash it; send a `load_dev` VSF cmd carrying size+hash; on `load_dev_ready` ack, stream the raw bytes back-to-back over the same CDC link; the manager verifies the hash, jumps to vector_table[1] with SP from vector_table[0]. The USB disconnect that follows IS the success signal — re-enumeration brings up the dev image, which we then ping to confirm.
fn cmd_load_dev(port_path: &str, args: &[String]) -> Result<(), String> {
    let src_path = args.first().ok_or("usage: bridge load_dev <path/to/elf-or-bin>")?;
    let src_path = std::path::Path::new(src_path);
    if !src_path.exists() {
        return Err(format!("image not found: {}", src_path.display()));
    }

    let elf_magic = {
        let mut buf = [0u8; 4];
        std::fs::File::open(src_path)
            .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut buf))
            .map(|_| buf == [0x7f, b'E', b'L', b'F'])
            .unwrap_or(false)
    };

    let bin_path: std::path::PathBuf = if elf_magic {
        let bin = src_path.with_extension("bin");
        print!("→ objcopy -O binary {} → {} ", src_path.display(), bin.display());
        let _ = std::io::stdout().flush();
        let status = std::process::Command::new("llvm-objcopy")
            .args(["-O", "binary"])
            .arg(src_path)
            .arg(&bin)
            .status()
            .map_err(|e| format!("\nspawn llvm-objcopy: {e}"))?;
        if !status.success() {
            return Err(format!("\nllvm-objcopy failed: {status}"));
        }
        println!("(done)");
        bin
    } else {
        src_path.to_path_buf()
    };

    let image = std::fs::read(&bin_path).map_err(|e| format!("read {}: {e}", bin_path.display()))?;
    if image.len() < 8 {
        return Err(format!("image too short ({} bytes) — needs at least vector table", image.len()));
    }
    let initial_sp = u32::from_le_bytes([image[0], image[1], image[2], image[3]]);
    let reset_handler = u32::from_le_bytes([image[4], image[5], image[6], image[7]]);
    let hash = blake3::hash(&image);
    println!(
        "→ image: {} bytes, SP=0x{:08X}, reset=0x{:08X}, BLAKE3={}",
        image.len(),
        initial_sp,
        reset_handler,
        hash.to_hex(),
    );

    // Phase 1: hand off the size + hash via a normal VSF cmd. The manager validates
    // size (≤ 176 KiB) and replies "load_dev_ready" before we stream a single byte.
    let extras = vec![
        ("n".to_string(), VsfType::u(image.len(), false)),
        ("did".to_string(), VsfType::hp(hash.as_bytes().to_vec())),
    ];
    println!("→ load_dev cmd (size + hash)");
    let (resp, _rtt) = send_cmd(port_path, "load_dev", 9001, extras)?;
    if resp.is_empty() {
        return Err("no response from load_dev cmd (manager unreachable)".into());
    }
    let section = parse_resp(&resp)?;
    if let Some(err) = resp_ascii(&section, "err") {
        return Err(format!("manager rejected load: {err}"));
    }
    if resp_ascii(&section, "op") != Some("load_dev_ready") {
        return Err("manager did not ack with load_dev_ready".into());
    }

    // Phase 2: stream the image bytes over the same CDC link. The manager is in a
    // tight `class.read_packet` loop; we just push the bytes through. open_port
    // already set a 150s read timeout — the write side has no separate timeout,
    // and the kernel paces full-speed CDC at ~1 Mbit/s (~1.5 s for 164 KB).
    println!("→ streaming {} bytes", image.len());
    let mut port = open_port(port_path)?;
    let t_stream = Instant::now();
    port.write_all(&image).map_err(|e| format!("stream write: {e}"))?;
    port.flush().map_err(|e| format!("stream flush: {e}"))?;
    let stream_ms = t_stream.elapsed().as_secs_f64() * 1000.0;
    println!(
        "  streamed in {:.0} ms ({:.1} kB/s)",
        stream_ms,
        (image.len() as f64 / 1024.0) / (stream_ms / 1000.0),
    );

    // The manager will either jump (USB disconnect = success) or send a final error
    // response (hash_mismatch / disconnect). Read with a short deadline so we can
    // tell the two apart: if any bytes come back, parse them; if the port goes away
    // first, treat that as success.
    let mut err_buf = Vec::with_capacity(128);
    let mut chunk = [0u8; 128];
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if Instant::now() > deadline {
            break;
        }
        match port.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                err_buf.extend_from_slice(&chunk[..n]);
                if err_buf.last() == Some(&b']') {
                    break;
                }
            }
            Err(e) if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::BrokenPipe) => break,
            Err(_) => break,
        }
    }
    drop(port);
    if !err_buf.is_empty() {
        if let Ok(s) = parse_resp(&err_buf) {
            if let Some(err) = resp_ascii(&s, "err") {
                return Err(format!("manager reported {err} after stream"));
            }
        }
    }

    // Phase 3: wait for the dev image to re-enumerate. The manager calls
    // `bx reset_handler` after hashing succeeds; embassy_rp::init in the dev image
    // resets USBCTRL as part of clocks::init, so the host kernel sees a clean
    // disconnect followed by a new ACM device. Existing wait_for polls every 100ms.
    let port_pb = std::path::PathBuf::from(port_path);
    print!("→ waiting for {} to re-enumerate ", port_pb.display());
    let _ = std::io::stdout().flush();
    wait_for(
        Instant::now() + Duration::from_secs(10),
        || if port_pb.exists() { Some(()) } else { None },
        "serial device",
    )?;
    println!("(found)");
    std::thread::sleep(Duration::from_millis(500));

    println!("→ verifying with ping");
    cmd_ping(port_path)?;
    println!("load_dev: success");
    Ok(())
}
