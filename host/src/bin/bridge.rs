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

/// 256-bit FPGA TX_PATTERN mirror. Must match `TX_PATTERN` in
/// rtl/measure/top_pipe_mirror_xor.v exactly. Source string is
/// "The quick brown fox jumps over t" (32 ASCII chars = 256 bits).
/// Byte 0 = 'T' = G#54; bit 0 within each byte is consumed first by the
/// FPGA's `fpga_tx_reg[0]` (LSB-first per byte). A 256/256 match between
/// bridge's `fpga_decoded_log` and a rotation of this constant proves
/// Claims 7+12 bit-clean over that 256-slot capture window.
const FPGA_TX_PATTERN_256: [u8; 32] = [
    b'T', b'h', b'e', b' ', b'q', b'u', b'i', b'c',
    b'k', b' ', b'b', b'r', b'o', b'w', b'n', b' ',
    b'f', b'o', b'x', b' ', b'j', b'u', b'm', b'p',
    b's', b' ', b'o', b'v', b'e', b'r', b' ', b't',
];

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
                "usage: bridge [--port <path>] [--inspect] <ping|info|uptime|random [N]|wire_trace [SAMPLES [PERIOD_NS]]|wire_stats [SAMPLES]|wire_sync [MAX_ITER [FRAC_BITS [SETTLE_ITER [P_SHIFT [CASCADE_MODE]]]]]|wire_bits [P_SHIFT [LFSR_SEED_HEX]]|wire_loopback [TX_PATTERN_HEX [P_SHIFT]]|tune_p [P_MIN [P_MAX [MAX_ITER [FRAC_BITS]]]]|wire_decode [MAX_ITER [FRAC_BITS]]|wire_mirror [MAX_EDGES [FRAC_BITS [P_SHIFT [TX_PATTERN_HEX]]]]|bootsel|reset|flash <uf2>|load_dev <elf-or-bin>>"
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
        "wire_count_decode" => cmd_wire_count_decode(&port_path, cmd_args),
        "wire_count_watch" => cmd_wire_count_watch(&port_path, cmd_args),
        "wire_count_drive" => cmd_wire_count_drive(&port_path, cmd_args),
        "wire_4096_decode" => cmd_wire_4096_decode(&port_path, cmd_args),
        "wire_gap_decode" => cmd_wire_gap_decode(&port_path, cmd_args),
        "meal_dump_ira" => cmd_meal_dump_ira(cmd_args),
        "meal_challenge" => cmd_meal_challenge(cmd_args),
        "meal_health" => cmd_meal_health(&port_path, cmd_args),
        "meal_motuhake" => cmd_meal_motuhake(&port_path, cmd_args),
        "wire_pattern_decode" => cmd_wire_pattern_decode(&port_path, cmd_args),
        "wire_stats" => cmd_wire_stats(&port_path, cmd_args),
        "wire_sync" => cmd_wire_sync(&port_path, cmd_args),
        "wire_bits" => cmd_wire_bits(&port_path, cmd_args),
        "wire_loopback" => cmd_wire_loopback(&port_path, cmd_args),
        "wire_tx_diag" => cmd_wire_tx_diag(&port_path),
        "tune_p" => cmd_tune_p(&port_path, cmd_args),
        "wire_decode" => cmd_wire_decode(&port_path, cmd_args),
        "wire_mirror" => cmd_wire_mirror(&port_path, cmd_args),
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

/// Compute the expected wire value at each slot boundary, given the bridge's TX pattern
/// and the FPGA's TX pattern, simulating the Claim 12 mirror-XOR protocol per slot.
///
/// Returns N bits where bit i = wire value during absolute slot (i + 1). Slot indexing:
/// slot 0 = initial enclave slot (pre-log; FPGA in IDLE), slot 1 = first host slot
/// (bridge's first drive bit), slot 2 = first DATA-mode-possible enclave slot, etc.
///
/// `force_idle = true` keeps fpga_data_mode false the whole simulation (= simulates
/// "handshake never fired", whatever bridge sent). Used to print IDLE-mode expected
/// pattern side-by-side with DATA-mode expected for the operator to compare.
///
/// FPGA TX rotation: per top_pipe_mirror_xor.v, `fpga_tx_reg` rotates right on every
/// host→enclave transition. So slot 0 uses fpga_tx[0], slot 2 uses fpga_tx[1], slot 4
/// uses fpga_tx[2], etc. (the index is half the slot index).
///
/// Handshake: at FPGA's mid-host-slot sample, if wire==1 and data_mode==0, then
/// data_mode <= 1 (effective starting the NEXT enclave slot).
fn expected_wire_pattern(bridge_tx: u32, fpga_tx: u32, n_slots: usize, force_idle: bool) -> Vec<u8> {
    let mut result = Vec::with_capacity(n_slots);
    let mut fpga_data_mode = false;
    let mut fpga_tx_pos: u32 = 0;
    let mut bridge_last_decoded: u8 = 0;
    let mut bridge_bit_idx: u32 = 0;
    for slot_in_log in 0..n_slots {
        let absolute_slot = slot_in_log + 1;
        let is_host = absolute_slot % 2 == 1;
        let wire = if is_host {
            let drive = ((bridge_tx >> (bridge_bit_idx & 31)) & 1) as u8;
            bridge_bit_idx = bridge_bit_idx.wrapping_add(1);
            if drive == 1 && !fpga_data_mode && !force_idle {
                fpga_data_mode = true;
            }
            bridge_last_decoded = drive;
            drive
        } else {
            fpga_tx_pos = fpga_tx_pos.wrapping_add(1);
            let fpga_bit = if fpga_data_mode {
                ((fpga_tx >> (fpga_tx_pos & 31)) & 1) as u8
            } else {
                0
            };
            1 ^ fpga_bit ^ bridge_last_decoded
        };
        result.push(wire);
    }
    result
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
    if let Some(pipe) = resp_u64(&section, "pipe") {
        let state = match pipe {
            1 => "LOCKED (comms held in last sync)",
            _ => "UNLOCKED (no comms / never synced)",
        };
        println!("pipe: {state}");
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

/// Capture one wire_trace block and decode any counter transmissions in it.
/// Returns the (period_est_samples, list_of_decoded_counts). Used by both the
/// single-shot `wire_count_decode` and the live-watching `wire_count_watch`.
fn capture_and_decode_counter(
    port_path: &str,
    samples_req: u32,
    period_ns: u32,
    verbose: bool,
) -> Result<(f64, Vec<u32>), String> {
    let mut params = Vec::with_capacity(8);
    params.extend_from_slice(&samples_req.to_le_bytes());
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
        return Err(format!("trace truncated"));
    }
    let bits = &data[8..8 + expected_bytes];
    let samples: Vec<u8> = (0..captured)
        .map(|i| (bits[i >> 3] >> (i & 7)) & 1)
        .collect();
    let actual_period_ns = if captured > 0 {
        (elapsed_us as f64 * 1000.0) / captured as f64
    } else {
        0.0
    };
    if verbose {
        println!(
            "wire_count_decode: {} samples / {} µs (sample period = {:.0} ns)",
            captured, elapsed_us, actual_period_ns
        );
    }

    let edges: Vec<usize> = (1..samples.len())
        .filter(|&i| samples[i] != samples[i - 1])
        .collect();
    if edges.len() < 20 {
        return Ok((0.0, vec![]));
    }

    // ROBUST period estimation: combine median (outlier-resistant) with a P
    // controller for tracking convergence. The median gives an immediate
    // unbiased estimate even when some edges are sync prefixes or stretched-
    // TX-bit intervals (= outliers). The P controller then refines by snapping
    // phase to each accepted edge — but bounded so TX-phase drift can't pull
    // it off true.
    let intervals: Vec<usize> = edges.windows(2).map(|w| w[1] - w[0]).collect();
    let mut sorted_intervals = intervals.clone();
    sorted_intervals.sort_unstable();
    // True median.
    let median = sorted_intervals[sorted_intervals.len() / 2] as f64;
    // P-loop with TIGHT outlier rejection: anything > 25% off from median is
    // a non-idle interval (TX bit-pair / sync / glitch). Skip those entirely.
    let k_p: f64 = 0.05;
    let mut period_est = median;
    let mut phase_ref = edges[0] as f64;
    let (mut accepted, mut rejected) = (0usize, 0usize);
    for &edge in &edges[1..] {
        let actual = edge as f64;
        let predicted = phase_ref + period_est;
        let error = actual - predicted;
        if error.abs() > 0.25 * median {
            rejected += 1;
            // Snap phase forward but DO NOT update period — coast thru the
            // outlier interval so the next valid edge re-anchors.
            phase_ref = actual;
        } else {
            period_est += k_p * error;
            phase_ref = actual;
            accepted += 1;
        }
    }
    if verbose {
        println!(
            "  period: median = {:.3}, P-loop refined = {:.3} samples ({:.1} ns); edges {} accepted, {} rejected",
            median, period_est, period_est * actual_period_ns, accepted, rejected
        );
    }

    // Find syncs (LOW runs > 1.5 × period_est, ≤ 4 × period_est). The upper
    // bound rejects the FPGA's post-TX RX window: bridge tristate during RX
    // means the wire floats LOW for RX_TICKS (= 16) wire_clks. A real sync is
    // SYNC_TICKS (= 2) wire_clks. Anything in between is fine to accept.
    let sync_min = (period_est * 1.5) as usize;
    let sync_max = (period_est * 4.0) as usize;
    let mut syncs: Vec<usize> = Vec::new();
    let mut i = 1;
    while i < samples.len() {
        if samples[i] == 0 && samples[i - 1] == 1 {
            let mut j = i;
            while j < samples.len() && samples[j] == 0 {
                j += 1;
            }
            let run_len = j - i;
            if run_len > sync_min && run_len <= sync_max && j < samples.len() {
                syncs.push(j);
            }
            i = j + 1;
        } else {
            i += 1;
        }
    }

    // Decode each sync into a 32-bit count.
    let mut counts: Vec<u32> = Vec::new();
    for &sync_end in &syncs {
        let mut count: u32 = 0;
        let mut decoded = 0u32;
        for n in 0..32u32 {
            let off = ((2.0 * n as f64 + 1.5) * period_est).round() as usize;
            let idx = sync_end + off;
            if idx >= samples.len() {
                break;
            }
            if samples[idx] != 0 {
                count |= 1u32 << n;
            }
            decoded += 1;
        }
        if decoded == 32 {
            counts.push(count);
        }
    }
    Ok((period_est, counts))
}

/// `wire_count_decode [SAMPLES [PERIOD_NS]]` — single-shot decode + verbose output.
fn cmd_wire_count_decode(port_path: &str, args: &[String]) -> Result<(), String> {
    const TRACE_MAX_SAMPLES: u32 = 8192;
    let samples_req: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SAMPLES: {e}")))
        .transpose()?
        .unwrap_or(TRACE_MAX_SAMPLES)
        .clamp(1, TRACE_MAX_SAMPLES);
    let period_ns: u32 = args.get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(10_000);
    let (period_est, counts) = capture_and_decode_counter(port_path, samples_req, period_ns, true)?;
    if counts.is_empty() {
        println!("  no syncs decoded — FPGA may be idling, or capture missed the TX window");
    } else {
        const PATTERN_REF: &[u8; 32] = b"The quick brown fox jumps over t";
        for (i, c) in counts.iter().enumerate() {
            // Payload: [3'h0:byte_idx][last_rx_byte][8'h00][pattern_byte]
            let pattern_byte = (c & 0xFF) as u8;
            let sep          = ((c >> 8) & 0xFF) as u8;
            let last_rx_byte = ((c >> 16) & 0xFF) as u8;
            let byte_idx     = ((c >> 24) & 0x1F) as u8;
            let pad          = ((c >> 29) & 0x07) as u8;
            let expected     = PATTERN_REF[byte_idx as usize & 31];
            let pat_ok       = pattern_byte == expected;
            let printable    = if pattern_byte.is_ascii_graphic() || pattern_byte == b' ' {
                pattern_byte as char
            } else {
                '?'
            };
            println!(
                "  sync #{}: G#{:08X}  byte_idx={:2}  pattern=G#{:02X} '{}'  last_rx=G#{:02X}  sep=G#{:02X}  pad=G#{}  {}",
                i, c, byte_idx, pattern_byte, printable, last_rx_byte, sep, pad,
                if pat_ok { "✓ pattern match" } else { "✗ MISMATCH" }
            );
        }
    }
    let _ = period_est;
    Ok(())
}

/// `wire_pattern_decode [SAMPLES [PERIOD_NS]]` — capture + decode top_pipe_pattern.v
/// transmission. Each wire_clk = 1 slot. Even slots = enclave (= pattern bit),
/// odd slots = host (always 1). Decoder:
///   1. Locate edges, lock wire_clk_period via median + P-loop (same as counter).
///   2. Convert sample stream → slot stream by classifying each wire_clk region
///      via midpoint sampling at known offsets from a phase anchor.
///   3. Try both possible alignments (even slots = enclave OR odd slots = enclave).
///      The correct alignment has odd slots ≈ all 1s (= host slots driven HIGH).
///   4. Extract 256 pattern bits LSB-first, compare to expected "The quick brown..."
fn cmd_wire_pattern_decode(port_path: &str, args: &[String]) -> Result<(), String> {
    const TRACE_MAX_SAMPLES: u32 = 8192;
    let samples_req: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SAMPLES: {e}")))
        .transpose()?
        .unwrap_or(TRACE_MAX_SAMPLES)
        .clamp(1, TRACE_MAX_SAMPLES);
    let period_ns: u32 = args.get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(10_000);

    // Capture raw samples.
    let mut params = Vec::with_capacity(8);
    params.extend_from_slice(&samples_req.to_le_bytes());
    params.extend_from_slice(&period_ns.to_le_bytes());
    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_trace",
        7,
        vec![("data".to_string(), VsfType::v(b'b', params))],
    )?;
    if resp.is_empty() { return Err("no response".into()); }
    let section = parse_resp(&resp)?;
    let data = section.get("data").map_err(|e| format!("missing data: {e}"))?
        .first().and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()), _ => None
        }).ok_or("data field not binary")?;
    if data.len() < 8 { return Err("trace too short".into()); }
    let captured = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let elapsed_us = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as u64;
    let expected_bytes = (captured + 7) >> 3;
    if data.len() < 8 + expected_bytes { return Err("trace truncated".into()); }
    let bits_data = &data[8..8 + expected_bytes];
    let samples: Vec<u8> = (0..captured).map(|i| (bits_data[i >> 3] >> (i & 7)) & 1).collect();
    let actual_period_ns = if captured > 0 { (elapsed_us as f64 * 1000.0) / captured as f64 } else { 0.0 };
    println!("wire_pattern_decode: {} samples / {} µs ({:.0} ns/sample)", captured, elapsed_us, actual_period_ns);

    // Find edges + lock wire_clk via median + P-loop (same as counter decoder).
    let edges: Vec<usize> = (1..samples.len()).filter(|&i| samples[i] != samples[i-1]).collect();
    if edges.len() < 20 { return Err(format!("only {} edges", edges.len())); }
    let mut intervals: Vec<usize> = edges.windows(2).map(|w| w[1] - w[0]).collect();
    intervals.sort_unstable();
    let median = intervals[intervals.len() / 2] as f64;
    let k_p = 0.05f64;
    let mut period_est = median;
    let mut phase_ref = edges[0] as f64;
    for &edge in &edges[1..] {
        let actual = edge as f64;
        let error = actual - (phase_ref + period_est);
        if error.abs() <= 0.25 * median {
            period_est += k_p * error;
        }
        phase_ref = actual;
    }
    println!("  wire_clk_period = {:.3} samples ({:.1} ns)", period_est, period_est * actual_period_ns);

    const EXPECTED: &[u8; 32] = b"The quick brown fox jumps over t";

    // Brute-force phase + slot-alignment search. Try every fractional offset
    // within one wire_clk period (8 sub-positions) and both slot parities,
    // pick the combination that gives the best bit-match against the expected
    // pattern (any 32-byte rotation). This is more robust than guessing phase
    // from the first edge.
    let phase0_base = edges[0] as f64;
    let mut best: Option<(usize, usize, f64, Vec<u8>)> = None; // (rot, bits_match, phase_used, bytes)

    for phase_frac_idx in 0..16 {
        let phase_offset = phase0_base + (phase_frac_idx as f64) * period_est / 16.0;
        let num_slots = ((samples.len() as f64 - phase_offset) / period_est) as usize;
        if num_slots < 64 { continue; }
        let max_slots = num_slots.min(4096);
        let mut slot_bits: Vec<u8> = Vec::with_capacity(max_slots);
        for n in 0..max_slots {
            let mid_pos = (phase_offset + (n as f64 + 0.5) * period_est) as usize;
            if mid_pos >= samples.len() { break; }
            slot_bits.push(samples[mid_pos]);
        }
        for enclave_offset in 0..2usize {
            let pattern_bits: Vec<u8> = (enclave_offset..slot_bits.len()).step_by(2)
                .map(|n| slot_bits[n]).collect();
            let n_full_bytes = pattern_bits.len() / 8;
            if n_full_bytes < 4 { continue; }
            let mut pattern_bytes: Vec<u8> = Vec::with_capacity(n_full_bytes);
            for byte_idx in 0..n_full_bytes {
                let mut b = 0u8;
                for bit in 0..8 {
                    if pattern_bits[byte_idx * 8 + bit] == 1 { b |= 1 << bit; }
                }
                pattern_bytes.push(b);
            }
            let n_check = pattern_bytes.len().min(32);
            for rot in 0..32 {
                let bits_match: usize = pattern_bytes.iter().take(n_check).enumerate()
                    .map(|(i, &b)| (!(b ^ EXPECTED[(i + rot) & 31])).count_ones() as usize)
                    .sum();
                if best.as_ref().map_or(true, |b| bits_match > b.1) {
                    best = Some((rot, bits_match, phase_offset, pattern_bytes.clone()));
                }
            }
        }
    }

    let (best_rot, best_bits, phase_used, best_bytes) =
        best.ok_or("no valid alignment found")?;
    println!("  best phase offset: sample {:.2} ({:.3} fractional slot from first edge)",
        phase_used, (phase_used - phase0_base) / period_est);
    println!("  picked: bit match {}/{} (= {:.1}%)",
        best_bits, best_bytes.len().min(32) * 8,
        100.0 * best_bits as f64 / (best_bytes.len().min(32) * 8).max(1) as f64);
    println!();
    println!("  decoded:  {}", best_bytes.iter().take(32).map(|b| format!("{b:02X}")).collect::<String>());
    println!("  expected: {}", EXPECTED.iter().map(|b| format!("{b:02X}")).collect::<String>());
    println!("  best rotation +{}", best_rot);

    // Bit match across full available window.
    let n_check = best_bytes.len();
    let mut total_match = 0usize;
    let mut total_bits = 0usize;
    for byte_idx in 0..n_check {
        let exp = EXPECTED[(byte_idx + best_rot) & 31];
        let got = best_bytes[byte_idx];
        total_match += (!(exp ^ got)).count_ones() as usize;
        total_bits += 8;
    }
    println!("  bit match across {} bytes: {}/{} ({:.1}%)",
        n_check, total_match, total_bits, 100.0 * total_match as f64 / total_bits as f64);

    Ok(())
}

/// `wire_count_watch [PERIOD_NS]` — continuously captures and decodes counter
/// transmissions, displaying the latest count in the terminal (in-place update).
/// First sync per capture is the real transmission; subsequent syncs in the same
/// capture are filtered as false positives (post-TX idle phase quirks).
fn cmd_wire_count_watch(port_path: &str, args: &[String]) -> Result<(), String> {
    use std::io::Write;
    const TRACE_MAX_SAMPLES: u32 = 8192;
    let period_ns: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(10_000);

    println!("wire_count_watch: listening for FPGA counter (Ctrl-C to stop)");
    println!("  sample period ≈ {} ns, window ≈ {:.1} ms per capture",
        period_ns, (TRACE_MAX_SAMPLES * period_ns) as f64 / 1_000_000.0);
    println!();

    const PATTERN_REF: &[u8; 32] = b"The quick brown fox jumps over t";

    let mut last_byte_idx: Option<u8> = None;
    let mut attempts = 0u64;
    let mut hits = 0u64;
    let mut rejected_garbage = 0u64;
    let start = std::time::Instant::now();

    loop {
        attempts += 1;
        let result = capture_and_decode_counter(port_path, TRACE_MAX_SAMPLES, period_ns, false);
        match result {
            Ok((_period, counts)) => {
                // Filter the syncs: real TX has pattern_byte matching the
                // FPGA's reference pattern at the decoded byte_idx position,
                // and sep byte = 0x00. False syncs typically decode as 0x00 or
                // fail the pattern check.
                let elapsed_s = start.elapsed().as_secs_f64();
                let best = counts.iter().copied().filter(|&c| {
                    // Accept any candidate whose pattern_byte appears anywhere
                    // in the reference pattern AND whose separator byte is 0
                    // (the format invariant). Pad byte is allowed nonzero so
                    // pre-RX-window FPGA bitstreams still display.
                    let pattern_byte = (c & 0xFF) as u8;
                    let sep          = ((c >> 8) & 0xFF) as u8;
                    if sep != 0 { return false; }
                    PATTERN_REF.contains(&pattern_byte)
                }).next();
                if let Some(count) = best {
                    hits += 1;
                    let pattern_byte = (count & 0xFF) as u8;
                    let last_rx_byte = ((count >> 16) & 0xFF) as u8;
                    let byte_idx     = ((count >> 24) & 0x1F) as u8;
                    let printable    = if pattern_byte.is_ascii_graphic() || pattern_byte == b' ' {
                        pattern_byte as char
                    } else { '?' };
                    let delta_marker = match last_byte_idx {
                        Some(last) => {
                            let delta = (byte_idx.wrapping_sub(last)) & 0x1F;
                            if delta == 1 { " ✓ +1".to_string() }
                            else if delta == 0 { " (repeat)".to_string() }
                            else { format!(" (+{delta})") }
                        }
                        None => " (first)".to_string(),
                    };
                    println!(
                        "[{:6.1}s] byte_idx={:2} '{}' (G#{:02X}) rx=G#{:02X}  raw=G#{:08X}  [{}/{} hits, {} rejected]{}",
                        elapsed_s, byte_idx, printable, pattern_byte, last_rx_byte, count,
                        hits, attempts, rejected_garbage, delta_marker
                    );
                    std::io::stdout().flush().ok();
                    last_byte_idx = Some(byte_idx);
                } else if !counts.is_empty() {
                    rejected_garbage += counts.len() as u64;
                }
            }
            Err(_) => {
                // Transient — usually a stale USB frame. Pause briefly + retry.
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// `meal_dump_ira` — read the OTP slot sector (0x100000, 256 bytes) from the
/// FPGA's external SPI flash via openFPGALoader and decode the 8 slots.
///
/// Layout (set by `rtl/otp_persistent.v`):
///   slot 0..3 → IRA (replicated)
///   slot 4..7 → bitwise inverse of IRA (Claim 4 inverted-pair storage)
///
/// Verifies that slots 0..3 are byte-identical and slots 4..7 are the
/// bitwise complement, then prints the IRA. Use this to confirm:
///   1. Ceremony successfully persisted IRA to flash
///   2. IRA survives power cycles (run before + after pulling the cable;
///      the same value should come back)
///   3. `--wipe-slots` correctly erased the sector (all bytes = 0xFF)
fn cmd_meal_dump_ira(args: &[String]) -> Result<(), String> {
    use std::process::Command;

    let offset = args.first()
        .map(|s| {
            let s = s.trim_start_matches("0x").trim_start_matches("G#");
            u32::from_str_radix(s, 16).map_err(|e| format!("bad OFFSET: {e}"))
        })
        .transpose()?
        .unwrap_or(0x100000);

    let tmp_path = "/tmp/pipe_meal_ira_dump.bin";
    println!("meal_dump_ira: reading 256 bytes at flash offset 0x{:06X}", offset);

    let status = Command::new("openFPGALoader")
        .args([
            "-c", "ft232",
            "--dump-flash",
            "--offset", &format!("0x{:X}", offset),
            "--file-size", "256",
            tmp_path,
        ])
        .status()
        .map_err(|e| format!("failed to spawn openFPGALoader: {e}"))?;
    if !status.success() {
        return Err(format!("openFPGALoader exited with {}", status));
    }

    let bytes = std::fs::read(tmp_path)
        .map_err(|e| format!("reading {tmp_path}: {e}"))?;
    if bytes.len() < 256 {
        return Err(format!("dump too short: {} bytes (expected 256)", bytes.len()));
    }

    // Split into 8 slots × 32 bytes
    let mut slots: [[u8; 32]; 8] = [[0u8; 32]; 8];
    for (i, slot) in slots.iter_mut().enumerate() {
        slot.copy_from_slice(&bytes[i * 32..(i + 1) * 32]);
    }

    // Detect VIRGIN state (sector erased — all 0xFF)
    let all_ff = slots.iter().all(|s| s.iter().all(|&b| b == 0xFF));
    if all_ff {
        println!();
        println!("  All 256 bytes = 0xFF → sector erased (VIRGIN state).");
        println!("  FPGA on next boot will be in VIRGIN, ready to provision.");
        return Ok(());
    }

    // Display each slot
    println!();
    for (i, slot) in slots.iter().enumerate() {
        let hex: String = slot.iter().map(|b| format!("{:02X}", b)).collect();
        let label = if i < 4 { "ira (A)" } else { "~ira (B)" };
        println!("  slot[{i}] = {hex}  ({label})");
    }

    // Verify A-slot agreement
    let mut a_agree = true;
    for i in 1..4 {
        if slots[i] != slots[0] {
            println!("  ✗ slot[{i}] (A-replica) does NOT match slot[0]");
            a_agree = false;
        }
    }

    // Verify B-slots are inverse of A-slots
    let mut b_agree = true;
    for i in 4..8 {
        let inv: [u8; 32] = std::array::from_fn(|j| !slots[0][j]);
        if slots[i] != inv {
            println!("  ✗ slot[{i}] (B-replica) is not bitwise-inverse of slot[0]");
            b_agree = false;
        }
    }

    println!();
    if a_agree && b_agree {
        println!("  ✓ all 4 A-slots identical, all 4 B-slots = ~A (Claim 4 inverted-pair OK)");
        let ira_hex: String = slots[0].iter().map(|b| format!("{:02X}", b)).collect();
        println!();
        println!("  IRA = {ira_hex}");
        println!();
        println!("  Persistence test: run this command, pull cable, replug, run again.");
        println!("  IRA must match bit-for-bit. Use --wipe-slots in the build script to");
        println!("  return to VIRGIN and re-provision a fresh IRA via the ceremony.");
    } else {
        println!();
        println!("  ✗ INTEGRITY MISMATCH — slots do not match the expected A/B pattern.");
        println!("    Possible causes: partial burn (FUCKED), wrong flash offset, or");
        println!("    bitstream wrote in an unexpected layout. Try --wipe-slots and");
        println!("    re-provision from scratch.");
    }

    Ok(())
}

/// `meal_challenge <CHALLENGE_HEX> [--expected-ira <IRA_HEX>]`
///
/// Computes the expected challenge-response output for a given (IRA, challenge)
/// pair using the same BLAKE3 keyed-hash invocation `chal_resp_fsm.v`
/// performs on-chip:
///
///   response = blake3::keyed_hash(IRA[32 bytes], challenge[32 bytes])
///
/// When `--expected-ira` is supplied, prints the locally-computed expected
/// response so it can be compared bit-for-bit against the FPGA's wire output
/// (either captured by oscilloscope/logic analyzer or by a future wire-driven
/// verification path — see the bottom of this function for the protocol
/// description).
///
/// IRA derivation paths supported:
///   - v2 baked bitstream: pass the IRA hex that was baked at synthesis time
///   - v1 fresh ceremony: read the 64-hex-char IRA from the OLED's mode 1
///     screen and pass it here
///   - Persistent flash variant: use `meal_dump_ira` to extract IRA from flash
///     and feed the resulting hex into this command
///
/// Wire automation (deferred): driving the 256-bit challenge over PIPE and
/// capturing the response requires a new bridge firmware command since the
/// existing wire-drive primitives operate on single bytes. The chal_resp_fsm
/// protocol is documented in rtl/chal_resp_fsm.v:
///
///   1. Bridge tristates wire (PULLMODE=DOWN → idle LOW)
///   2. Bridge drives wire HIGH briefly to wake FPGA from LISTEN_HI
///   3. Bridge drives wire LOW for ≥3 wire_ticks (RX_SYNC_THRESHOLD)
///   4. Bridge clocks out 256 challenge bits LSB-first per byte, 2 wire_ticks/bit
///   5. Bridge tristates; FPGA runs BLAKE3, then drives wire LOW for 4 ticks
///      (TX_SYNC), then keeps LOW until first 1 in response (Claim 12a
///      leading-zero suppression), then 256 response bits MSB-first 2 ticks/bit,
///      then trailing 1, then tristates
///   6. Bridge samples the trace from sync onward, finds sync, walks past
///      leading zeros to first 1, unpacks 256 bits, returns hex
fn cmd_meal_challenge(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err(
            "meal_challenge <CHALLENGE_HEX> [--expected-ira <IRA_HEX>]\n  \
             CHALLENGE_HEX: 64 hex chars (256 bits)\n  \
             IRA_HEX (optional but recommended): 64 hex chars".to_string()
        );
    }
    let challenge_hex = &args[0];
    let challenge_bytes = parse_hex_256(challenge_hex, "challenge")?;

    // Optional --expected-ira flag
    let mut expected_ira: Option<[u8; 32]> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--expected-ira" => {
                let v = args.get(i + 1).ok_or("--expected-ira needs a value")?;
                expected_ira = Some(parse_hex_256(v, "expected-ira")?);
                i += 2;
            }
            other => return Err(format!("unknown arg: {other}")),
        }
    }

    println!("meal_challenge:");
    println!("  challenge = {challenge_hex}");
    if let Some(ira) = expected_ira {
        let ira_hex: String = ira.iter().map(|b| format!("{:02X}", b)).collect();
        println!("  expected IRA = {ira_hex}");

        // BLAKE3 keyed_hash matches chal_resp_fsm's on-chip invocation:
        //   key = 32-byte IRA, data = 32-byte challenge → 32-byte response
        let response = blake3::keyed_hash(&ira, &challenge_bytes);
        let resp_bytes = response.as_bytes();
        let resp_hex: String = resp_bytes.iter().map(|b| format!("{:02X}", b)).collect();
        println!("  expected response = {resp_hex}");
        println!();
        println!("  This is what the FPGA's PIPE wire MUST emit (MSB first, Claim 12a");
        println!("  framed: leading zeros suppressed up to first 1, then trailing 1).");
        println!("  Capture the wire post-challenge and compare bit-for-bit.");
    } else {
        println!();
        println!("  (No --expected-ira supplied; expected response not computed.)");
        println!("  Provide --expected-ira <IRA_HEX> to get the local BLAKE3 keyed-hash");
        println!("  reference for wire-trace comparison.");
    }
    Ok(())
}

/// Parse a 64-character hex string into a 32-byte (256-bit) array.
fn parse_hex_256(s: &str, what: &str) -> Result<[u8; 32], String> {
    let s = s.trim_start_matches("0x").trim_start_matches("G#");
    if s.len() != 64 {
        return Err(format!("{what} must be 64 hex chars (got {})", s.len()));
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        let hi = hex_nibble(s.as_bytes()[i * 2]).ok_or_else(
            || format!("{what}: bad hex char at position {}", i * 2))?;
        let lo = hex_nibble(s.as_bytes()[i * 2 + 1]).ok_or_else(
            || format!("{what}: bad hex char at position {}", i * 2 + 1))?;
        *byte = (hi << 4) | lo;
    }
    Ok(out)
}

fn hex_nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// `wire_gap_decode [PERIOD_NS]` — proves the bridge can stay locked thru
/// a 4096-wire_clk gap of no edges. FPGA bitstream `top_pipe_gap.v` emits:
///   sync1 (4 LOW) → gap (4096 HIGH, no edges) → sync2 (4 LOW)
/// Bridge captures both syncs in one trace, host estimates wire_clk_period
/// from edges OUTSIDE the gap (idle alternation), then verifies that the
/// distance from sync1_fall to sync2_fall equals (SYNC1_TICKS + GAP_TICKS) ×
/// wire_clk_period within ±1 wire_clk. Pass = the patent claim is empirically
/// demonstrated: 4096-slot timing recovery across a constant-wire interval.
///
/// Default PERIOD_NS = 50000 (50 µs/sample) so 8192 samples ≈ 410 ms covers
/// the ~365 ms burst comfortably without needing a bigger trace buffer.
fn cmd_wire_gap_decode(port_path: &str, args: &[String]) -> Result<(), String> {
    const TRACE_MAX_SAMPLES: u32 = 8192;
    let period_ns: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(50_000);

    let mut params = Vec::with_capacity(8);
    params.extend_from_slice(&TRACE_MAX_SAMPLES.to_le_bytes());
    params.extend_from_slice(&period_ns.to_le_bytes());
    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_trace",
        7,
        vec![("data".to_string(), VsfType::v(b'b', params))],
    )?;
    if resp.is_empty() { return Err("no response (timeout)".into()); }
    let section = parse_resp(&resp)?;
    let data = section.get("data").map_err(|e| format!("missing data: {e}"))?
        .first().and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()), _ => None
        }).ok_or("data field not binary")?;
    if data.len() < 8 { return Err("trace too short".into()); }
    let captured = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let elapsed_us = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as u64;
    let expected_bytes = (captured + 7) >> 3;
    if data.len() < 8 + expected_bytes { return Err("trace truncated".into()); }
    let bits_data = &data[8..8 + expected_bytes];
    let samples: Vec<u8> = (0..captured).map(|i| (bits_data[i >> 3] >> (i & 7)) & 1).collect();
    let actual_period_ns = if captured > 0 { (elapsed_us as f64 * 1000.0) / captured as f64 } else { 0.0 };
    println!("wire_gap_decode: {} samples / {} µs ({:.0} ns/sample, total {:.0} ms)",
        captured, elapsed_us, actual_period_ns, elapsed_us as f64 / 1000.0);

    // Find ALL LOW runs longer than a single sample (= candidate sync regions).
    let mut low_runs: Vec<(usize, usize, usize)> = Vec::new(); // (start, end, length)
    let mut i = 0;
    while i < samples.len() {
        if samples[i] == 0 {
            let mut j = i;
            while j < samples.len() && samples[j] == 0 { j += 1; }
            low_runs.push((i, j, j - i));
            i = j;
        } else { i += 1; }
    }
    println!("  found {} LOW runs in trace", low_runs.len());

    // Compute all edge positions for regression-based clock recovery later.
    let edges: Vec<usize> = (1..samples.len()).filter(|&i| samples[i] != samples[i-1]).collect();
    if edges.len() < 30 { return Err(format!("only {} edges in trace", edges.len())); }

    // FPGA's per-burst structure: SYNC1_TICKS LOW → GAP_TICKS HIGH → SYNC2_TICKS LOW.
    // The sync1→sync2 falling-edge distance is exactly SYNC1_TICKS + GAP_TICKS
    // wire_clks (sync2 fires SYNC1_TICKS + GAP_TICKS wire_clks after sync1).
    const SYNC1_TICKS: usize = 8;
    const GAP_TICKS:   usize = 4096;
    const EXPECTED_WIRE_CLKS: usize = SYNC1_TICKS + GAP_TICKS;  // 4104

    // Find the two syncs: LOW runs longer than 5 samples (= ~5.5 wire_clks
    // at the bridge's 79 µs sample rate vs 89 µs wire_clk). Real syncs are
    // 8 wire_clks ≈ 9 samples; idle alternation is single-sample LOWs.
    let sync_min_samples = 5usize;
    let candidate_syncs: Vec<(usize, usize, usize)> = low_runs.iter()
        .filter(|&&(_, _, len)| len >= sync_min_samples)
        .copied().collect();
    println!("  sync-length filter: {} LOW runs with ≥{} samples ({:.0} ns)",
        candidate_syncs.len(), sync_min_samples, sync_min_samples as f64 * actual_period_ns);
    for (idx, &(s, e, len)) in candidate_syncs.iter().enumerate() {
        println!("    sync candidate #{}: samples [{}..{}], len={}", idx, s, e, len);
    }

    if candidate_syncs.len() < 2 {
        return Err(format!("need at least 2 syncs to measure gap; found {}", candidate_syncs.len()));
    }
    let sync1_fall = candidate_syncs[0].0;
    let sync2_fall = candidate_syncs.last().unwrap().0;
    let measured_distance = sync2_fall - sync1_fall;

    // Estimate wire_clk_period via linear regression on idle-alternation
    // edges BEFORE sync1. Each edge is exactly 1 wire_clk apart in idle.
    // Regression: edge_pos[i] = phase0 + i × wire_clk_period → least-squares
    // fit gives a sub-sample-resolution period that beats integer median.
    let idle_edges: Vec<f64> = edges.iter()
        .filter(|&&e| e < sync1_fall)
        .map(|&e| e as f64)
        .collect();
    if idle_edges.len() < 20 {
        return Err(format!("only {} idle edges before sync1 (need ≥20 for clean regression)",
            idle_edges.len()));
    }
    let n = idle_edges.len() as f64;
    let sum_i: f64 = (0..idle_edges.len()).map(|i| i as f64).sum();
    let sum_x: f64 = idle_edges.iter().sum();
    let sum_ii: f64 = (0..idle_edges.len()).map(|i| (i*i) as f64).sum();
    let sum_ix: f64 = idle_edges.iter().enumerate().map(|(i, &x)| i as f64 * x).sum();
    let period_est = (n * sum_ix - sum_i * sum_x) / (n * sum_ii - sum_i * sum_i);
    let period_est_ns = period_est * actual_period_ns;
    println!();
    println!("  wire_clk_period (linear regression on {} idle edges before sync1):",
        idle_edges.len());
    println!("    {:.4} samples = {:.1} ns/wire_clk", period_est, period_est_ns);

    let predicted_distance = EXPECTED_WIRE_CLKS as f64 * period_est;
    let drift_samples = measured_distance as f64 - predicted_distance;
    let drift_wire_clks = drift_samples / period_est;
    let drift_ppm = drift_wire_clks / EXPECTED_WIRE_CLKS as f64 * 1_000_000.0;

    println!();
    println!("  sync1 falling edge: sample {}", sync1_fall);
    println!("  sync2 falling edge: sample {}", sync2_fall);
    println!("  measured distance:  {} samples", measured_distance);
    println!("  predicted distance: {} × {:.4} = {:.2} samples (4104 wire_clks)",
        EXPECTED_WIRE_CLKS, period_est, predicted_distance);
    println!("  drift:              {:+.3} samples = {:+.4} wire_clks = {:+.1} ppm",
        drift_samples, drift_wire_clks, drift_ppm);

    if drift_wire_clks.abs() < 1.0 {
        println!();
        println!("  ✓ PASS — clock recovery held thru 4096-slot gap (drift < 1 wire_clk)");
        println!("  → Patent claim demonstrated: PIPE line code tolerates 4096 wire_clks of");
        println!("    constant-wire state without losing slot phase.");
    } else if drift_wire_clks.abs() < 2.0 {
        println!();
        println!("  △ MARGINAL — drift in [1, 2) wire_clks (likely sample-quantization noise)");
    } else {
        println!();
        println!("  ✗ FAIL — drifted {:.2} wire_clks across the gap (too much for slot lock)",
            drift_wire_clks);
    }

    Ok(())
}

/// `wire_4096_decode [PERIOD_NS]` — captures a single 4096-bit TX burst
/// from `top_pipe_4096.v` and decodes all 4096 bits. Reports first drift
/// position (= first bit that disagrees with the expected pattern cycled 16×).
///
/// Buffer math: 65536 samples × ~16 µs = ~1.05 s, fits the FPGA's ~730 ms
/// burst with margin. wire_clk ≈ 89 µs, so each bit ≈ 178 µs ≈ 11 samples.
fn cmd_wire_4096_decode(port_path: &str, args: &[String]) -> Result<(), String> {
    const TRACE_MAX_SAMPLES: u32 = 65536;
    let period_ns: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(10_000);

    let mut params = Vec::with_capacity(8);
    params.extend_from_slice(&TRACE_MAX_SAMPLES.to_le_bytes());
    params.extend_from_slice(&period_ns.to_le_bytes());
    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_trace",
        7,
        vec![("data".to_string(), VsfType::v(b'b', params))],
    )?;
    if resp.is_empty() { return Err("no response (timeout)".into()); }
    let section = parse_resp(&resp)?;
    let data = section.get("data").map_err(|e| format!("missing data: {e}"))?
        .first().and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()), _ => None
        }).ok_or("data field not binary")?;
    if data.len() < 8 { return Err("trace too short".into()); }
    let captured = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let elapsed_us = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as u64;
    let expected_bytes = (captured + 7) >> 3;
    if data.len() < 8 + expected_bytes { return Err("trace truncated".into()); }
    let bits_data = &data[8..8 + expected_bytes];
    let samples: Vec<u8> = (0..captured).map(|i| (bits_data[i >> 3] >> (i & 7)) & 1).collect();
    let actual_period_ns = if captured > 0 { (elapsed_us as f64 * 1000.0) / captured as f64 } else { 0.0 };
    println!("wire_4096_decode: {} samples / {} µs ({:.0} ns/sample, total {:.0} ms)",
        captured, elapsed_us, actual_period_ns, elapsed_us as f64 / 1000.0);

    let edges: Vec<usize> = (1..samples.len()).filter(|&i| samples[i] != samples[i-1]).collect();
    if edges.len() < 50 { return Err(format!("only {} edges", edges.len())); }

    // Estimate wire_clk_period from median of pre-sync intervals (idle).
    let intervals: Vec<usize> = edges.windows(2).map(|w| w[1] - w[0]).collect();
    let mut sorted = intervals.clone();
    sorted.sort_unstable();
    let median = sorted[sorted.len() / 2] as f64;
    println!("  median inter-edge interval: {:.2} samples ({:.1} ns)",
        median, median * actual_period_ns);

    // Find sync: LOW run > 1.5 × median, < 4 × median.
    let sync_min = (median * 1.5) as usize;
    let sync_max = (median * 4.0) as usize;
    let mut sync_end: Option<usize> = None;
    let mut i = 1;
    while i < samples.len() {
        if samples[i] == 0 && samples[i - 1] == 1 {
            let mut j = i;
            while j < samples.len() && samples[j] == 0 { j += 1; }
            let run_len = j - i;
            if run_len > sync_min && run_len <= sync_max && j < samples.len() {
                sync_end = Some(j);
                break;
            }
            i = j + 1;
        } else { i += 1; }
    }
    let sync_end = sync_end.ok_or_else(|| "no sync found".to_string())?;
    println!("  sync detected at sample {}", sync_end);

    // Lock period using edges WITHIN the data burst, AFTER the sync. Use a
    // P-controller over those edges — this is the long-window clock recovery
    // that the 4096-bit test exists to validate.
    const N_DATA_BITS: u32 = 4096;
    const SAMPLES_PER_BIT_NOMINAL: f64 = 2.0; // (2 wire_clks per bit, median = 1 wire_clk)
    let nominal_bit_period = median * SAMPLES_PER_BIT_NOMINAL;
    println!("  nominal bit period: {:.2} samples ({:.1} ns)",
        nominal_bit_period, nominal_bit_period * actual_period_ns);

    // Refine period using edges in the data window. P-loop over edges that
    // are within ±25% of median (= wire_clk-spaced edges, not stretched).
    let k_p = 0.01f64;
    let mut period_est = median;
    let mut phase_ref = sync_end as f64;
    let burst_end_samples = sync_end + (N_DATA_BITS as usize * 2) * (median as usize + 1);
    let burst_end_clamped = burst_end_samples.min(samples.len());
    let mut accepted = 0usize;
    let mut rejected = 0usize;
    for &edge in edges.iter().filter(|&&e| e > sync_end && e < burst_end_clamped) {
        let actual = edge as f64;
        let error = actual - (phase_ref + period_est);
        if error.abs() <= 0.25 * median {
            period_est += k_p * error;
            accepted += 1;
        } else {
            rejected += 1;
        }
        phase_ref = actual;
    }
    println!("  P-loop on data edges: {} accepted, {} rejected; period_est = {:.4} samples ({:.1} ns/wire_clk)",
        accepted, rejected, period_est, period_est * actual_period_ns);

    // Expected pattern: 256-bit reference cycled 16 times = 4096 bits.
    const PATTERN_REF: &[u8; 32] = b"The quick brown fox jumps over t";
    // Pattern bit N = bit (N%8) of PATTERN_REF[(N/8) % 32], LSB-first.
    let expected_bit = |n: u32| -> u8 {
        let byte_pos = (n / 8) as usize & 31;
        let bit_pos = (n % 8) as usize;
        (PATTERN_REF[byte_pos] >> bit_pos) & 1
    };

    // Decode: bit N at sync_end + (2N + 1.5) × period_est.
    let mut decoded = vec![0u8; N_DATA_BITS as usize];
    let mut first_dropout: Option<usize> = None;
    for n in 0..N_DATA_BITS as usize {
        let off = ((2.0 * n as f64 + 1.5) * period_est).round() as usize;
        let pos = sync_end + off;
        if pos >= samples.len() {
            if first_dropout.is_none() { first_dropout = Some(n); }
            break;
        }
        decoded[n] = samples[pos];
    }

    // Compare against expected, count matches + locate first drift.
    let mut matches = 0u32;
    let mut first_drift: Option<usize> = None;
    let mut errors_per_kbit = [0u32; 4];
    for n in 0..N_DATA_BITS as usize {
        if decoded[n] == expected_bit(n as u32) {
            matches += 1;
        } else if first_drift.is_none() {
            first_drift = Some(n);
        } else {
            errors_per_kbit[n / 1024] += 1;
        }
    }
    if let Some(first) = first_drift { errors_per_kbit[first / 1024] += 1; }
    let max_n_decoded = first_dropout.unwrap_or(N_DATA_BITS as usize);

    println!();
    println!("  decoded {} / {} bits", max_n_decoded, N_DATA_BITS);
    println!("  bit-exact matches: {}/{} ({:.2}%)",
        matches, N_DATA_BITS,
        100.0 * matches as f64 / N_DATA_BITS as f64);
    if let Some(first) = first_drift {
        println!("  first drift at bit {} (= within kbit window {})", first, first / 1024);
    } else {
        println!("  ✓ ALL 4096 BITS LANDED — clock recovery held thru full burst");
    }
    println!("  errors per kbit window: [0..1024]={}  [1024..2048]={}  [2048..3072]={}  [3072..4096]={}",
        errors_per_kbit[0], errors_per_kbit[1], errors_per_kbit[2], errors_per_kbit[3]);

    // Spot check: print first 32 and last 32 decoded bits as bytes for sanity.
    let pack_bytes = |start: usize, n_bytes: usize| -> String {
        let mut s = String::new();
        for b in 0..n_bytes {
            let mut byte = 0u8;
            for bit in 0..8 {
                let idx = start + b * 8 + bit;
                if idx < decoded.len() && decoded[idx] != 0 { byte |= 1 << bit; }
            }
            s.push_str(&format!("{:02X} ", byte));
        }
        s
    };
    let expected_pack = |start: usize, n_bytes: usize| -> String {
        let mut s = String::new();
        for b in 0..n_bytes {
            let mut byte = 0u8;
            for bit in 0..8 {
                let n = start + b * 8 + bit;
                if expected_bit(n as u32) != 0 { byte |= 1 << bit; }
            }
            s.push_str(&format!("{:02X} ", byte));
        }
        s
    };
    println!();
    println!("  first 32 bytes (256 bits) decoded:  {}", pack_bytes(0, 32));
    println!("  first 32 bytes expected:           {}", expected_pack(0, 32));
    println!("  last 32 bytes  (256 bits) decoded:  {}", pack_bytes(4096 - 256, 32));
    println!("  last 32 bytes  expected:           {}", expected_pack(4096 - 256, 32));

    Ok(())
}

/// `wire_count_drive [BYTE [SAMPLES [PERIOD_NS]]]` — bidirectional round-trip
/// test. Bridge detects the FPGA's next sync, waits for the 32-bit data
/// phase to finish, drives BYTE LSB-first during the FPGA's RX window, then
/// captures the post-drive trace. Host decodes the captured trace and
/// reports whether the FPGA's `last_rx_byte` field echoes BYTE.
///
/// Default BYTE = 0xFF (drives wire HIGH all 8 bits); SAMPLES = 8192;
/// PERIOD_NS = 10000.
fn cmd_wire_count_drive(port_path: &str, args: &[String]) -> Result<(), String> {
    const TRACE_MAX_SAMPLES: u32 = 8192;
    let byte_to_drive: u8 = args.first()
        .map(|s| u32::from_str_radix(s.trim_start_matches("0x").trim_start_matches("G#"), 16)
            .or_else(|_| s.parse::<u32>())
            .map_err(|e| format!("bad BYTE: {e}")))
        .transpose()?
        .map(|v| v as u8)
        .unwrap_or(0xFFu8);
    let samples_req: u32 = args.get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SAMPLES: {e}")))
        .transpose()?
        .unwrap_or(TRACE_MAX_SAMPLES)
        .clamp(1, TRACE_MAX_SAMPLES);
    let period_ns: u32 = args.get(2)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad PERIOD_NS: {e}")))
        .transpose()?
        .unwrap_or(10_000);

    let mut params = Vec::with_capacity(9);
    params.push(byte_to_drive);
    params.extend_from_slice(&samples_req.to_le_bytes());
    params.extend_from_slice(&period_ns.to_le_bytes());
    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_count_drive",
        7,
        vec![("data".to_string(), VsfType::v(b'b', params))],
    )?;
    if resp.is_empty() { return Err("no response (timeout)".into()); }
    let section = parse_resp(&resp)?;
    let data = section.get("data").map_err(|e| format!("missing data: {e}"))?
        .first().and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()), _ => None
        }).ok_or("data field not binary")?;
    if data.len() < 12 { return Err(format!("response too short: {} bytes", data.len())); }
    let captured_field = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    let elapsed_us = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as u64;
    let byte_driven = data[8];
    let captured = (captured_field & 0x7FFF_FFFF) as usize;
    let sync_found = (captured_field >> 31) & 1;
    let expected_bytes = (captured + 7) >> 3;
    if data.len() < 12 + expected_bytes {
        return Err(format!("trace truncated: have {}, want {}", data.len(), 12 + expected_bytes));
    }
    let bits = &data[12..12 + expected_bytes];
    let samples: Vec<u8> = (0..captured).map(|i| (bits[i >> 3] >> (i & 7)) & 1).collect();
    let actual_period_ns = if captured > 0 { (elapsed_us as f64 * 1000.0) / captured as f64 } else { 0.0 };

    println!("wire_count_drive: drove G#{byte_driven:02X}, sync_found={sync_found}, {captured} samples / {elapsed_us} µs ({actual_period_ns:.0} ns/sample)");
    if sync_found == 0 {
        println!("  no sync detected within 100ms — FPGA may be idling or unflashed");
        return Ok(());
    }

    let edges: Vec<usize> = (1..samples.len()).filter(|&i| samples[i] != samples[i-1]).collect();
    if edges.len() < 20 {
        println!("  only {} edges in capture — degenerate trace", edges.len());
        return Ok(());
    }

    // Same decoder as capture_and_decode_counter.
    let intervals: Vec<usize> = edges.windows(2).map(|w| w[1] - w[0]).collect();
    let mut sorted = intervals.clone();
    sorted.sort_unstable();
    let median = sorted[sorted.len() / 2] as f64;
    let k_p = 0.05f64;
    let mut period_est = median;
    let mut phase_ref = edges[0] as f64;
    for &edge in &edges[1..] {
        let actual = edge as f64;
        let error = actual - (phase_ref + period_est);
        if error.abs() <= 0.25 * median {
            period_est += k_p * error;
        }
        phase_ref = actual;
    }
    let sync_min = (period_est * 1.5) as usize;
    let sync_max = (period_est * 4.0) as usize;
    let mut syncs: Vec<usize> = Vec::new();
    let mut i = 1;
    while i < samples.len() {
        if samples[i] == 0 && samples[i-1] == 1 {
            let mut j = i;
            while j < samples.len() && samples[j] == 0 { j += 1; }
            let run_len = j - i;
            if run_len > sync_min && run_len <= sync_max && j < samples.len() {
                syncs.push(j);
            }
            i = j + 1;
        } else { i += 1; }
    }

    const PATTERN_REF: &[u8; 32] = b"The quick brown fox jumps over t";
    let mut matches = 0usize;
    let mut total = 0usize;
    for (idx, &sync_end) in syncs.iter().enumerate() {
        let mut count: u32 = 0;
        let mut decoded = 0u32;
        for n in 0..32u32 {
            let off = ((2.0 * n as f64 + 1.5) * period_est).round() as usize;
            let pos = sync_end + off;
            if pos >= samples.len() { break; }
            if samples[pos] != 0 { count |= 1u32 << n; }
            decoded += 1;
        }
        if decoded < 32 { continue; }
        let pattern_byte = (count & 0xFF) as u8;
        let last_rx = ((count >> 16) & 0xFF) as u8;
        let byte_idx = ((count >> 24) & 0x1F) as u8;
        let pat_expected = PATTERN_REF[byte_idx as usize & 31];
        let pat_ok = pattern_byte == pat_expected;
        let rx_ok = last_rx == byte_driven;
        total += 1;
        if rx_ok { matches += 1; }
        let printable = if pattern_byte.is_ascii_graphic() || pattern_byte == b' ' {
            pattern_byte as char
        } else { '?' };
        println!(
            "  sync #{}: byte_idx={:2} pattern=G#{:02X} '{}' last_rx=G#{:02X}  {} pattern={}  rx_echo={}",
            idx, byte_idx, pattern_byte, printable, last_rx,
            if pat_ok { "✓" } else { "✗" }, if pat_ok { "match" } else { "MISMATCH" },
            if rx_ok { format!("✓ G#{last_rx:02X} == G#{byte_driven:02X}") } else { format!("✗ G#{last_rx:02X} != G#{byte_driven:02X}") }
        );
    }
    if total > 0 {
        println!("\nround-trip echo: {matches}/{total} syncs carried last_rx = G#{byte_driven:02X}");
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
/// Decoded `wire_sync` response. Mirrors the firmware's `SyncResult` layout (see
/// pipe-bridge-rp2040/src/main.rs `fast_sync`), one-shot parsed so both cmd_wire_sync
/// (which pretty-prints a single run) and cmd_tune_p (which sweeps across p_shift)
/// can use the same byte layout.
#[allow(dead_code)]
struct SyncResultParsed {
    elapsed_us: u64,
    total_iter: u64,
    status: u32,
    frac_bits: u32,
    p_shift: u32,
    locked: bool,
    edges_to_lock: u32,
    /// Seed slot in SYSTICK cycles (8 ns each at 125 MHz). Keeping the historical
    /// `iter` suffix here only because the on-wire byte name didn't change; the unit
    /// is now cycles. With the dual tracker this is the average of the two polarity
    /// seeds; per-polarity seeds are below.
    acquisition_slot_iter: u32,
    final_interval_fp: u32,
    /// Per-polarity acquisition seeds and final interval_fp values. With RC asymmetry
    /// (HIGH ≠ LOW widths) these diverge: rise tracks HIGH-side period, fall tracks LOW.
    acquisition_slot_cyc_rise: u32,
    acquisition_slot_cyc_fall: u32,
    final_interval_fp_rise: u32,
    final_interval_fp_fall: u32,
    acquisition_iter_count: u32,
    measurement_iter_count: u32,
    acq_rising: u32,
    acq_falling: u32,
    rising_total: u32,
    falling_total: u32,
    rising_neg_overflow: u32,
    rising_pos_overflow: u32,
    falling_neg_overflow: u32,
    falling_pos_overflow: u32,
    hist_bins: usize,
    hist_half_range: i32,
    phase_sum: i64,
    /// RX bit decode appendix (firmware: ferros-bridge fast_sync). Empty/zero on
    /// firmware that predates the appendix.
    bits_buffer: u64,
    bits_decoded: u32,
    /// Mirror-mode appendix: count of 32-bit TX words pushed to SM1 FIFO during
    /// the run (32 host slots per word). 0 outside mirror mode or on older firmware.
    tx_words_consumed: u32,
    /// Final phase_err EMA values (per polarity, SYSTICK cycles). |EMA| <= 16 cyc
    /// (= SYNC_LOCK_EMA_THRESHOLD_CYC) means locked.
    phase_err_ema_rise: i32,
    phase_err_ema_fall: i32,
    /// PERIOD tracker (rise-to-rise = HIGH + LOW). Drift-stable frequency reference.
    /// The actual lock signal — locked = (|phase_err_ema_period|.abs() <= 16 cyc).
    acquisition_slot_cyc_period: u32,
    final_interval_fp_period: u32,
    phase_err_ema_period: i32,
    /// Period diagnostic histogram. 17 bins of width = seed/8 covering [0, 2×seed).
    /// Bin 8 = seed, bin 4 = seed/2 (missed-edge suspect), bin 16 = ≥2×seed overflow.
    /// Sampled BEFORE the cascade window check so glitches are visible. Empty Vec
    /// on firmware that predates the appendix.
    period_hist: Vec<u32>,
    /// PERIOD sanity-check: sum of every period_now value that contributed to the
    /// histogram, plus count + min + max. `period_sum × 8 ns` should equal the
    /// tracking-phase wall time; if not, the histogram is missing samples.
    period_sum: i64,
    period_sample_count: u32,
    period_min: i32,
    period_max: i32,
    /// Slow EMA of period_now (α = 1/1024) reported in fp form (same frac_bits
    /// scaling as final_interval_fp_period). This is the long-term-stable wire
    /// period estimate — use it (not the live P-controller output) as the
    /// "predicted period at start of silence" for silence-budget calculations.
    period_ema_slow_fp: u32,
    /// Phase 2c: bridge-side decode of FPGA's TX bits. Rolling LSB-first u32 buffer
    /// of FPGA bits decoded per Claim 12 inverse. After 32+ enclave-slot crossings
    /// with FPGA in DATA mode, equals a rotation of the FPGA's TX_PATTERN. In wire_sync
    /// or pre-handshake mirror runs, expect 0 (FPGA stays in IDLE → drives 0).
    fpga_decoded_buffer: u32,
    /// Total enclave-slot crossings that decoded a bit (mirror mode only; 0 in wire_sync).
    fpga_decoded_count: u32,
    /// Mirror-mode edge filter counters. Sum = post-acquisition edges processed by the
    /// filter. Healthy: accepted >> rejected. Diagnostic for decode regressions —
    /// high mid_slot means CDR phase drifted; high wrong_polarity means slot_phase
    /// parity or tx_shift_reg got out of lockstep with SM1.
    mirror_edges_accepted: u32,
    mirror_edges_rejected_mid_slot: u32,
    mirror_edges_rejected_wrong_polarity: u32,
    /// Claim-12-aware polarity prediction model: how often the new model's
    /// prediction matched (or didn't match) the observed edge. ADVISORY: the
    /// firmware counts but doesn't yet use this prediction for accept_for_cdr.
    /// If `claim12_match` dominates over the two mispredict counters, the new
    /// model is correct and can replace the old slotted_oled-tuned check.
    mirror_claim12_match: u32,
    mirror_claim12_mispredict_no_edge_observed: u32,
    mirror_claim12_mispredict_wrong_polarity: u32,
    /// Raw wire-state-per-slot diagnostic: up to 256 bits captured at the FIRST 256
    /// slot boundaries crossed after mirror_started. LSB-first within bytes. Bit 0
    /// = wire at first boundary (entering host slot 1 from initial enclave slot 0),
    /// bit 1 = wire at second boundary (entering enclave slot 2), etc.
    slot_wire_log: [u8; 32],
    slot_wire_log_count: u32,
    /// FPGA-decoded-bits log: up to 256 bits captured at the FIRST 256 enclave-slot
    /// crossings after `mirror_started`. Each bit is `1 ^ last_driven_bit ^ wire_at_slot`
    /// at that boundary — the bridge's belief about the FPGA's TX bit for that slot.
    /// LSB-first within bytes. Host verifies bit-exact match against all 256 rotations
    /// of FPGA_TX_PATTERN_256.
    fpga_decoded_log: [u8; 32],
    fpga_decoded_log_count: u32,
    /// Diagnostic: per-edge slots_crossed >SLOTS_CROSSED_MAX events. Non-zero =
    /// slot_phase parity drifted by however many slots got clamped (drift cascades
    /// from there).
    edges_slots_crossed_capped: u32,
    /// Diagnostic: largest pre-clamp slots_crossed observed in this run.
    max_observed_slots_crossed: u32,
    /// Diagnostic: edges in the parity-ambiguous zone where slot_phase update was
    /// skipped. Each is a potential parity flip avoided.
    edges_parity_ambiguous_skipped: u32,
    /// Raw own_cyc capture: snapshot of slot_cyc at capture start, count of entries
    /// written into raw_own_cyc_log, and the log itself. Each entry is a single edge's
    /// PIO-measured inter-edge interval (2 × !X cycles). Captured for the first 256
    /// edges after mirror_started. Ground truth for slot tracker analysis.
    raw_own_cyc_slot_cyc: u32,
    raw_own_cyc_count: u32,
    raw_own_cyc_log: Vec<u32>,
    /// Ring buffer of LAST 256 decoded enclave-slot bits. Bit at ring position
    /// `K % 256` corresponds to slot index K. Combined with `fpga_decoded_count`,
    /// host linearises to get the most recent 256 bits in slot order.
    fpga_decoded_late_log: [u8; 32],
    /// Most recent 256 edge intervals' raw own_cyc values (ring buffer).
    /// late_raw_own_cyc_count = total edges seen post-mirror-start; ring at
    /// position (late_raw_own_cyc_count - 1) % 256 holds the most recent edge.
    late_raw_own_cyc_count: u32,
    late_raw_own_cyc_log: Vec<u32>,
    fall_to_rise_offset_sum: i64,
    rise_to_fall_offset_sum: i64,
    rising_hist: Vec<u16>,
    falling_hist: Vec<u16>,
}

/// Run one `wire_sync` round on the bridge with the given parameters, parse the
/// response blob into a `SyncResultParsed`. Layout matches firmware exactly: 18 × u32
/// + 3 × i64 + 2 × hist_bins × u16.
fn run_wire_sync(
    port_path: &str,
    max_iter: u32,
    frac_bits: u32,
    settle_iter: u32,
    p_shift: u32,
) -> Result<SyncResultParsed, String> {
    run_wire_sync_full(port_path, max_iter, frac_bits, settle_iter, p_shift, 0, 1)
}

/// Same as run_wire_sync but appends a 32-bit TX pattern that the bridge drives onto
/// GP0 via PIO TX during the capture. tx_pattern=0 disables TX (identical to
/// run_wire_sync). Used by cmd_wire_loopback to validate the TX path with the
/// bridge's own PIO RX as the verification end.
#[allow(dead_code)]
fn run_wire_sync_with_tx(
    port_path: &str,
    max_iter: u32,
    frac_bits: u32,
    settle_iter: u32,
    p_shift: u32,
    tx_pattern: u32,
) -> Result<SyncResultParsed, String> {
    run_wire_sync_full(port_path, max_iter, frac_bits, settle_iter, p_shift, tx_pattern, 1)
}

/// Full-parameter version that includes cascade_mode for the firmware's n_slots
/// gating: 0 = force n_slots=1 (clean-toggle / mirror-XOR / single-interval data,
/// any out-of-window edge dropped as glitch); 1 = enable the n=1..4 cascade for
/// real multi-slot data (LFSR / random). Old callers via run_wire_sync /
/// run_wire_sync_with_tx default to 1 (preserves original behaviour).
fn run_wire_sync_full(
    port_path: &str,
    max_iter: u32,
    frac_bits: u32,
    settle_iter: u32,
    p_shift: u32,
    tx_pattern: u32,
    cascade_mode: u32,
) -> Result<SyncResultParsed, String> {
    let mut params = Vec::with_capacity(24);
    params.extend_from_slice(&max_iter.to_le_bytes());
    params.extend_from_slice(&frac_bits.to_le_bytes());
    params.extend_from_slice(&settle_iter.to_le_bytes());
    params.extend_from_slice(&p_shift.to_le_bytes());
    // tx_pattern always emitted when cascade_mode is non-default so the bridge sees
    // both fields contiguously. When cascade_mode is the default 1 AND tx_pattern is
    // 0, we can drop both for backward compat with old firmware (which expects 20-byte
    // or 16-byte params and stops there).
    let include_tx = tx_pattern != 0 || cascade_mode != 1;
    if include_tx {
        params.extend_from_slice(&tx_pattern.to_le_bytes());
    }
    if cascade_mode != 1 {
        params.extend_from_slice(&cascade_mode.to_le_bytes());
    }

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
    const SCALAR_BYTES: usize = 24 * 4 + 3 * 8; // 120
    if data.len() < SCALAR_BYTES {
        return Err(format!("sync response too short: {} bytes (want >= {SCALAR_BYTES} scalar header)", data.len()));
    }
    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let gi64 = |off: usize| i64::from_le_bytes([
        data[off], data[off+1], data[off+2], data[off+3],
        data[off+4], data[off+5], data[off+6], data[off+7],
    ]);
    let g16 = |off: usize| u16::from_le_bytes([data[off], data[off+1]]);

    let hist_bins = g32(92) as usize;
    let hist_off = SCALAR_BYTES;
    let hist_bytes = hist_bins * 2;
    if data.len() < hist_off + 2 * hist_bytes {
        return Err(format!(
            "sync response truncated: have {} bytes, need {} (scalars + 2 × {} bins)",
            data.len(), hist_off + 2 * hist_bytes, hist_bins,
        ));
    }
    let rising_hist: Vec<u16> = (0..hist_bins).map(|i| g16(hist_off + i * 2)).collect();
    let falling_hist: Vec<u16> = (0..hist_bins).map(|i| g16(hist_off + hist_bytes + i * 2)).collect();
    // RX bit decode appendix: u64 bits_buffer + u32 bits_decoded immediately after the
    // two histograms. Older firmware doesn't include it; default to 0 in that case.
    let appendix_off = hist_off + 2 * hist_bytes;
    let (bits_buffer, bits_decoded) = if data.len() >= appendix_off + 12 {
        let b = u64::from_le_bytes([
            data[appendix_off],     data[appendix_off + 1],
            data[appendix_off + 2], data[appendix_off + 3],
            data[appendix_off + 4], data[appendix_off + 5],
            data[appendix_off + 6], data[appendix_off + 7],
        ]);
        (b, g32(appendix_off + 8))
    } else {
        (0, 0)
    };
    // Mirror-mode appendix: u32 tx_words_consumed immediately after bits_decoded.
    // Backward compatible — older firmware or non-mirror runs default to 0.
    let tx_words_consumed = if data.len() >= appendix_off + 16 {
        g32(appendix_off + 12)
    } else {
        0
    };
    // EMA appendix: i32 phase_err_ema_rise, i32 phase_err_ema_fall after tx_words_consumed.
    let (phase_err_ema_rise, phase_err_ema_fall) = if data.len() >= appendix_off + 24 {
        let r = i32::from_le_bytes([
            data[appendix_off + 16], data[appendix_off + 17],
            data[appendix_off + 18], data[appendix_off + 19],
        ]);
        let f = i32::from_le_bytes([
            data[appendix_off + 20], data[appendix_off + 21],
            data[appendix_off + 22], data[appendix_off + 23],
        ]);
        (r, f)
    } else {
        (0, 0)
    };
    // PERIOD appendix: u32 seed, u32 fp value, i32 EMA, after the per-polarity EMAs.
    let (acquisition_slot_cyc_period, final_interval_fp_period, phase_err_ema_period) =
        if data.len() >= appendix_off + 36 {
            let seed = g32(appendix_off + 24);
            let fp = g32(appendix_off + 28);
            let ema = i32::from_le_bytes([
                data[appendix_off + 32], data[appendix_off + 33],
                data[appendix_off + 34], data[appendix_off + 35],
            ]);
            (seed, fp, ema)
        } else {
            (0, 0, 0)
        };
    // Period histogram appendix: 17 × u32 immediately after phase_err_ema_period.
    // Layout must match firmware PERIOD_HIST_BINS constant.
    const PERIOD_HIST_BINS: usize = 17;
    let period_hist_off = appendix_off + 36;
    let period_hist: Vec<u32> = if data.len() >= period_hist_off + PERIOD_HIST_BINS * 4 {
        (0..PERIOD_HIST_BINS).map(|i| g32(period_hist_off + i * 4)).collect()
    } else {
        Vec::new()
    };
    // PERIOD sanity-check appendix: i64 sum + u32 count + i32 min + i32 max.
    let sanity_off = period_hist_off + PERIOD_HIST_BINS * 4;
    let (period_sum, period_sample_count, period_min, period_max) = if data.len() >= sanity_off + 20 {
        let sum = gi64(sanity_off);
        let count = g32(sanity_off + 8);
        let mn = i32::from_le_bytes([data[sanity_off+12], data[sanity_off+13], data[sanity_off+14], data[sanity_off+15]]);
        let mx = i32::from_le_bytes([data[sanity_off+16], data[sanity_off+17], data[sanity_off+18], data[sanity_off+19]]);
        (sum, count, mn, mx)
    } else {
        (0, 0, 0, 0)
    };
    // Slow EMA appendix: u32 fp value (same frac_bits scaling as final_interval_fp_period).
    let slow_ema_off = sanity_off + 20;
    let period_ema_slow_fp = if data.len() >= slow_ema_off + 4 {
        g32(slow_ema_off)
    } else { 0 };
    // Phase 2c decode appendix: u32 LSB-first FPGA decode buffer + u32 enclave-slot
    // count. Backward compatible — wire_sync's payload doesn't include them (this is
    // the wire_mirror appendix), and older firmware that doesn't surface them returns
    // a shorter payload → both fields default to 0.
    let decode_off = slow_ema_off + 4;
    let (fpga_decoded_buffer, fpga_decoded_count) = if data.len() >= decode_off + 8 {
        (g32(decode_off), g32(decode_off + 4))
    } else { (0, 0) };
    // Mirror-mode filter counters appendix (3 × u32). Same backward-compat rule —
    // older firmware that doesn't surface these returns a shorter payload → all 0.
    let filter_off = decode_off + 8;
    let (mirror_edges_accepted, mirror_edges_rejected_mid_slot, mirror_edges_rejected_wrong_polarity) =
        if data.len() >= filter_off + 12 {
            (g32(filter_off), g32(filter_off + 4), g32(filter_off + 8))
        } else { (0, 0, 0) };
    // Claim-12-aware polarity model advisory counters (3 × u32).
    let claim12_off = filter_off + 12;
    let (mirror_claim12_match, mirror_claim12_mispredict_no_edge_observed, mirror_claim12_mispredict_wrong_polarity) =
        if data.len() >= claim12_off + 12 {
            (g32(claim12_off), g32(claim12_off + 4), g32(claim12_off + 8))
        } else { (0, 0, 0) };
    // Raw wire-state-per-slot log (32 bytes) + count (u32).
    let wire_log_off = claim12_off + 12;
    let (slot_wire_log, slot_wire_log_count) = if data.len() >= wire_log_off + 36 {
        let mut log = [0u8; 32];
        log.copy_from_slice(&data[wire_log_off..wire_log_off + 32]);
        (log, g32(wire_log_off + 32))
    } else { ([0u8; 32], 0) };
    // FPGA-decoded-bits log (32 bytes) + count (u32). Same backward-compat rule.
    let fpga_log_off = wire_log_off + 36;
    let (fpga_decoded_log, fpga_decoded_log_count) = if data.len() >= fpga_log_off + 36 {
        let mut log = [0u8; 32];
        log.copy_from_slice(&data[fpga_log_off..fpga_log_off + 32]);
        (log, g32(fpga_log_off + 32))
    } else { ([0u8; 32], 0) };
    // slots_crossed clamp diagnostic (2 × u32). Older firmware → both 0.
    let clamp_off = fpga_log_off + 36;
    let (edges_slots_crossed_capped, max_observed_slots_crossed) =
        if data.len() >= clamp_off + 8 {
            (g32(clamp_off), g32(clamp_off + 4))
        } else { (0, 0) };
    // Parity-ambiguous skip counter (u32). Older firmware → 0.
    let parity_off = clamp_off + 8;
    let edges_parity_ambiguous_skipped = if data.len() >= parity_off + 4 {
        g32(parity_off)
    } else { 0 };
    // Raw own_cyc capture (u32 slot_cyc, u32 count, 256 × u32 log). Older firmware → empty.
    let raw_off = parity_off + 4;
    let (raw_own_cyc_slot_cyc, raw_own_cyc_count, raw_own_cyc_log) =
        if data.len() >= raw_off + 8 + 256 * 4 {
            let sc = g32(raw_off);
            let cnt = g32(raw_off + 4);
            let mut log = Vec::with_capacity(256);
            for i in 0..256 {
                log.push(g32(raw_off + 8 + i * 4));
            }
            (sc, cnt, log)
        } else { (0, 0, Vec::new()) };
    // Late-bits sliding window (32 bytes, ring buffer of last 256 decoded bits).
    let late_off = raw_off + 8 + 256 * 4;
    let fpga_decoded_late_log: [u8; 32] = if data.len() >= late_off + 32 {
        let mut log = [0u8; 32];
        log.copy_from_slice(&data[late_off..late_off + 32]);
        log
    } else { [0u8; 32] };
    let late_raw_off = late_off + 32;
    let (late_raw_own_cyc_count, late_raw_own_cyc_log): (u32, Vec<u32>) =
        if data.len() >= late_raw_off + 4 + 256 * 4 {
            let cnt = g32(late_raw_off);
            let mut log = Vec::with_capacity(256);
            for i in 0..256 {
                log.push(g32(late_raw_off + 4 + i * 4));
            }
            (cnt, log)
        } else { (0, Vec::new()) };
    Ok(SyncResultParsed {
        elapsed_us: g32(0) as u64,
        total_iter: g32(4) as u64,
        status: g32(8),
        frac_bits: g32(12),
        p_shift: g32(16),
        locked: g32(20) != 0,
        edges_to_lock: g32(24),
        acquisition_slot_iter: g32(28),
        final_interval_fp: g32(32),
        acquisition_slot_cyc_rise: g32(36),
        acquisition_slot_cyc_fall: g32(40),
        final_interval_fp_rise: g32(44),
        final_interval_fp_fall: g32(48),
        acquisition_iter_count: g32(52),
        measurement_iter_count: g32(56),
        acq_rising: g32(60),
        acq_falling: g32(64),
        rising_total: g32(68),
        falling_total: g32(72),
        rising_neg_overflow: g32(76),
        rising_pos_overflow: g32(80),
        falling_neg_overflow: g32(84),
        falling_pos_overflow: g32(88),
        hist_bins,
        hist_half_range: (hist_bins / 2) as i32,
        phase_sum: gi64(96),
        bits_buffer,
        bits_decoded,
        tx_words_consumed,
        phase_err_ema_rise,
        phase_err_ema_fall,
        acquisition_slot_cyc_period,
        final_interval_fp_period,
        phase_err_ema_period,
        period_hist,
        period_sum,
        period_sample_count,
        period_min,
        period_max,
        period_ema_slow_fp,
        fpga_decoded_buffer,
        fpga_decoded_count,
        mirror_edges_accepted,
        mirror_edges_rejected_mid_slot,
        mirror_edges_rejected_wrong_polarity,
        mirror_claim12_match,
        mirror_claim12_mispredict_no_edge_observed,
        mirror_claim12_mispredict_wrong_polarity,
        slot_wire_log,
        slot_wire_log_count,
        fpga_decoded_log,
        fpga_decoded_log_count,
        edges_slots_crossed_capped,
        max_observed_slots_crossed,
        edges_parity_ambiguous_skipped,
        raw_own_cyc_slot_cyc,
        raw_own_cyc_count,
        raw_own_cyc_log,
        fpga_decoded_late_log,
        late_raw_own_cyc_count,
        late_raw_own_cyc_log,
        fall_to_rise_offset_sum: gi64(104),
        rise_to_fall_offset_sum: gi64(112),
        rising_hist,
        falling_hist,
    })
}

/// Print the period diagnostic histogram. Reads the shape:
/// - tight pile at bin 8 alone → clean lock
/// - bimodal at bin 4 AND bin 8 → missed-edge artefacts (one rising lost merges two periods)
/// - continuous low-side tail (bins 1..7) → RC ringing / false transitions on shoulders
/// - mass at bin 16 (overflow) → long silence runs or dropped runs of edges
fn print_period_hist(hist: &[u32], seed_cyc: u32) {
    if hist.is_empty() || seed_cyc == 0 {
        return;
    }
    let bin_width = seed_cyc / 8;
    if bin_width == 0 {
        return;
    }
    let total: u64 = hist.iter().map(|&c| c as u64).sum();
    let max = hist.iter().copied().max().unwrap_or(0).max(1);
    let n = hist.len();
    println!();
    println!("  PERIOD histogram ({} samples, bin width = seed/8 = {} cyc; bin 8 = seed {} cyc):",
        total, bin_width, seed_cyc);
    for (i, &count) in hist.iter().enumerate() {
        let range = if i + 1 == n {
            format!(">={:5} cyc       ", i as u32 * bin_width)
        } else {
            format!("{:5}..{:5} cyc   ", i as u32 * bin_width, (i as u32 + 1) * bin_width)
        };
        let bar_len = (count as u64 * 40 / max as u64) as usize;
        let bar: String = core::iter::repeat('#').take(bar_len).collect();
        let marker = match i {
            4 => "  ← seed/2 (missed-edge suspect)",
            8 => "  ← seed",
            _ if i + 1 == n => "  ← ≥2×seed overflow",
            _ => "",
        };
        println!("    bin {:02} [{}]: {:8} {}{}", i, range, count, bar, marker);
    }
}

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
    let p_shift: u32 = args
        .get(3)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad P_SHIFT: {e}")))
        .transpose()?
        .unwrap_or(8)
        .min(24);
    let cascade_mode: u32 = args
        .get(4)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad CASCADE_MODE (0 = clean-toggle, 1 = multi-slot): {e}")))
        .transpose()?
        .unwrap_or(1)
        .min(1);

    let r = run_wire_sync_full(port_path, max_iter, frac_bits, settle_iter, p_shift, 0, cascade_mode)?;
    let SyncResultParsed { elapsed_us, total_iter, status, frac_bits, p_shift: _,
        locked, edges_to_lock,
        acquisition_slot_iter: _acq_avg, final_interval_fp: _final_avg,
        acquisition_slot_cyc_rise, acquisition_slot_cyc_fall,
        final_interval_fp_rise, final_interval_fp_fall,
        acquisition_iter_count, measurement_iter_count,
        acq_rising, acq_falling, rising_total, falling_total,
        rising_neg_overflow, rising_pos_overflow, falling_neg_overflow, falling_pos_overflow,
        hist_half_range, phase_sum, fall_to_rise_offset_sum, rise_to_fall_offset_sum,
        rising_hist, falling_hist, .. } = r;

    // SYSTICK ticks at the AHB clock = 125 MHz on RP2040 → 8 ns per cycle. All slot
    // / phase_err / RC values are in cycles now; the iter-rate of the inner loop only
    // shows up in the wall-time-per-iter sanity print.
    const NS_PER_CYC: f64 = 8.0;
    let inner_loop_ns_per_iter = if total_iter > 0 {
        (elapsed_us as f64 * 1000.0) / total_iter as f64
    } else { 0.0 };
    let iter_mhz = if elapsed_us > 0 {
        total_iter as f64 / elapsed_us as f64
    } else { 0.0 };
    let status_str = match status {
        0 => "LOCKED",
        1 => "acquisition incomplete (not enough same-polarity intervals in budget)",
        2 => "no edges seen — wire dead?",
        _ => "unknown",
    };
    println!(
        "PIPE wire sync ({} iterations, {:.3} ms wall time, {:.3} Miter/s, {:.1} ns/iter inner loop):",
        total_iter, elapsed_us as f64 / 1000.0, iter_mhz, inner_loop_ns_per_iter,
    );
    println!("  status: {}", status_str);

    if status == 2 {
        return Ok(());
    }

    let fp_scale = (1u64 << frac_bits) as f64;
    let acq_rise_ns = acquisition_slot_cyc_rise as f64 * NS_PER_CYC;
    let acq_fall_ns = acquisition_slot_cyc_fall as f64 * NS_PER_CYC;
    let final_slot_rise = final_interval_fp_rise as f64 / fp_scale;
    let final_slot_fall = final_interval_fp_fall as f64 / fp_scale;
    let final_rise_ns = final_slot_rise * NS_PER_CYC;
    let final_fall_ns = final_slot_fall * NS_PER_CYC;
    let drift_rise = final_slot_rise - acquisition_slot_cyc_rise as f64;
    let drift_fall = final_slot_fall - acquisition_slot_cyc_fall as f64;
    let drift_rise_ppm = if acquisition_slot_cyc_rise > 0 {
        drift_rise * 1_000_000.0 / acquisition_slot_cyc_rise as f64
    } else { 0.0 };
    let drift_fall_ppm = if acquisition_slot_cyc_fall > 0 {
        drift_fall * 1_000_000.0 / acquisition_slot_cyc_fall as f64
    } else { 0.0 };

    println!();
    println!("  acquisition: {} edges ({} rise-to-rise + {} fall-to-fall) in {} iter",
        acq_rising + acq_falling, acq_rising, acq_falling, acquisition_iter_count);
    println!("    rise seed: {} cyc = {:.3} µs   fall seed: {} cyc = {:.3} µs   Δrc seed: {:+.0} ns",
        acquisition_slot_cyc_rise, acq_rise_ns / 1000.0,
        acquisition_slot_cyc_fall, acq_fall_ns / 1000.0,
        (acq_fall_ns - acq_rise_ns));

    let total_edges = rising_total + falling_total;
    let total_ov = rising_neg_overflow + rising_pos_overflow + falling_neg_overflow + falling_pos_overflow;

    println!("  tracking:    {} edges ({} rising + {} falling) in {} iter; {} hist overflow; FRAC={}",
        total_edges, rising_total, falling_total,
        measurement_iter_count,
        total_ov, frac_bits,
    );

    if locked {
        println!("  LOCK:        held at end of run (period EMA within ±16 cyc; first achieved at edge {})", edges_to_lock);
    } else {
        println!("  LOCK:        NOT held (period EMA exceeded ±16 cyc at end of run)");
    }
    let period_fp_scale = (1u64 << frac_bits) as f64;
    let period_seed_cyc = r.acquisition_slot_cyc_period as f64;
    let period_p_cyc   = r.final_interval_fp_period as f64 / period_fp_scale;
    let period_slow_cyc = r.period_ema_slow_fp as f64 / period_fp_scale;
    // Pick the best-estimate period for ppm/freq math: prefer the slow EMA (smaller
    // per-run variance, ~33 ppm SE), fall back to the running mean if the slow EMA
    // is empty (e.g. response from old firmware), then to the P-controller output.
    let period_best_cyc = if period_slow_cyc > 0.0 { period_slow_cyc }
        else if r.period_sample_count > 0 { r.period_sum as f64 / r.period_sample_count as f64 }
        else { period_p_cyc };
    let period_best_ns = period_best_cyc * NS_PER_CYC;
    let freq_hz = if period_best_cyc > 0.0 { 125_000_000.0 / period_best_cyc } else { 0.0 };
    let drift_seed_cyc = period_best_cyc - period_seed_cyc;
    let drift_seed_ppm = if period_seed_cyc > 0.0 { 1e6 * drift_seed_cyc / period_seed_cyc } else { 0.0 };
    // 4096-slot silence budget (= 2^12): drift × 4096 must stay under 0.5 × slot.
    // slot = period / 2 ≈ period_seed_cyc / 2. Tolerance = (slot / 2) / 4096 = period / 16384.
    // In ppm of period: 1e6 / 16384 ≈ 61 ppm one-sided.
    let silence_budget_ppm = 1.0e6 / 16384.0;
    // Slow-EMA noise estimate. Per-sample σ comes from period_now span — but for
    // cascade=1 LFSR data the span is huge (multi-slot intervals 1×..N×), so
    // dividing by 6 gives a "σ" of thousands of cyc that isn't real per-period
    // jitter. The slow EMA only consumes n_periods==1 samples whose σ matches the
    // clean-toggle case (~2 cyc on this wire). Cap the σ used for SE at 3 cyc as a
    // conservative ceiling that covers both modes — clean-toggle uses the smaller
    // measured value; LFSR falls back to the cap rather than the misleading raw σ.
    let per_sample_span = (r.period_max - r.period_min) as f64;
    let approx_sigma_raw = if per_sample_span > 0.0 { per_sample_span / 6.0 } else { 0.0 };
    let sigma_for_se = approx_sigma_raw.min(3.0);
    // Slow EMA's effective averaging window = 2^SLOW_SHIFT = 1024 samples (firmware
    // SYNC_PERIOD_EMA_SLOW_SHIFT = 10). The estimator noise is σ / √N_eff regardless
    // of total run length, because the EMA window is fixed.
    const SLOW_EMA_N_EFF: f64 = 1024.0;
    let se_of_mean_cyc = sigma_for_se / SLOW_EMA_N_EFF.sqrt();
    let se_of_mean_ppm = if period_best_cyc > 0.0 { 1e6 * se_of_mean_cyc / period_best_cyc } else { 0.0 };
    // Silence-budget check: what matters is whether our PREDICTION (the slow EMA)
    // is accurate enough to call slot boundaries 4096 silent slots later. That
    // accuracy is bounded by:
    //   (a) the estimator's own noise — SE-of-mean from the slow EMA's effective
    //       window (~1024 samples), bounded below by per-sample-σ / √N_eff
    //   (b) actual wire drift over the silence stretch (~188 ms here) — typically
    //       <1 ppm for a warm ring osc, but uncharacterised from a single run
    // The seed-to-slow-EMA delta is NOT the relevant error — seed is a 12 ms
    // snapshot at acquisition with its own ~175 ppm truncation/measurement error.
    // It's shown below as a sanity comparison only.
    let in_budget_estimate = se_of_mean_ppm < silence_budget_ppm;
    let budget_mark = if in_budget_estimate { "✓ inside" } else { "✗ over" };

    println!();
    println!("  WIRE STATS:");
    println!("    period:        {:.4} cyc = {:.4} µs   freq: {:.1} Hz",
        period_best_cyc, period_best_ns / 1000.0, freq_hz);
    println!("    per-period:    min {} / max {} cyc  (raw distribution — for LFSR includes 1×/2×/3×/4× slot gaps)",
        r.period_min, r.period_max);
    println!("    slow-EMA SE:   {:.4} cyc ({:.2} ppm)  [σ={:.1} cyc / √{:.0} (= EMA window)]   silence budget: ±{:.0} ppm  [{}]",
        se_of_mean_cyc, se_of_mean_ppm, sigma_for_se, SLOW_EMA_N_EFF, silence_budget_ppm, budget_mark);
    println!("    sources:       seed {} cyc  →  P-loop final {:.4} cyc  →  slow-EMA {:.4} cyc",
        r.acquisition_slot_cyc_period, period_p_cyc, period_slow_cyc);
    println!("    drift vs seed: {:+.4} cyc ({:+.1} ppm) — informational only (seed has ~175 ppm truncation error)",
        drift_seed_cyc, drift_seed_ppm);
    println!();
    println!("  P-EMA final: period {:+5} cyc (active lock signal)   rise {:+5} cyc   fall {:+5} cyc   (threshold ±16)",
        r.phase_err_ema_period, r.phase_err_ema_rise, r.phase_err_ema_fall);
    if r.bits_decoded > 0 {
        let valid = (r.bits_decoded as u32).min(64);
        let mask = if valid == 64 { u64::MAX } else { (1u64 << valid) - 1 };
        let visible = r.bits_buffer & mask;
        let popcount = visible.count_ones();
        let pct = 100.0 * popcount as f64 / valid as f64;
        println!("  bit decode:  {} total bits since lock; last {} = G#{:016X} (popcount {} = {:.1}% ones)",
            r.bits_decoded, valid, visible, popcount, pct);
    }
    if r.fpga_decoded_count > 0 {
        // Phase 2c: bridge-side decode of FPGA's Claim 12 TX bits. The buffer is a
        // rolling 32-bit LSB-first window; once 32+ enclave slots have passed in
        // FPGA DATA mode, the buffer value equals a rotation of TX_PATTERN. Print
        // both the raw u32 (hex) and the bit string (LSB-first, MSB-first) so the
        // user can match against the FPGA bitstream's TX_PATTERN parameter.
        let buf = r.fpga_decoded_buffer;
        let popcount = buf.count_ones();
        let pct = 100.0 * popcount as f64 / 32.0;
        println!("  FPGA decode: {} enclave slots; last 32 bits = G#{:08X} (popcount {} = {:.1}% ones)",
            r.fpga_decoded_count, buf, popcount, pct);
        // Rotation-matching helper: if TX_PATTERN matches a known FPGA bitstream
        // default, any 32-bit window that captured a full cycle decodes to a rotation
        // of that pattern. Check both the symmetric AAAAAAAA (legacy default) and
        // the non-symmetric DEADBEEF (current default — bit-shift distinguishable).
        let matches_rot = |target: u32| (0..32).any(|k| buf == target.rotate_left(k));
        if matches_rot(0xDEAD_BEEF) {
            println!("    → matches a rotation of 0xDEADBEEF (FPGA bitstream default TX_PATTERN)");
        } else if matches_rot(0xAAAA_AAAA) {
            println!("    → matches a rotation of 0xAAAAAAAA (legacy FPGA TX_PATTERN; symmetric — masks phase-shift artefacts)");
        }
    }
    if r.period_sample_count > 0 {
        let avg_cyc = r.period_sum as f64 / r.period_sample_count as f64;
        let sum_ns = r.period_sum as f64 * NS_PER_CYC;
        let elapsed_ns = elapsed_us as f64 * 1000.0;
        let ratio = if elapsed_ns > 0.0 { sum_ns / elapsed_ns } else { 0.0 };
        println!("  PERIOD sanity: sum {} cyc = {:.3} ms over {} samples (avg {:.1} cyc); wall-time {:.3} ms; ratio {:.3}",
            r.period_sum, sum_ns / 1e6, r.period_sample_count, avg_cyc,
            elapsed_ns / 1e6, ratio);
        println!("                 min {} cyc / max {} cyc (= {:.0} ns / {:.0} ns)",
            r.period_min, r.period_max,
            r.period_min as f64 * NS_PER_CYC,
            r.period_max as f64 * NS_PER_CYC);
    }
    print_period_hist(&r.period_hist, r.acquisition_slot_cyc_period);

    if total_edges == 0 {
        println!("  no tracking edges — increase MAX_ITER or check wire");
        return Ok(());
    }

    println!();
    println!("  final RISING slot: {:.4} cyc = {:.3} µs   drift: {:+.4} cyc ({:+.1} ppm)",
        final_slot_rise, final_rise_ns / 1000.0, drift_rise, drift_rise_ppm);
    println!("  final FALLING slot: {:.4} cyc = {:.3} µs   drift: {:+.4} cyc ({:+.1} ppm)",
        final_slot_fall, final_fall_ns / 1000.0, drift_fall, drift_fall_ppm);
    let asym_ns = final_fall_ns - final_rise_ns;
    println!("  RC asymmetry: {:+.0} ns (fall − rise; matches wire_stats HIGH/LOW width gap)", asym_ns);

    let phase_mean = phase_sum as f64 / total_edges as f64;
    println!("  mean phase_err: {:+.3} cyc ({:+.1} ns) over {} edges (trends to 0 when lock matches wire)",
        phase_mean, phase_mean * NS_PER_CYC, total_edges);

    if rising_total > 0 && falling_total > 0 {
        let fr_mean = fall_to_rise_offset_sum as f64 / rising_total as f64;
        let rf_mean = rise_to_fall_offset_sum as f64 / falling_total as f64;
        let delta_rc = (rf_mean - fr_mean) / 2.0;
        println!("  RC offset: rise→fall {:+.3} cyc, fall→rise {:+.3} cyc  →  Δrc = {:+.3} cyc ({:+.1} ns)",
            rf_mean, fr_mean, delta_rc, delta_rc * NS_PER_CYC);
    }

    // Per-polarity phase_err histograms. Bin i represents phase_err = (i - hist_half_range) cyc.
    let render_hist = |label: &str, hist: &[u16], neg_ov: u32, pos_ov: u32| {
        let total: u64 = hist.iter().map(|&v| v as u64).sum::<u64>() + neg_ov as u64 + pos_ov as u64;
        if total == 0 {
            println!("    {} hist: (no edges)", label);
            return;
        }
        let first = hist.iter().position(|&v| v > 0);
        let last = hist.iter().rposition(|&v| v > 0);
        println!("    {} hist (signed cycle offset → count, total {}, overflow {} neg / {} pos):",
            label, total, neg_ov, pos_ov);
        if let (Some(f), Some(l)) = (first, last) {
            for i in f..=l {
                let count = hist[i];
                if count == 0 { continue; }
                let signed_off = i as i32 - hist_half_range;
                println!("      {:+5} cyc ({:+8.1} ns)  {:>6}",
                    signed_off,
                    signed_off as f64 * NS_PER_CYC,
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

/// `tune_p [P_MIN [P_MAX [MAX_ITER [FRAC_BITS]]]]` — sweep the proportional tracker
/// shift across [P_MIN..=P_MAX] (default 4..14) and print a per-shift comparison row
/// so we can pick the value that locks fastest and holds the tightest. Each row runs
/// one full wire_sync, so a 10-value sweep takes ~90 seconds with the default budget.
///
/// Read the table this way:
///   `locked?`        — status field (0 = LOCKED, 1 = acquisition incomplete, 2 = no edges)
///   `final µs`       — final_interval_fp converted to µs; should be wire half-period
///   `drift ppm`      — how far the integrator slewed from the acquisition seed
///   `mean phase ns`  — should trend to zero if the lock is good
///   `lock %`         — fraction of edges that fell in the histogram center 5 bins; high
///                      means tight, low means the tail / overflow eats most edges
///   `overflow`       — edges outside the histogram entirely; if this dominates the
///                      tracker is chasing something that doesn't fit ±HALF iter
fn cmd_tune_p(port_path: &str, args: &[String]) -> Result<(), String> {
    let p_min: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad P_MIN: {e}")))
        .transpose()?
        .unwrap_or(4)
        .min(24);
    let p_max: u32 = args.get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad P_MAX: {e}")))
        .transpose()?
        .unwrap_or(14)
        .min(24);
    let max_iter: u32 = args.get(2)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad MAX_ITER: {e}")))
        .transpose()?
        .unwrap_or(1 << 24)
        .clamp(2048, 1 << 28);
    let frac_bits: u32 = args.get(3)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad FRAC_BITS: {e}")))
        .transpose()?
        .unwrap_or(13)
        .clamp(2, 19);
    if p_min > p_max {
        return Err(format!("P_MIN ({p_min}) > P_MAX ({p_max})"));
    }

    println!(
        "Sweeping p_shift = {p_min}..={p_max} (gain = 1/2^p_shift); MAX_ITER={max_iter}, FRAC_BITS={frac_bits}, ~{}s per row, ~{}s total",
        max_iter / 4_000_000,
        (p_max - p_min + 1) * (max_iter / 4_000_000),
    );
    println!();
    println!("  p | rise µs / drift ppm | fall µs / drift ppm | Δrc ns | std r/f cyc | smoothed cyc | 2^N r/f | max r/f | LOCKED  | →lock @ | ovfl");
    println!("  --+---------------------+---------------------+--------+-------------+--------------+---------+---------+---------+---------+------");

    const NS_PER_CYC: f64 = 8.0; // SYSTICK @ 125 MHz
    for p in p_min..=p_max {
        let r = run_wire_sync(port_path, max_iter, frac_bits, 0, p)?;
        let fp_scale = (1u64 << r.frac_bits) as f64;
        let final_rise_cyc = r.final_interval_fp_rise as f64 / fp_scale;
        let final_fall_cyc = r.final_interval_fp_fall as f64 / fp_scale;
        let drift_rise_ppm = if r.acquisition_slot_cyc_rise > 0 {
            (final_rise_cyc - r.acquisition_slot_cyc_rise as f64) * 1_000_000.0 / r.acquisition_slot_cyc_rise as f64
        } else { 0.0 };
        let drift_fall_ppm = if r.acquisition_slot_cyc_fall > 0 {
            (final_fall_cyc - r.acquisition_slot_cyc_fall as f64) * 1_000_000.0 / r.acquisition_slot_cyc_fall as f64
        } else { 0.0 };
        let asym_ns = (final_fall_cyc - final_rise_cyc) * NS_PER_CYC;

        // Per-polarity phase_err stats from each polarity's histogram (centered on that
        // polarity's own lock — std reflects only its own noise, no cross-polarity
        // bleed). Also extract the worst-case |phase_err| observed.
        let stat_polarity = |hist: &[u16]| -> (f64, i32) {
            let mut count: f64 = 0.0;
            let mut sum: f64 = 0.0;
            let mut sumsq: f64 = 0.0;
            let mut max_abs: i32 = 0;
            for (i, &c) in hist.iter().enumerate() {
                if c == 0 { continue; }
                let bin = i as i32 - r.hist_half_range;
                let cf = c as f64;
                let bf = bin as f64;
                count += cf;
                sum += cf * bf;
                sumsq += cf * bf * bf;
                if bin.abs() > max_abs { max_abs = bin.abs(); }
            }
            let std = if count > 0.0 {
                let m = sum / count;
                ((sumsq / count) - m * m).max(0.0).sqrt()
            } else { 0.0 };
            (std, max_abs)
        };
        let (rise_std, rise_max) = stat_polarity(&r.rising_hist);
        let (fall_std, fall_max) = stat_polarity(&r.falling_hist);

        // Smoothed std after the P controller's effective averaging (~2^p_shift edges).
        // Per-edge measurement noise reduces by √(2^p_shift) when integrated thru the
        // single-pole filter the proportional gain creates. The steady-state precision
        // is slot / smoothed_std → 2^N stability per slot.
        let avg_window = (1u64 << p) as f64;
        let smooth_rise = rise_std / avg_window.sqrt();
        let smooth_fall = fall_std / avg_window.sqrt();
        let slot_rise = final_rise_cyc.max(1.0);
        let slot_fall = final_fall_cyc.max(1.0);
        let n_rise = if smooth_rise > 0.0 { (slot_rise / smooth_rise).log2() } else { 0.0 };
        let n_fall = if smooth_fall > 0.0 { (slot_fall / smooth_fall).log2() } else { 0.0 };

        let total_ov = r.rising_neg_overflow + r.rising_pos_overflow + r.falling_neg_overflow + r.falling_pos_overflow;
        let lock_flag = if r.locked { "  yes  " } else { "  no   " };
        let lock_at: String = if r.locked { format!("{}", r.edges_to_lock) } else { "—".to_string() };

        println!(
            "  {:>2} | {:>6.3} / {:>+8.0} | {:>6.3} / {:>+8.0} | {:>+5.0} | {:>4.2}/{:>4.2}   | {:>5.2}/{:>5.2}  | {:>4.1}/{:>4.1} | {:>3}/{:>3} | {} | {:>7} | {:>5}",
            p,
            final_rise_cyc * NS_PER_CYC / 1000.0, drift_rise_ppm,
            final_fall_cyc * NS_PER_CYC / 1000.0, drift_fall_ppm,
            asym_ns,
            rise_std, fall_std,
            smooth_rise, smooth_fall,
            n_rise, n_fall,
            rise_max, fall_max,
            lock_flag, lock_at, total_ov,
        );
    }
    Ok(())
}

/// `wire_bits [P_SHIFT [LFSR_SEED_HEX]]` — runs one wire_sync and dumps the last 64
/// RX-decoded bits. If a 32-bit LFSR seed is provided, simulates the FPGA's wire LFSR
/// from that seed, slides the 64-bit decoded window across the simulated stream, and
/// reports the offset (in bits) of the first match — confirming the bridge is recovering
/// the actual wire bits, not just acquiring lock.
///
/// FPGA LFSR is the Fibonacci form embedded in top_pipe_random_oled.v:
///   wire_lfsr <= {wire_lfsr[30:0], wire_lfsr[31] ^ wire_lfsr[21] ^ wire_lfsr[1] ^ wire_lfsr[0]};
///   if (wire_lfsr[0]) wire_out <= ~wire_out;   // bit driving slot N's flip = lfsr[0] BEFORE step
/// Default seed = 0xDEADBEEF (matches the bitstream).
fn cmd_wire_bits(port_path: &str, args: &[String]) -> Result<(), String> {
    let p_shift: u32 = args.first()
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad P_SHIFT: {e}")))
        .transpose()?
        .unwrap_or(8)
        .min(24);
    let seed: u32 = args.get(1)
        .map(|s| u32::from_str_radix(s.trim_start_matches("0x").trim_start_matches("G#"), 16)
            .map_err(|e| format!("bad LFSR_SEED_HEX: {e}")))
        .transpose()?
        .unwrap_or(0xDEAD_BEEF);
    let max_iter: u32 = 1 << 24;
    let frac_bits: u32 = 13;
    let settle_iter: u32 = 0;

    let r = run_wire_sync(port_path, max_iter, frac_bits, settle_iter, p_shift)?;
    println!("p_shift={p_shift} locked={} bits_decoded={} edges_to_lock={}",
        r.locked, r.bits_decoded, r.edges_to_lock);
    if r.bits_decoded == 0 {
        return Err("no bits decoded — acquisition failed".to_string());
    }

    let valid_bits = (r.bits_decoded as u32).min(64) as u32;
    let display_mask = 1u64.checked_shl(valid_bits).unwrap_or(0).wrapping_sub(1);
    println!("last {valid_bits} bits (newest=right): {:0width$b}",
        r.bits_buffer & display_mask,
        width = valid_bits as usize);
    println!("                            hex: G#{:016X}", r.bits_buffer);

    // Diagnostic: simulate the FPGA's first N slot bits from the seed, so we can
    // eyeball whether the LFSR formula is right.
    let mut sim_lfsr = seed;
    let mut sim_first_64: u64 = 0;
    for _ in 0..64 {
        let bit = (sim_lfsr & 1) as u64;
        sim_first_64 = (sim_first_64 << 1) | bit;
        let new_bit = ((sim_lfsr >> 31) ^ (sim_lfsr >> 21) ^ (sim_lfsr >> 1) ^ (sim_lfsr >> 0)) & 1;
        sim_lfsr = (sim_lfsr << 1) | new_bit;
    }
    println!("LFSR sim first 64 bits from seed G#{seed:08X}: G#{sim_first_64:016X}");

    // Search the full LFSR period (2^32 - 1) forward for our decoded window.
    let mut lfsr = seed;
    const SIM_SLOTS: u64 = (1u64 << 32) - 1;
    let mut window: u64 = 0;
    let mut filled: u64 = 0;
    let target = r.bits_buffer;
    let mask = if valid_bits == 64 { u64::MAX } else { (1u64 << valid_bits) - 1 };
    let mut found_at: Option<u64> = None;
    for slot_idx in 0..SIM_SLOTS {
        let bit = (lfsr & 1) as u64;
        window = (window << 1) | bit;
        filled += 1;
        let new_bit = ((lfsr >> 31) ^ (lfsr >> 21) ^ (lfsr >> 1) ^ (lfsr >> 0)) & 1;
        lfsr = (lfsr << 1) | new_bit;
        if filled >= valid_bits as u64 && (window & mask) == (target & mask) {
            found_at = Some(slot_idx + 1 - valid_bits as u64);
            break;
        }
    }
    match found_at {
        Some(off) => println!("LFSR match: decoded window appears at slot offset {off} in stream from seed G#{seed:08X}"),
        None => {
            println!("LFSR match: NO match within full period ({SIM_SLOTS} slots) from seed G#{seed:08X}");
            println!("            either the host LFSR formula differs from the FPGA, or the bridge bit decoder has a bug.");
        }
    }
    Ok(())
}

/// `wire_loopback [TX_PATTERN_HEX [P_SHIFT]]` — bridge drives a known 32-bit pattern
/// onto GP0 via PIO TX SM1 while the existing PIO RX SM0 captures the wire. Same
/// fast_sync + bit decoder as wire_bits; the only difference is TX is on. Validates
/// the TX path end-to-end with no FPGA dependency: program a SILENT FPGA bitstream
/// (e.g. top_pipe_silent_oled, pipe_pad tied LOW) and the only edges on the wire are
/// from the bridge's own drive. Recommended pattern: G#AAAAAAAA (LSB-first alternating
/// bits → wire transitions every slot, CDR locks, bit decoder sees all 1s).
fn cmd_wire_loopback(port_path: &str, args: &[String]) -> Result<(), String> {
    let tx_pattern: u32 = args.first()
        .map(|s| u32::from_str_radix(s.trim_start_matches("0x").trim_start_matches("G#"), 16)
            .map_err(|e| format!("bad TX_PATTERN_HEX: {e}")))
        .transpose()?
        .unwrap_or(0xAAAA_AAAA);
    let p_shift: u32 = args.get(1)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad P_SHIFT: {e}")))
        .transpose()?
        .unwrap_or(8)
        .min(24);
    if tx_pattern == 0 {
        return Err("TX_PATTERN must be nonzero — pattern G#00000000 disables TX".to_string());
    }

    println!("wire_loopback: TX pattern G#{tx_pattern:08X}, p_shift={p_shift}");
    let r = run_wire_sync_with_tx(port_path, 1 << 24, 13, 0, p_shift, tx_pattern)?;
    println!("  locked={} edges_to_lock={} bits_decoded={}",
        r.locked, r.edges_to_lock, r.bits_decoded);
    if !r.locked {
        println!("  NOT locked — bridge couldn't acquire on its own TX. Possible: TX not actually");
        println!("  driving the wire (funcsel issue), FPGA still driving (load silent bitstream),");
        println!("  or pattern produces no transitions (e.g. G#FFFFFFFF or G#00000000).");
        return Ok(());
    }
    let valid_bits = (r.bits_decoded as u32).min(64);
    let display_mask = 1u64.checked_shl(valid_bits).unwrap_or(0).wrapping_sub(1);
    println!("  last {valid_bits} bits (newest=right): {:0width$b}",
        r.bits_buffer & display_mask,
        width = valid_bits as usize);
    println!("  hex: G#{:016X}", r.bits_buffer);
    let slot_us = r.final_interval_fp as f64 / (1u64 << r.frac_bits) as f64 * 8.0 / 1000.0;
    println!("  locked slot ≈ {:.3} µs (target: ~2.872 µs for slot rate 348 kHz at PIO clkdiv=359)", slot_us);
    Ok(())
}

/// `wire_tx_diag` — two-phase pad drive comparison. Phase A: PIO TX SM1 with
/// G#AAAAAAAA, count transitions via SIO read. Phase B: SIO direct toggle (CPU
/// writes the GPIO XOR register), count transitions via SIO read. If SIO transitions
/// > 0 and PIO transitions == 0, PIO TX is broken (algorithmic bug). If both == 0,
/// pad can't drive (contention with FPGA or pad config). Includes register dumps
/// for each phase.
fn cmd_wire_tx_diag(port_path: &str) -> Result<(), String> {
    let (resp, _rtt) = send_cmd(port_path, "wire_tx_diag", 42, vec![])?;
    let section = parse_resp(&resp)?;
    let data = section.get("data").map_err(|e| format!("missing data: {e}"))?
        .first().and_then(|v| match v {
            VsfType::v(b'b', bytes) => Some(bytes.clone()),
            _ => None,
        }).ok_or_else(|| "data field not binary".to_string())?;
    if data.len() < 16 * 4 {
        return Err(format!("response too short: {} bytes (want >=64)", data.len()));
    }
    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
    let pio_samples = g32(0);
    let pio_trans = g32(4);
    let pio_first = g32(8);
    let pio_last = g32(12);
    let ctrl_before = g32(16);
    let ctrl_pio = g32(20);
    let pads_pio = g32(24);
    let pio_sm_addr = g32(28);
    let pio_sm_execctrl = g32(32);
    let pio_fstat = g32(36);
    let sio_toggles = g32(40);
    let sio_trans = g32(44);
    let sio_first = g32(48);
    let sio_last = g32(52);
    let ctrl_sio = g32(56);
    let pads_sio = g32(60);
    println!("=== Phase A: PIO TX (pattern G#AAAAAAAA, {pio_samples} SIO samples) ===");
    println!("  transitions: {pio_trans}    first→last pad: {pio_first} → {pio_last}");
    println!("  PIO SM1 addr (current PC): {pio_sm_addr}    execctrl: G#{pio_sm_execctrl:08X}");
    println!("  PIO0.fstat: G#{pio_fstat:08X}    (bits: txfull[19:16] txempty[27:24] rxfull[3:0] rxempty[11:8])");
    println!("  IO_BANK0.gpio(0).ctrl: before G#{ctrl_before:08X}  pio G#{ctrl_pio:08X}");
    println!("    funcsel=G#{:X} outover=G#{:X} oeover=G#{:X}",
        ctrl_pio & 0x1F, (ctrl_pio >> 8) & 0x3, (ctrl_pio >> 12) & 0x3);
    println!("  PADS_BANK0.gpio(0): G#{pads_pio:08X}  IE={} OD={}",
        (pads_pio >> 6) & 1, (pads_pio >> 7) & 1);
    println!();
    println!("=== Phase B: SIO direct toggle ({sio_toggles} XOR writes) ===");
    println!("  transitions: {sio_trans}    first→last pad: {sio_first} → {sio_last}");
    println!("  IO_BANK0.gpio(0).ctrl: G#{ctrl_sio:08X}");
    println!("    funcsel=G#{:X} outover=G#{:X} oeover=G#{:X}",
        ctrl_sio & 0x1F, (ctrl_sio >> 8) & 0x3, (ctrl_sio >> 12) & 0x3);
    println!("  PADS_BANK0.gpio(0): G#{pads_sio:08X}  IE={} OD={}",
        (pads_sio >> 6) & 1, (pads_sio >> 7) & 1);
    println!();
    match (pio_trans, sio_trans) {
        (0, 0) => println!("→ verdict: pad can't drive at all. Contention (yank FPGA / tristate it) or pad config bug."),
        (0, n) if n > 0 => println!("→ verdict: SIO drives ({n} transitions), PIO doesn't. Bug is in PIO TX setup."),
        (p, 0) if p > 0 => println!("→ verdict: PIO drives ({p}), SIO doesn't?? Unexpected. SIO test broken."),
        (p, s) => println!("→ verdict: both drive (PIO {p}, SIO {s}). wire_loopback RX/decode is what's failing."),
    }
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

/// `wire_mirror [MAX_EDGES [FRAC_BITS [P_SHIFT [TX_PATTERN_HEX]]]]` — PIO-driven
/// mirror-XOR slot-aware drive. The bridge runs fast_sync (same CDR as wire_sync)
/// but in mirror mode: after acquisition, SM1 (2-instruction PIO program with
/// side-set on PINDIRS) is started on the next rising edge, anchored to the start
/// of an FPGA enclave slot. SM1 then cycles `nop side 0` (tristate during enclave
/// slot) and `out pins, 1 side 1` (drive one TX bit during host slot). SM1's
/// CLKDIV is continuously updated from interval_fp_low so it stays phase-locked
/// to the FPGA's actual slot rate.
///
/// TX_PATTERN_HEX is a 32-bit pattern, LSB-first. Default `AAAAAAAA` = alternating
/// bits = bridge drives HI on every other host slot, maintaining edge density for
/// the CDR to keep tracking.
fn cmd_wire_mirror(port_path: &str, args: &[String]) -> Result<(), String> {
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
    let p_shift: u32 = args
        .get(2)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad P_SHIFT: {e}")))
        .transpose()?
        .unwrap_or(8)
        .min(24);
    let tx_pattern: u32 = args
        .get(3)
        .map(|s| u32::from_str_radix(s.trim_start_matches("G#"), 16)
            .map_err(|e| format!("bad TX_PATTERN_HEX: {e}")))
        .transpose()?
        .unwrap_or(0xAAAA_AAAA);
    // cascade_mode default is 0 (force single-period). This is the right default
    // for AAAAAAAA-class TX patterns. cascade=1 (multi-period unfold) is exposed
    // for experimentation but reintroduces cascade-promotion fixed points in mirror
    // mode and isn't currently usable for any tested TX pattern. Sparse data (like
    // DEADBEEF) needs TX-aware period prediction — a separate future change.
    let cascade_mode: u32 = args
        .get(4)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad CASCADE_MODE (0=single-period, 1=multi-period unfold): {e}")))
        .transpose()?
        .unwrap_or(0)
        .min(1);
    // sampler_mode: 0 = edge-driven decode (default, byte-identical baseline).
    // 1 = PIO0 SM2 wire-sampler mode (architecture B per ancient-launching-lemur plan).
    // Currently captures raw SM2 byte samples for bit-order validation; decode still
    // comes from the edge-driven path in this phase. Once Test 1 confirms bit order,
    // the sampler decode loop becomes active under this flag.
    let sampler_mode: u32 = args
        .get(5)
        .map(|s| s.parse::<u32>().map_err(|e| format!("bad SAMPLER_MODE (0=edge-driven, 1=PIO SM2 sampler): {e}")))
        .transpose()?
        .unwrap_or(0)
        .min(1);

    // IDLE-clear preamble: drive TX=0 for ~2 seconds before the real run. This forces
    // the FPGA's silent_slot_cnt to saturate (4096 slots @ ~2.7 kHz ≈ 1.5 s), dropping
    // data_mode back to IDLE so the FPGA is in a known state for our handshake. Without
    // this, ~50% of runs fail to lock because the FPGA was already in DATA mode from a
    // previous run, and the all-1s TX pattern doesn't re-trigger anything.
    // Skip the preamble for TX=0 itself (the user IS doing the IDLE-clear).
    if tx_pattern != 0 {
        eprintln!("→ IDLE-clear preamble (TX=0, ~2 s)");
        let mut preamble_params = Vec::with_capacity(20);
        let preamble_max_iter: u32 = 1 << 22;  // ~2 s wall time
        let zero_pattern: u32 = 0;
        preamble_params.extend_from_slice(&preamble_max_iter.to_le_bytes());
        preamble_params.extend_from_slice(&frac_bits.to_le_bytes());
        preamble_params.extend_from_slice(&p_shift.to_le_bytes());
        preamble_params.extend_from_slice(&zero_pattern.to_le_bytes());
        preamble_params.extend_from_slice(&cascade_mode.to_le_bytes());
        let _ = send_cmd(
            port_path,
            "wire_mirror",
            43,
            vec![("data".to_string(), VsfType::v(b'b', preamble_params))],
        )?;
        // Brief settle so the bridge's USB/CPU state is quiescent before the real run.
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    let mut params = Vec::with_capacity(24);
    params.extend_from_slice(&max_iter.to_le_bytes());
    params.extend_from_slice(&frac_bits.to_le_bytes());
    params.extend_from_slice(&p_shift.to_le_bytes());
    params.extend_from_slice(&tx_pattern.to_le_bytes());
    params.extend_from_slice(&cascade_mode.to_le_bytes());
    params.extend_from_slice(&sampler_mode.to_le_bytes());

    let (resp, _rtt) = send_cmd(
        port_path,
        "wire_mirror",
        43,
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

    const SCALAR_BYTES: usize = 24 * 4 + 3 * 8;
    if data.len() < SCALAR_BYTES {
        return Err(format!("mirror response too short: {} bytes", data.len()));
    }
    let g32 = |off: usize| u32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);

    let elapsed_us = g32(0) as u64;
    let total_iter = g32(4) as u64;
    let status = g32(8);
    let locked = g32(20) != 0;
    let edges_to_lock = g32(24);
    let acquisition_slot_cyc_rise = g32(36);
    let acquisition_slot_cyc_fall = g32(40);
    let final_interval_fp_rise = g32(44);
    let final_interval_fp_fall = g32(48);
    let frac_bits_back = g32(12);
    let p_shift_back = g32(16);
    let rising_total = g32(68);
    let falling_total = g32(72);
    let hist_bins = g32(92) as usize;
    let appendix_off = SCALAR_BYTES + 4 * hist_bins;
    let tx_words_consumed = if data.len() >= appendix_off + 16 {
        g32(appendix_off + 12)
    } else {
        0
    };
    // Bits decoder appendix (first 12 bytes of the appendix block).
    let bits_buffer: u64 = if data.len() >= appendix_off + 8 {
        u64::from_le_bytes([
            data[appendix_off],     data[appendix_off + 1],
            data[appendix_off + 2], data[appendix_off + 3],
            data[appendix_off + 4], data[appendix_off + 5],
            data[appendix_off + 6], data[appendix_off + 7],
        ])
    } else { 0 };
    let bits_decoded: u32 = if data.len() >= appendix_off + 12 { g32(appendix_off + 8) } else { 0 };
    // PERIOD appendix (3 × 4 bytes after EMA pair) + histogram (17 × 4 bytes).
    // Layout: [bits_buffer u64][bits_decoded u32][tx_words u32][ema_rise i32]
    //         [ema_fall i32][period_seed u32][period_fp u32][period_ema i32][hist 17×u32]
    let period_seed_cyc = if data.len() >= appendix_off + 28 { g32(appendix_off + 24) } else { 0 };
    let period_final_fp = if data.len() >= appendix_off + 32 { g32(appendix_off + 28) } else { 0 };
    let period_ema = if data.len() >= appendix_off + 36 {
        i32::from_le_bytes([
            data[appendix_off + 32], data[appendix_off + 33],
            data[appendix_off + 34], data[appendix_off + 35],
        ])
    } else { 0 };
    const PERIOD_HIST_BINS: usize = 17;
    let period_hist: Vec<u32> = if data.len() >= appendix_off + 36 + PERIOD_HIST_BINS * 4 {
        (0..PERIOD_HIST_BINS).map(|i| g32(appendix_off + 36 + i * 4)).collect()
    } else {
        Vec::new()
    };
    // Phase 2c decode appendix at the tail. Layout from firmware:
    // [period_sum i64 @ +104][period_sample_count u32 @ +112][period_min i32 @ +116]
    // [period_max i32 @ +120][period_ema_slow_fp u32 @ +124]
    // [fpga_decoded_buffer u32 @ +128][fpga_decoded_count u32 @ +132]
    let decode_off = appendix_off + 36 + PERIOD_HIST_BINS * 4 + 24;
    let (fpga_decoded_buffer, fpga_decoded_count) = if data.len() >= decode_off + 8 {
        (g32(decode_off), g32(decode_off + 4))
    } else { (0, 0) };
    // Mirror-mode filter counters appendix (3 × u32). Backward-compat: older firmware
    // returns shorter payload → all 0.
    let filter_off = decode_off + 8;
    let (mirror_edges_accepted, mirror_edges_rejected_mid_slot, mirror_edges_rejected_wrong_polarity) =
        if data.len() >= filter_off + 12 {
            (g32(filter_off), g32(filter_off + 4), g32(filter_off + 8))
        } else { (0, 0, 0) };
    // Claim-12-aware polarity advisory counters (3 × u32).
    let claim12_off = filter_off + 12;
    let (mirror_claim12_match, mirror_claim12_mispredict_no_edge, mirror_claim12_mispredict_wrong_polarity) =
        if data.len() >= claim12_off + 12 {
            (g32(claim12_off), g32(claim12_off + 4), g32(claim12_off + 8))
        } else { (0, 0, 0) };
    // Raw wire-state-per-slot log (32 bytes) + count (u32).
    let wire_log_off = claim12_off + 12;
    let (slot_wire_log, slot_wire_log_count): ([u8; 32], u32) =
        if data.len() >= wire_log_off + 36 {
            let mut log = [0u8; 32];
            log.copy_from_slice(&data[wire_log_off..wire_log_off + 32]);
            (log, g32(wire_log_off + 32))
        } else { ([0u8; 32], 0) };
    // FPGA-decoded-bits log (32 bytes) + count (u32). First 256 decoded enclave-slot
    // bits for bit-exact verify against the 256-bit FPGA TX_PATTERN.
    let fpga_log_off = wire_log_off + 36;
    let (fpga_decoded_log, fpga_decoded_log_count): ([u8; 32], u32) =
        if data.len() >= fpga_log_off + 36 {
            let mut log = [0u8; 32];
            log.copy_from_slice(&data[fpga_log_off..fpga_log_off + 32]);
            (log, g32(fpga_log_off + 32))
        } else { ([0u8; 32], 0) };
    // slots_crossed clamp diagnostic (2 × u32).
    let clamp_off = fpga_log_off + 36;
    let (edges_slots_crossed_capped, max_observed_slots_crossed): (u32, u32) =
        if data.len() >= clamp_off + 8 {
            (g32(clamp_off), g32(clamp_off + 4))
        } else { (0, 0) };
    // Parity-ambiguous skip counter (u32).
    let parity_off = clamp_off + 8;
    let edges_parity_ambiguous_skipped: u32 = if data.len() >= parity_off + 4 {
        g32(parity_off)
    } else { 0 };
    // Raw own_cyc capture (u32 slot_cyc, u32 count, 256 × u32 log).
    let raw_off = parity_off + 4;
    let (raw_own_cyc_slot_cyc, raw_own_cyc_count, raw_own_cyc_log): (u32, u32, Vec<u32>) =
        if data.len() >= raw_off + 8 + 256 * 4 {
            let sc = g32(raw_off);
            let cnt = g32(raw_off + 4);
            let mut log = Vec::with_capacity(256);
            for i in 0..256 {
                log.push(g32(raw_off + 8 + i * 4));
            }
            (sc, cnt, log)
        } else { (0, 0, Vec::new()) };
    // Late-bits sliding window (32 bytes, ring of last 256 decoded bits).
    let late_off = raw_off + 8 + 256 * 4;
    let fpga_decoded_late_log: [u8; 32] = if data.len() >= late_off + 32 {
        let mut log = [0u8; 32];
        log.copy_from_slice(&data[late_off..late_off + 32]);
        log
    } else { [0u8; 32] };
    let late_raw_off = late_off + 32;
    let (late_raw_own_cyc_count, late_raw_own_cyc_log): (u32, Vec<u32>) =
        if data.len() >= late_raw_off + 4 + 256 * 4 {
            let cnt = g32(late_raw_off);
            let mut log = Vec::with_capacity(256);
            for i in 0..256 {
                log.push(g32(late_raw_off + 4 + i * 4));
            }
            (cnt, log)
        } else { (0, Vec::new()) };
    // SM2 wire-sampler appendix: u32 count, 256 bytes, u32 slots consumed, u32 stall.
    let sm2_off = late_raw_off + 4 + 256 * 4;
    let (sm2_bytes_count, sm2_bytes, sampler_slots_consumed, sm2_rx_stall): (u32, Vec<u8>, u32, u32) =
        if data.len() >= sm2_off + 4 + 256 + 4 + 4 {
            let cnt = g32(sm2_off);
            let bytes = data[sm2_off + 4 .. sm2_off + 4 + 256].to_vec();
            let consumed = g32(sm2_off + 4 + 256);
            let stall = g32(sm2_off + 4 + 256 + 4);
            (cnt, bytes, consumed, stall)
        } else { (0, Vec::new(), 0, 0) };

    const NS_PER_CYC: f64 = 8.0;
    let status_str = match status {
        0 => "LOCKED",
        1 => "acquisition incomplete",
        2 => "no edges — wire dead?",
        _ => "unknown",
    };
    let fp_scale = (1u64 << frac_bits_back) as f64;
    let final_rise_cyc = final_interval_fp_rise as f64 / fp_scale;
    let final_fall_cyc = final_interval_fp_fall as f64 / fp_scale;
    let final_rise_ns = final_rise_cyc * NS_PER_CYC;
    let final_fall_ns = final_fall_cyc * NS_PER_CYC;
    let drift_rise = final_rise_cyc - acquisition_slot_cyc_rise as f64;
    let drift_fall = final_fall_cyc - acquisition_slot_cyc_fall as f64;

    println!(
        "PIPE wire mirror ({} edges, {:.3} ms wall time): {}",
        total_iter, elapsed_us as f64 / 1000.0, status_str,
    );
    println!("  frac_bits={}, p_shift={}, locked={}, edges_to_lock={}",
        frac_bits_back, p_shift_back, locked,
        if edges_to_lock == u32::MAX { "never".into() } else { format!("{}", edges_to_lock) });
    println!();
    println!("  rise seed: {} cyc = {:.3} µs   fall seed: {} cyc = {:.3} µs",
        acquisition_slot_cyc_rise, acquisition_slot_cyc_rise as f64 * NS_PER_CYC / 1000.0,
        acquisition_slot_cyc_fall, acquisition_slot_cyc_fall as f64 * NS_PER_CYC / 1000.0);
    println!("  final RISING slot: {:.4} cyc = {:.3} µs   drift: {:+.4} cyc",
        final_rise_cyc, final_rise_ns / 1000.0, drift_rise);
    println!("  final FALLING slot: {:.4} cyc = {:.3} µs   drift: {:+.4} cyc",
        final_fall_cyc, final_fall_ns / 1000.0, drift_fall);
    println!();
    println!("  rising edges:  {}   falling edges: {}", rising_total, falling_total);
    println!("  TX pattern: G#{:08X}", tx_pattern);
    println!("  TX words pushed: {}  ({} host slots driven)",
        tx_words_consumed, tx_words_consumed * 32);
    if rising_total > 0 {
        let words_per_k_edge = tx_words_consumed as f64 / (rising_total as f64 / 1000.0);
        println!("  TX words / 1000 rising edges: {:.2}  (~1000 expected — one push per rising edge in mirror mode, only when FIFO not full)", words_per_k_edge);
    }
    // Bit decoder readback. In mirror mode with cascade=0 (default), each accepted
    // rising contributes exactly 1 bit (a "1") to bits_buffer, so the output is all
    // 1s when locked. Truly recovering the TX pattern from this stream requires
    // TX-aware period prediction (compute exact n_periods from the known TX bits,
    // unfold accepted edges into the right (n-1) zeros + 1) — not currently done.
    if bits_decoded > 0 {
        let valid = (bits_decoded as u32).min(64);
        let mask = if valid == 64 { u64::MAX } else { (1u64 << valid) - 1 };
        let visible = bits_buffer & mask;
        let popcount = visible.count_ones();
        let pct = 100.0 * popcount as f64 / valid as f64;
        println!("  bit decode:  {} total bits since lock; last {} = G#{:016X} (popcount {} = {:.1}% ones)",
            bits_decoded, valid, visible, popcount, pct);
        println!("               (cascade=0: every accepted edge → 1 \"1\" bit; pattern recovery needs TX-aware unfold)");
    }
    if period_seed_cyc > 0 {
        let period_final_cyc = period_final_fp as f64 / fp_scale;
        let drift = period_final_cyc - period_seed_cyc as f64;
        let drift_ppm = 1e6 * drift / period_seed_cyc as f64;
        println!();
        println!("  PERIOD:      seed {} cyc   final {:.4} cyc   drift {:+.4} cyc ({:+.1} ppm)   silence budget: ±61 ppm",
            period_seed_cyc, period_final_cyc, drift, drift_ppm);
        println!("  P-EMA period: {:+} cyc (threshold ±16; |EMA|≤16 means locked)", period_ema);
    }
    if fpga_decoded_count > 0 {
        // Phase 2c: bridge's inverse-Claim-12 decode of FPGA's TX bits. Rolling
        // 32-bit LSB-first window — after 32+ enclave slots in FPGA DATA mode the
        // value equals a rotation of the FPGA's TX_PATTERN parameter.
        let popcount = fpga_decoded_buffer.count_ones();
        let pct = 100.0 * popcount as f64 / 32.0;
        println!();
        println!("  FPGA decode: {} enclave slots; last 32 bits = G#{:08X} (popcount {} = {:.1}% ones)",
            fpga_decoded_count, fpga_decoded_buffer, popcount, pct);
        // Quick spot-check against the FPGA bitstream's default TX_PATTERN.
        let target: u32 = 0xAAAA_AAAA;
        let matches_default = (0..32).any(|k| fpga_decoded_buffer == target.rotate_left(k));
        if matches_default {
            println!("    → matches a rotation of 0xAAAAAAAA (FPGA bitstream default TX_PATTERN)");
        } else {
            // Show all 4 byte-rotations to make visual scan easier.
            println!("    (rotations: G#{:08X} G#{:08X} G#{:08X} G#{:08X})",
                fpga_decoded_buffer.rotate_left(8),
                fpga_decoded_buffer.rotate_left(16),
                fpga_decoded_buffer.rotate_left(24),
                fpga_decoded_buffer);
        }
    }
    // Raw wire-state-per-slot diagnostic — captures the actual wire value at each of
    // the first up-to-256 slot boundaries crossed after mirror_started. Compare against
    // the computed Claim-12 wire pattern for (FPGA TX = 0xDEADBEEF × bridge TX) in DATA
    // mode and in IDLE mode side-by-side. Any of these three outcomes is diagnostic:
    //   - matches DATA → handshake fired AND slot tracker correctly aligned ✓
    //   - matches IDLE → handshake never fired (FPGA stayed in IDLE the whole test)
    //   - matches neither → slot tracker drifted, OR FPGA bitstream isn't what we think
    if slot_wire_log_count > 0 {
        let n = (slot_wire_log_count as usize).min(64);
        let actual: Vec<u8> = (0..n).map(|i| (slot_wire_log[i / 8] >> (i % 8)) & 1).collect();
        let data_expected = expected_wire_pattern(tx_pattern, 0xDEAD_BEEF, n, false);
        let idle_expected = expected_wire_pattern(tx_pattern, 0xDEAD_BEEF, n, true);
        let to_bits = |v: &[u8]| -> String {
            v.iter()
                .enumerate()
                .map(|(i, &b)| {
                    let c = if b != 0 { '1' } else { '0' };
                    if i > 0 && i % 8 == 0 { format!(" {c}") } else { c.to_string() }
                })
                .collect()
        };
        let data_match = actual.iter().zip(&data_expected).filter(|(a, e)| a == e).count();
        let idle_match = actual.iter().zip(&idle_expected).filter(|(a, e)| a == e).count();
        println!();
        println!("  WIRE LOG (first {} slot boundaries, slot 1 .. slot {}):",
            n, n);
        println!("    actual:        {}", to_bits(&actual));
        println!("    DATA expected: {}  ({}/{} match)", to_bits(&data_expected), data_match, n);
        println!("    IDLE expected: {}  ({}/{} match)", to_bits(&idle_expected), idle_match, n);
        if data_match >= n * 90 / 100 {
            println!("    → DATA mode: handshake fired, slot tracker aligned, decode should work");
        } else if idle_match >= n * 90 / 100 {
            println!("    → IDLE mode: handshake never fired (FPGA stayed in IDLE the whole test)");
        } else {
            let max_match = data_match.max(idle_match);
            println!("    → neither pattern matches (best: {}/{}). slot_phase tracker drift, FPGA bitstream mismatch, or partial-handshake mid-stream", max_match, n);
        }
    }
    // Rung 1: 256-bit bit-exact verify against FPGA_TX_PATTERN_256. Captures the first
    // 256 decoded enclave-slot bits and finds the best rotation alignment. A 256/256
    // match proves Claims 7+12 bit-clean for that capture window. The rotation offset
    // reflects how many enclave slots elapsed before mirror_started snapshotted the log
    // (= startup race between FPGA shift register and bridge's first enclave anchor).
    if fpga_decoded_log_count > 0 {
        let n = (fpga_decoded_log_count as usize).min(256);
        let bit_at = |buf: &[u8; 32], i: usize| (buf[i / 8] >> (i % 8)) & 1;
        let mut best_match = 0usize;
        let mut best_rot = 0usize;
        for rot in 0..256 {
            let matches: usize = (0..n)
                .filter(|&i| bit_at(&fpga_decoded_log, i) == bit_at(&FPGA_TX_PATTERN_256, (i + rot) & 255))
                .count();
            if matches > best_match {
                best_match = matches;
                best_rot = rot;
            }
        }
        println!();
        println!("  FPGA DECODE LOG: first {} enclave-slot bits captured", n);
        if max_observed_slots_crossed > 0 {
            println!("    slots_crossed: max observed = {} (clamp = 32){}",
                max_observed_slots_crossed,
                if edges_slots_crossed_capped > 0 {
                    format!("; CLAMP FIRED {} times — slot_phase parity lost on each event",
                        edges_slots_crossed_capped)
                } else { String::new() });
        }
        if edges_parity_ambiguous_skipped > 0 {
            println!("    parity_ambiguous skipped: {} edges (potential parity flips avoided)",
                edges_parity_ambiguous_skipped);
        }
        let hex_dump = |buf: &[u8; 32]| -> String {
            buf.iter().enumerate()
                .map(|(i, &b)| if i % 4 == 0 && i > 0 { format!(" {b:02X}") } else { format!("{b:02X}") })
                .collect()
        };
        println!("    decoded:  {}", hex_dump(&fpga_decoded_log));
        println!("    expected: {}", hex_dump(&FPGA_TX_PATTERN_256));
        if best_match == n {
            println!("    PASS: Claim 7/12 bit-clean over {} enclave slots, rotation +{}", n, best_rot);
        } else {
            let pct = 100.0 * best_match as f64 / n as f64;
            println!("    best rotation: +{}   match: {}/{} ({:.1}%)", best_rot, best_match, n, pct);
            if best_match < n / 2 + n / 8 {
                println!("    → far from any rotation. Slot tracker may be misaligned, FPGA bitstream may not match the 256-bit TX_PATTERN, or handshake never fired");
            } else if (n - best_match) <= n / 32 {
                println!("    → near-perfect ({} bits off). Residual slot-phase drift over the capture window or off-by-one near the start", n - best_match);
            }
        }
        if n >= 64 {
            println!("    per-32-bit window match @ best rotation +{}:", best_rot);
            for w in 0..(n / 32) {
                let s = w * 32;
                let e = ((w + 1) * 32).min(n);
                let m: usize = (s..e)
                    .filter(|&i| bit_at(&fpga_decoded_log, i) == bit_at(&FPGA_TX_PATTERN_256, (i + best_rot) & 255))
                    .count();
                println!("      slots {:3}..{:3}: {:2}/32", s, e, m);
            }
        }
        // Longest contiguous run of perfectly-matched bits at the best rotation.
        // This is the patent-claim evidence: even if the slot tracker eventually
        // drifts mid-run, a long bit-exact run proves Claims 7+12 protocol works
        // at the physical layer.
        let mut max_run = 0usize;
        let mut cur_run = 0usize;
        let mut max_run_start = 0usize;
        let mut cur_run_start = 0usize;
        for i in 0..n {
            if bit_at(&fpga_decoded_log, i) == bit_at(&FPGA_TX_PATTERN_256, (i + best_rot) & 255) {
                if cur_run == 0 { cur_run_start = i; }
                cur_run += 1;
                if cur_run > max_run {
                    max_run = cur_run;
                    max_run_start = cur_run_start;
                }
            } else {
                cur_run = 0;
            }
        }
        if max_run >= 32 {
            println!("    longest perfect run: {} bits starting at slot {} (slots {}..{} bit-exact match against pattern[{}..])",
                max_run, max_run_start, max_run_start, max_run_start + max_run,
                (max_run_start + best_rot) & 255);
            if max_run >= 64 {
                println!("    → ≥64 consecutive bits bit-clean: Claims 7+12 hardware-proven (slot tracker drifts beyond this but protocol works)");
            }
        }
        // Late-bits sliding window verification: ring buffer of LAST 256 decoded bits.
        // Linearise by reading positions [decode_count % 256, decode_count % 256 + 1, ...]
        // mod 256 — that puts the OLDEST bit (slot index decode_count - 256) first.
        if fpga_decoded_count >= 256 {
            let total_slots = fpga_decoded_count as usize;
            let late_start_slot = total_slots - 256;
            let ring_start = total_slots & 255;
            let mut late_linear = [0u8; 32];
            for i in 0..256 {
                let ring_pos = (ring_start + i) & 255;
                let src_byte = fpga_decoded_late_log[ring_pos >> 3];
                let src_bit = (src_byte >> (ring_pos & 7)) & 1;
                if src_bit != 0 {
                    late_linear[i >> 3] |= 1 << (i & 7);
                }
            }
            let mut best_late_rot = 0usize;
            let mut best_late_match = 0usize;
            for rot in 0..256 {
                let m: usize = (0..256)
                    .filter(|&i| bit_at(&late_linear, i) == bit_at(&FPGA_TX_PATTERN_256, (i + rot) & 255))
                    .count();
                if m > best_late_match { best_late_match = m; best_late_rot = rot; }
            }
            println!();
            println!("  LATE DECODE LOG: last 256 enclave-slot bits (slot {}..{} of {} total)",
                late_start_slot, total_slots, total_slots);
            if best_late_match == 256 {
                println!("    PASS: bit-clean at rotation +{}", best_late_rot);
            } else {
                let pct = 100.0 * best_late_match as f64 / 256.0;
                println!("    best rotation: +{}   match: {}/256 ({:.1}%)", best_late_rot, best_late_match, pct);
            }
            let expected_late_rot = (best_rot + late_start_slot) & 255;
            let rot_delta_correct = best_late_rot == expected_late_rot;
            if best_match >= 250 && best_late_match >= 250 {
                if rot_delta_correct {
                    println!("    → SUSTAINED BIT-CLEAN over {} slots: first-256 + last-256 BOTH match, rotation delta = {} (= late_start_slot mod 256)",
                        total_slots, late_start_slot & 255);
                    println!("    → Claims 7+12 hardware-proven for sustained operation");
                } else {
                    println!("    → both windows match individually but rotation delta is OFF: first @ +{}, late @ +{}, expected late @ +{} (= +{} mod 256). Slot tracker drifted in between.",
                        best_rot, best_late_rot, expected_late_rot, best_rot + late_start_slot);
                }
            }
        }
    }
    // Raw own_cyc capture: the ground truth. If the histogram doesn't show tight peaks
    // at integer multiples of slot_cyc, the slot tracker's model is wrong and no amount
    // of filter tweaking will fix it.
    let raw_n = raw_own_cyc_count.min(raw_own_cyc_log.len() as u32) as usize;
    if raw_n > 0 {
        println!();
        println!("  RAW own_cyc capture: {} edges, slot_cyc snapshot = {} cyc",
            raw_n, raw_own_cyc_slot_cyc);
        let log = &raw_own_cyc_log[..raw_n];
        let sc = raw_own_cyc_slot_cyc as f64;
        // Min / max / mean
        let min = *log.iter().min().unwrap();
        let max = *log.iter().max().unwrap();
        let sum: u64 = log.iter().map(|&v| v as u64).sum();
        let mean = sum as f64 / raw_n as f64;
        println!("    own_cyc: min={} max={} mean={:.1}", min, max, mean);
        if sc > 0.0 {
            println!("    in slots: min={:.4} max={:.4} mean={:.4}",
                min as f64 / sc, max as f64 / sc, mean / sc);
            // Histogram by integer slot bucket (0, 1, 2, ..., 7+) and fractional offset
            // from nearest integer slot. The fractional offset is the smoking gun:
            // if values cluster near .0/.5/.0/.5, slot_cyc is half its true value;
            // if they cluster near .0/.0/.0, slot tracker is right;
            // if they drift across [0, 1), slot_cyc is wrong by a slowly accumulating
            // amount (which IS clock drift, but at our budgets shouldn't happen).
            let mut int_bins = [0u32; 9];
            let mut frac_bins = [0u32; 10]; // 0.0..0.1, 0.1..0.2, ..., 0.9..1.0
            for &v in log {
                let ratio = v as f64 / sc;
                let int_part = ratio.floor() as usize;
                int_bins[int_part.min(8)] += 1;
                let frac = ratio - ratio.floor();
                let fb = ((frac * 10.0) as usize).min(9);
                frac_bins[fb] += 1;
            }
            println!("    integer-slot bins: 0:{} 1:{} 2:{} 3:{} 4:{} 5:{} 6:{} 7:{} 8+:{}",
                int_bins[0], int_bins[1], int_bins[2], int_bins[3], int_bins[4],
                int_bins[5], int_bins[6], int_bins[7], int_bins[8]);
            println!("    fractional-offset bins (distance from .0):");
            // Reshape into "how close to a slot boundary?" — 0.0 = on it, 0.5 = worst.
            // distance = min(frac, 1.0 - frac).
            let mut dist_bins = [0u32; 6]; // 0.00-0.05, 0.05-0.15, 0.15-0.25, 0.25-0.35, 0.35-0.45, 0.45-0.50
            for &v in log {
                let ratio = v as f64 / sc;
                let frac = ratio - ratio.floor();
                let d = frac.min(1.0 - frac);
                let b = if d < 0.05 { 0 }
                        else if d < 0.15 { 1 }
                        else if d < 0.25 { 2 }
                        else if d < 0.35 { 3 }
                        else if d < 0.45 { 4 }
                        else { 5 };
                dist_bins[b] += 1;
            }
            println!("      0.00-0.05 (on boundary): {}", dist_bins[0]);
            println!("      0.05-0.15:               {}", dist_bins[1]);
            println!("      0.15-0.25:               {}", dist_bins[2]);
            println!("      0.25-0.35:               {}", dist_bins[3]);
            println!("      0.35-0.45:               {}", dist_bins[4]);
            println!("      0.45-0.50 (AMBIGUOUS):   {} ← these are the parity-flip risk", dist_bins[5]);
            // First 32 raw values + ratios so we can eyeball the sequence.
            println!("    first 32 edges (own_cyc / slot_cyc → ratio):");
            for i in 0..raw_n.min(32) {
                let v = log[i];
                let r = v as f64 / sc;
                println!("      [{:3}] {:7} / {} = {:.4}", i, v, raw_own_cyc_slot_cyc, r);
            }
        } else {
            println!("    (slot_cyc=0, ratios unavailable)");
        }
    }
    // LATE raw own_cyc histogram — compares against the EARLY histogram. If late
    // shows MORE sub-slot glitches or quarter-splits, the wire physics has drifted
    // (e.g., RC heating, FPGA clock drift, data-mode-dependent artifacts). If late
    // looks identical to early but decode is bad, the slot tracker math is slipping.
    if late_raw_own_cyc_count > 0 && raw_own_cyc_slot_cyc > 0 {
        let n = 256usize;
        let log = &late_raw_own_cyc_log[..n.min(late_raw_own_cyc_log.len())];
        let sc = raw_own_cyc_slot_cyc as f64;
        let min = *log.iter().min().unwrap();
        let max = *log.iter().max().unwrap();
        let sum: u64 = log.iter().map(|&v| v as u64).sum();
        let mean = sum as f64 / log.len() as f64;
        println!();
        println!("  LATE raw own_cyc capture: ring of last 256 edges (total edges seen post-mirror = {})",
            late_raw_own_cyc_count);
        println!("    own_cyc: min={} max={} mean={:.1}", min, max, mean);
        println!("    in slots: min={:.4} max={:.4} mean={:.4}",
            min as f64 / sc, max as f64 / sc, mean / sc);
        let mut int_bins = [0u32; 9];
        for &v in log {
            let ratio = v as f64 / sc;
            int_bins[ratio.floor() as usize] = int_bins[ratio.floor() as usize].saturating_add(1);
        }
        println!("    integer-slot bins: 0:{} 1:{} 2:{} 3:{} 4:{} 5:{} 6:{} 7:{} 8+:{}",
            int_bins[0], int_bins[1], int_bins[2], int_bins[3], int_bins[4],
            int_bins[5], int_bins[6], int_bins[7], int_bins[8]);
        let mut dist_bins = [0u32; 6];
        for &v in log {
            let ratio = v as f64 / sc;
            let frac = ratio - ratio.floor();
            let d = frac.min(1.0 - frac);
            let b = if d < 0.05 { 0 } else if d < 0.15 { 1 } else if d < 0.25 { 2 }
                    else if d < 0.35 { 3 } else if d < 0.45 { 4 } else { 5 };
            dist_bins[b] += 1;
        }
        println!("    fractional-offset (distance from .0):");
        println!("      0.00-0.05 (on boundary): {}", dist_bins[0]);
        println!("      0.05-0.15:               {}", dist_bins[1]);
        println!("      0.15-0.25:               {}", dist_bins[2]);
        println!("      0.25-0.35:               {}", dist_bins[3]);
        println!("      0.35-0.45:               {}", dist_bins[4]);
        println!("      0.45-0.50 (AMBIGUOUS):   {}", dist_bins[5]);
    }
    // SM2 wire-sampler diagnostic. In edge-mode runs (sampler_mode = 0) all fields
    // are zero. In sampler-mode runs (sampler_mode = 1) the bridge captures the
    // first 256 bytes pushed by SM2 = 2048 slot midpoint samples.
    if sm2_bytes_count > 0 {
        println!();
        println!("  SM2 SAMPLER: {} bytes captured ({} slot samples)",
            sm2_bytes_count, sm2_bytes_count * 8);
        println!("    sampler_slots_consumed = {}, sm2_rx_stall = {}",
            sampler_slots_consumed, sm2_rx_stall);
        if sm2_rx_stall > 0 {
            println!("    WARNING: SM2 RX FIFO stalled {} times — CPU fell behind", sm2_rx_stall);
        }
        // Hex dump of first 32 bytes (256 samples = 256 slots) for bit-order
        // validation against the known wire pattern.
        let n = sm2_bytes_count.min(32) as usize;
        let hex: String = sm2_bytes[..n].iter()
            .enumerate()
            .map(|(i, &b)| if i % 4 == 0 && i > 0 { format!(" {b:02X}") } else { format!("{b:02X}") })
            .collect();
        println!("    first {} bytes (= {} slot samples): {}", n, n * 8, hex);
        // Per-byte bit ratio: how many of 8 bits per byte are set. With a clean
        // alternating wire (= idle FPGA clock at slot rate), every byte should
        // popcount to 4. With FPGA in DATA mode + bridge driving constant 1s,
        // bytes reflect FPGA's TX_PATTERN (combined with bridge=1 every host slot).
        let total_bits: u32 = sm2_bytes[..sm2_bytes_count as usize].iter()
            .map(|&b| b.count_ones())
            .sum();
        let total_samples = (sm2_bytes_count * 8) as f64;
        println!("    total bits set: {} of {} samples ({:.1}% high)",
            total_bits, sm2_bytes_count * 8, 100.0 * total_bits as f64 / total_samples);
    }
    // Mirror-mode edge filter accounting. Sum = post-acquisition edges processed.
    // Healthy lock: accepted ≫ rejected. Diagnostic for decode regressions.
    let filter_total = mirror_edges_accepted
        + mirror_edges_rejected_mid_slot
        + mirror_edges_rejected_wrong_polarity;
    if filter_total > 0 {
        let pct = |n: u32| 100.0 * n as f64 / filter_total as f64;
        println!();
        println!("  MIRROR filter: {} edges processed", filter_total);
        println!("    accepted:                  {:>6} ({:.1}%)",
            mirror_edges_accepted, pct(mirror_edges_accepted));
        println!("    rejected (mid-slot):       {:>6} ({:.1}%) — edge fell outside the ±¼-slot acceptance window around predicted boundaries (CDR phase drifted)",
            mirror_edges_rejected_mid_slot, pct(mirror_edges_rejected_mid_slot));
        println!("    rejected (wrong polarity): {:>6} ({:.1}%) — edge polarity didn't match slot_phase + last/current TX bit prediction (slot_phase parity or tx_shift_reg out of lockstep with SM1)",
            mirror_edges_rejected_wrong_polarity, pct(mirror_edges_rejected_wrong_polarity));
    }
    // Claim-12-aware polarity prediction (ADVISORY — counted only, not yet wired into
    // accept_for_cdr). If `match` dominates over `mispredict_*`, the new model is right
    // and can replace the old prediction.
    let claim12_total = mirror_claim12_match + mirror_claim12_mispredict_no_edge + mirror_claim12_mispredict_wrong_polarity;
    if claim12_total > 0 {
        let pct = |n: u32| 100.0 * n as f64 / claim12_total as f64;
        println!();
        println!("  CLAIM 12 polarity prediction (advisory): {} edges evaluated", claim12_total);
        println!("    matched observation:       {:>6} ({:.1}%) — model predicted edge with correct polarity",
            mirror_claim12_match, pct(mirror_claim12_match));
        println!("    mispredict (no edge):      {:>6} ({:.1}%) — model predicted no edge but observed one (model says wire would have stayed same)",
            mirror_claim12_mispredict_no_edge, pct(mirror_claim12_mispredict_no_edge));
        println!("    mispredict (polarity):     {:>6} ({:.1}%) — model predicted edge but wrong direction",
            mirror_claim12_mispredict_wrong_polarity, pct(mirror_claim12_mispredict_wrong_polarity));
        if mirror_claim12_match * 4 > claim12_total * 3 {
            println!("    → model agreement >75% — Claim-12-aware prediction is correct; can replace old slotted_oled-tuned check");
        } else if mirror_claim12_match > mirror_claim12_mispredict_no_edge + mirror_claim12_mispredict_wrong_polarity {
            println!("    → model agreement >50% — better than old model but needs work before going live");
        } else {
            println!("    → model agreement <50% — Claim 12 prediction is WRONG; check fpga_tx_pos tracking, data_mode detection, or FPGA_TX_PATTERN constant");
        }
    }
    print_period_hist(&period_hist, period_seed_cyc);

    Ok(())
}

/// Response from the firmware `pipe_l3_round` op. The bridge layer L3 protocol
/// (BLAKE3, ratchet, X1/X2 encode/decode, Q_HEALTH composer) lives in higher
/// layers; this helper is the bare USB round-trip.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct L3RoundResponse {
    /// 1 if the bridge held CDR lock for the entire exchange, 0 if lost
    /// (in which case `rx_actual_count` may be less than what was requested
    /// and the next call should set `open_session=true` to force re-acquire).
    pub session_ok: bool,
    /// Number of valid rx bits captured. May be less than the requested count
    /// on lock loss or wall-clock abort.
    pub rx_actual_count: u32,
    /// Final `interval_fp_period` from the bridge CDR — a host-visible
    /// estimate of slot timing for diagnostic. Same fp scaling as
    /// `wire_sync`'s `final_interval_fp_period`.
    pub slot_drift: u32,
    /// Captured enclave-slot bits, LSB-first within each byte (i.e., the
    /// first captured bit is `rx_bits[0]` bit 0). Length is
    /// `ceil(rx_actual_count / 8)`.
    pub rx_bits: Vec<u8>,
}

/// Thin USB round-trip for the firmware `pipe_l3_round` op. Serialises the
/// request payload + parses the response payload. Does NOT implement the L3
/// protocol logic (BLAKE3, fresh-session/Message-B encoding, ratchet, etc.)
/// — those live in their own modules.
///
/// `tx_bits` byte stream is LSB-first within each byte: the first transmitted
/// bit is `tx_bits[0]` bit 0. The bridge consumes exactly `tx_bit_count` bits
/// from this buffer (ignoring any padding bits past that count) and tristates
/// the wire after the last one (drives 0 on host slots until the round ends).
///
/// `rx_count` requests up to this many enclave-slot bits be captured. Actual
/// captured count is in the response and may be less on lock loss.
///
/// `flags`:
///   bit 0 = open_session — force fresh CDR acquire even if the bridge thinks
///           a session is live. Use on first round of a new exchange.
///   bit 1 = close_session — tear down the SMs after this round. Use on the
///           last round of an exchange so the wire goes silent.
///
/// `max_iter` is the wall-clock safety cap on edge-count (same units as
/// wire_sync's `max_iter`). 1 << 25 ≈ 2 s is a sensible default for a single
/// round; the firmware will abort early once both tx_count and rx_count are
/// satisfied.
#[allow(dead_code)]
pub fn cmd_pipe_l3_round(
    port_path: &str,
    tx_bits: &[u8],
    tx_bit_count: u16,
    rx_count: u16,
    flags: u8,
    max_iter: u32,
) -> Result<L3RoundResponse, String> {
    const L3_MAX_BITS: u16 = 520;
    if tx_bit_count > L3_MAX_BITS || rx_count > L3_MAX_BITS {
        return Err(format!(
            "tx_count={tx_bit_count} or rx_count={rx_count} exceeds L3_MAX_BITS={L3_MAX_BITS}"
        ));
    }
    let needed_tx_bytes = (tx_bit_count as usize).div_ceil(8);
    if tx_bits.len() < needed_tx_bytes {
        return Err(format!(
            "tx_bits buffer too small: have {} bytes, need {} for tx_count={tx_bit_count}",
            tx_bits.len(),
            needed_tx_bytes
        ));
    }
    if flags & !0x3 != 0 {
        return Err(format!("reserved flag bits set: G#{flags:02X}"));
    }

    let mut params = Vec::with_capacity(9 + needed_tx_bytes);
    params.extend_from_slice(&tx_bit_count.to_le_bytes());
    params.extend_from_slice(&rx_count.to_le_bytes());
    params.extend_from_slice(&max_iter.to_le_bytes());
    params.push(flags);
    params.extend_from_slice(&tx_bits[..needed_tx_bytes]);

    let (resp, _rtt) = send_cmd(
        port_path,
        "pipe_l3_round",
        47,
        vec![("data".to_string(), VsfType::v(b'b', params))],
    )?;
    if resp.is_empty() {
        return Err("no response (timeout)".into());
    }
    let section = parse_resp(&resp)?;
    if let Some(err) = resp_ascii(&section, "err") {
        return Err(format!("device returned err: {err}"));
    }
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
        return Err(format!(
            "l3 response too short: {} bytes (need >= 8)",
            data.len()
        ));
    }
    let session_ok = data[0] != 0;
    let rx_actual_count = u16::from_le_bytes([data[2], data[3]]) as u32;
    let slot_drift = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    let rx_byte_count = (rx_actual_count as usize).div_ceil(8);
    if data.len() < 8 + rx_byte_count {
        return Err(format!(
            "l3 response truncated: {} bytes, need {} for rx_actual_count={rx_actual_count}",
            data.len(),
            8 + rx_byte_count
        ));
    }
    let rx_bits = data[8..8 + rx_byte_count].to_vec();
    Ok(L3RoundResponse {
        session_ok,
        rx_actual_count,
        slot_drift,
        rx_bits,
    })
}

// ---------- L3 protocol orchestration ------------------------------------- //

/// `Transport` impl that drives the L3 protocol over USB via `cmd_pipe_l3_round`.
///
/// First round of a fresh session sets `flags = open_session`; subsequent
/// rounds reuse the bridge's persisted CDR lock so we don't pay ~tens of ms
/// of acquisition per round. On lock loss the next round will re-acquire.
struct BridgeL3Transport<'a> {
    port_path: &'a str,
    session_open: bool,
    last_slot_drift: u32,
}

impl<'a> BridgeL3Transport<'a> {
    fn new(port_path: &'a str) -> Self {
        Self {
            port_path,
            session_open: false,
            last_slot_drift: 0,
        }
    }
}

impl<'a> pipe_host::l3::Transport for BridgeL3Transport<'a> {
    fn round(&mut self, tx_bits: &[bool], rx_bit_count: usize) -> Result<Vec<bool>, String> {
        // The chip has variable latency between receiving the request and
        // emitting the response — fresh-session has the slowest tail
        // (TRNG gather + 2 × BLAKE3, ~ms). The bridge firmware caps per-round
        // capture at L3_MAX_BITS=520. So drive the request in round 0, then
        // poll-rx in subsequent rounds until the frame-1 marker appears.
        // CDR lock is preserved between rounds by the firmware (session
        // stays "live"), so this is just a few extra USB round-trips, no
        // re-acquisition cost.
        const CAPTURE_BITS: u16 = 519;
        const MAX_POLL_ROUNDS: usize = 50; // 50 × ~10 ms ≈ 500 ms ceiling

        let mut accumulated: Vec<bool> = Vec::new();
        let mut tx_payload = pipe_host::l3::pack_bits_lsb_first(tx_bits);
        let mut tx_count_remaining: u16 = tx_bits.len() as u16;

        for poll in 0..MAX_POLL_ROUNDS {
            let flags = if self.session_open { 0x00 } else { 0x01 };
            let this_tx_bytes: &[u8] = if poll == 0 { &tx_payload } else { &[] };
            let this_tx_count: u16 = if poll == 0 { tx_count_remaining } else { 0 };
            let resp = cmd_pipe_l3_round(
                self.port_path,
                this_tx_bytes,
                this_tx_count,
                CAPTURE_BITS,
                flags,
                1 << 25,
            )?;
            self.last_slot_drift = resp.slot_drift;
            if !resp.session_ok && poll == 0 {
                eprintln!(
                    "  warning: bridge flagged session_ok=0 (slot_drift={}, captured {} bits) — proceeding",
                    resp.slot_drift, resp.rx_actual_count
                );
            }
            self.session_open = true;
            let mut this_chunk = pipe_host::l3::unpack_bits_lsb_first(
                &resp.rx_bits,
                resp.rx_actual_count as usize,
            )
            .map_err(|e| e.to_string())?;
            accumulated.append(&mut this_chunk);

            // Hunt for a frame-1 followed by a high-entropy payload. SM2's
            // first samples after each re-arm can have spurious transients
            // (single 1 surrounded by 0s); the real frame leads into
            // BLAKE3-conditioned random bits at ~50% density. Require the
            // first 64 bits after the candidate frame to contain at least 8
            // ones (~12%, generous lower bound — pure random would give ~32).
            let mut search_start = 0usize;
            loop {
                let rel = accumulated[search_start..].iter().position(|&b| b);
                if rel.is_none() {
                    break;
                }
                let frame_idx = search_start + rel.unwrap();
                if accumulated.len() - frame_idx < rx_bit_count {
                    break; // not enough trailing yet
                }
                let probe_end = (frame_idx + 1 + 64).min(accumulated.len());
                let probe_ones = accumulated[frame_idx + 1..probe_end]
                    .iter()
                    .filter(|&&b| b)
                    .count();
                if probe_ones >= 8 {
                    return Ok(accumulated[frame_idx..frame_idx + rx_bit_count].to_vec());
                }
                // Reject this candidate (low entropy) and look further on.
                search_start = frame_idx + 1;
            }

            // Avoid keeping a huge buffer around — only keep the last ~2KB
            // worth of bits since the frame, in case the frame hasn't shown
            // up yet but will soon.
            if accumulated.len() > 8 * CAPTURE_BITS as usize {
                let cut = accumulated.len() - 4 * CAPTURE_BITS as usize;
                accumulated.drain(..cut);
            }
            // Drop tx after the first round.
            tx_payload.clear();
            tx_count_remaining = 0;
        }
        Err(format!(
            "no frame-1 marker after {} poll rounds ({} bits captured); chip silent or session desynced",
            MAX_POLL_ROUNDS,
            MAX_POLL_ROUNDS * CAPTURE_BITS as usize
        ))
        // Scan for the frame-1 marker. Skip any leading idle bits (0s) the
        // chip emitted before the response was ready.
    }
}

/// `meal_health <expected_state_json> [--ira <64-hex>] [--mode session|permanent]`
///
/// Runs the chip's q/health commitment under the given key (default
/// PERMANENT). Compares the wire-decoded response against the locally-
/// recomputed BLAKE3.keyed(active_key, Q_HEALTH || state_block). PASS iff
/// they match: the chip's permanent (or session) key has just signed the
/// state we asserted.
///
/// The simplest invocation accepts an inline state-block JSON; for the demo
/// we'll typically pass `--ira` once after reading it from the OLED in v1.
fn cmd_meal_health(port_path: &str, args: &[String]) -> Result<(), String> {
    let mut ira_hex: Option<String> = None;
    let mut mode = pipe_host::l3::Mode::Permanent;
    let mut state = pipe_host::l3::StateBlock::default();
    state.chip_state = 4; // sensible default = HEALTHY
    state.ring_health_mask = 0xFFFF;
    state.ring_health_cnt = 16;
    state.slot_burned_mask = 0xFF;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ira" => {
                ira_hex = Some(args.get(i + 1).cloned().ok_or("--ira needs hex value")?);
                i += 2;
            }
            "--mode" => {
                let m = args.get(i + 1).ok_or("--mode needs value")?;
                mode = match m.as_str() {
                    "session" => pipe_host::l3::Mode::Session,
                    "permanent" => pipe_host::l3::Mode::Permanent,
                    other => return Err(format!("unknown mode '{other}'")),
                };
                i += 2;
            }
            "--chip-state" => {
                state.chip_state = args
                    .get(i + 1)
                    .ok_or("--chip-state needs value")?
                    .parse::<u8>()
                    .map_err(|e| format!("--chip-state: {e}"))?;
                i += 2;
            }
            "--ring-mask" => {
                let s = args.get(i + 1).ok_or("--ring-mask needs hex")?;
                state.ring_health_mask = u16::from_str_radix(s.trim_start_matches("G#"), 16)
                    .map_err(|e| format!("--ring-mask: {e}"))?;
                i += 2;
            }
            "--ring-cnt" => {
                state.ring_health_cnt = args
                    .get(i + 1)
                    .ok_or("--ring-cnt needs value")?
                    .parse::<u8>()
                    .map_err(|e| format!("--ring-cnt: {e}"))?;
                i += 2;
            }
            "--slot-mask" => {
                let s = args.get(i + 1).ok_or("--slot-mask needs hex")?;
                state.slot_burned_mask = u8::from_str_radix(s.trim_start_matches("G#"), 16)
                    .map_err(|e| format!("--slot-mask: {e}"))?;
                i += 2;
            }
            "--session-counter" => {
                state.session_counter = args
                    .get(i + 1)
                    .ok_or("--session-counter needs value")?
                    .parse::<u64>()
                    .map_err(|e| format!("--session-counter: {e}"))?;
                i += 2;
            }
            "--drop-counter" => {
                state.drop_counter = args
                    .get(i + 1)
                    .ok_or("--drop-counter needs value")?
                    .parse::<u64>()
                    .map_err(|e| format!("--drop-counter: {e}"))?;
                i += 2;
            }
            "--boot-epoch" => {
                state.boot_epoch = args
                    .get(i + 1)
                    .ok_or("--boot-epoch needs value")?
                    .parse::<u64>()
                    .map_err(|e| format!("--boot-epoch: {e}"))?;
                i += 2;
            }
            other => return Err(format!("unknown arg '{other}'")),
        }
    }
    let ira = parse_hex_word256(ira_hex.as_deref().unwrap_or_else(|| {
        eprintln!("warning: --ira not supplied; defaulting to all-zero. PERMANENT-mode result will be meaningless.");
        ""
    }))?;

    let mut tx = BridgeL3Transport::new(port_path);
    eprintln!("→ opening L3 session (fresh-session)...");
    let report = pipe_host::l3::meal_health(&mut tx, ira, mode, state.clone())
        .map_err(|e| format!("orchestration failed: {e}"))?;

    println!("mode           : {:?}", report.mode);
    println!("expected_state : {:?}", report.state);
    println!("recovered_resp : {}", hex_word256(&report.recovered_response));
    println!("expected_resp  : {}", hex_word256(&report.expected_response));
    println!("slot_drift     : {}", tx.last_slot_drift);
    if report.q_health_pass {
        println!("q/health: PASS — chip key committed to asserted state");
        Ok(())
    } else {
        println!("q/health: FAIL — state hypothesis didn't match chip's commitment");
        Err("q_health_mismatch".into())
    }
}

/// `meal_motuhake --ira <64-hex>` — A/B/C/D canonical test.
fn cmd_meal_motuhake(port_path: &str, args: &[String]) -> Result<(), String> {
    let mut ira_hex: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ira" => {
                ira_hex = Some(args.get(i + 1).cloned().ok_or("--ira needs hex")?);
                i += 2;
            }
            other => return Err(format!("unknown arg '{other}'")),
        }
    }
    let ira = parse_hex_word256(ira_hex.as_deref().ok_or("--ira required")?)?;

    let mut tx = BridgeL3Transport::new(port_path);
    eprintln!("→ opening L3 session (fresh-session)...");
    let report = pipe_host::l3::meal_motuhake(&mut tx, ira)
        .map_err(|e| format!("orchestration failed: {e}"))?;

    println!("A (session 1)  : {}", hex_word256(&report.a_session_1));
    println!("B (session 2)  : {}", hex_word256(&report.b_session_2));
    println!("C (permanent 1): {}", hex_word256(&report.c_permanent_1));
    println!("D (permanent 2): {}", hex_word256(&report.d_permanent_2));
    println!("slot_drift     : {}", tx.last_slot_drift);
    println!();
    println!("session determinism (A == B)            : {}", yn(report.session_deterministic));
    println!("permanent determinism (C == D)          : {}", yn(report.permanent_deterministic));
    println!("modes separated (A != C)                : {}", yn(report.modes_separated));
    println!("permanent matches local recompute (C)   : {}", yn(report.permanent_matches_local_recompute));

    let all_ok = report.session_deterministic
        && report.permanent_deterministic
        && report.modes_separated
        && report.permanent_matches_local_recompute;
    if all_ok {
        println!();
        println!("motuhake: PASS — all four canonical properties hold");
        Ok(())
    } else {
        println!();
        println!("motuhake: FAIL — at least one canonical property broken");
        Err("motuhake_fail".into())
    }
}

fn parse_hex_word256(s: &str) -> Result<pipe_host::l3::Word256, String> {
    let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    let cleaned = cleaned.trim_start_matches("G#");
    if cleaned.is_empty() {
        return Ok([0u8; 32]);
    }
    if cleaned.len() != 64 {
        return Err(format!(
            "expected 64 hex chars (32 bytes), got {}",
            cleaned.len()
        ));
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&cleaned[2 * i..2 * i + 2], 16)
            .map_err(|e| format!("bad hex at byte {i}: {e}"))?;
    }
    Ok(out)
}

fn hex_word256(w: &pipe_host::l3::Word256) -> String {
    let mut s = String::with_capacity(64);
    for b in w {
        use std::fmt::Write;
        write!(&mut s, "{:02x}", b).unwrap();
    }
    s
}

fn yn(b: bool) -> &'static str {
    if b {
        "PASS"
    } else {
        "FAIL"
    }
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

/// `load_dev <path-to-elf-or-bin>` — hot-load a dev image into bridge SRAM via the
/// running manager firmware (no PICOBOOT, no chip reset, no boot ROM dance). Flow:
/// objcopy ELF → flat binary if needed; BLAKE3-hash it; send a `load_dev` VSF cmd
/// carrying size + hash; on `load_dev_ready` ack, stream raw bytes back-to-back over
/// the same CDC link; manager reads back SRAM, BLAKE3-verifies, jumps to vector_table[1]
/// with SP from vector_table[0]. USB disconnect = success — re-enumeration brings up
/// the dev image, which we then ping (with retries) to confirm.
fn cmd_load_dev(port_path: &str, args: &[String]) -> Result<(), String> {
    let src_path = args.first().ok_or("usage: bridge load_dev <path/to/elf-or-bin>")?;
    let src_path = std::path::Path::new(src_path);
    if !src_path.exists() {
        return Err(format!("image not found: {}", src_path.display()));
    }

    // Reset the bridge to flash manager BEFORE streaming. The dev image's load_dev
    // handler lives in SRAM 0x20004600+ (~11 KB long) — the first 17% of the dev
    // image's text. Streaming bytes linearly into 0x20000000+ overwrites the handler
    // while it's still running the receive loop, which wedges the chip in random
    // ways. Manager-in-flash doesn't have this race: its code is at 0x10000000+,
    // physically separate from the SRAM region being written. One reset adds ~3 sec
    // per hot-reload but makes load_dev fully reliable. See git log for the binary
    // address analysis (llvm-nm on the dispatch symbol).
    let port_pb = std::path::PathBuf::from(port_path);
    if port_pb.exists() {
        print!("→ reset to flash manager ");
        let _ = std::io::stdout().flush();
        // Best-effort reset. If the bridge is already wedged the send_cmd will fail —
        // that's fine, we still wait for the port and assume the user power-cycled.
        let _ = send_cmd(port_path, "reset", 7, vec![]);
        // Wait for the device to disappear (USB disconnect after reset).
        let disappear_deadline = Instant::now() + Duration::from_secs(3);
        while port_pb.exists() && Instant::now() < disappear_deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        // Wait for the device to come back as the manager.
        wait_for(
            Instant::now() + Duration::from_secs(10),
            || if port_pb.exists() { Some(()) } else { None },
            "serial device after reset",
        )?;
        // CDC settling — first ping may race the DTR/RTS handshake.
        let manager_deadline = Instant::now() + Duration::from_secs(10);
        let mut delay_ms = 200u64;
        loop {
            if try_ping_short(port_path).is_ok() {
                break;
            }
            if Instant::now() > manager_deadline {
                return Err("manager didn't pong after reset".to_string());
            }
            std::thread::sleep(Duration::from_millis(delay_ms));
            delay_ms = (delay_ms * 3 / 2).min(800);
        }
        println!("(ready)");
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
    // size (≤ 176 KiB) and replies load_dev_ready before we stream a single byte.
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
        return Err(format!("manager rejected load_dev: {err}"));
    }
    if resp_ascii(&section, "op") != Some("load_dev_ready") {
        return Err("manager did not ack with load_dev_ready".into());
    }

    // Phase 2: stream the image bytes over the same CDC link. The manager is in a
    // tight `class.read_packet` loop; we just push the bytes thru. open_port
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

    // The manager will either commit (USB disconnect = success) or send a final
    // error response (hash_mismatch / disconnect / flash_*). Drop the long stream
    // timeout to 100ms here so the wall-clock deadline-check actually fires —
    // otherwise each port.read would block the full open_port timeout (150s) and
    // we'd never get past the drain loop. flash_dev is slow (erase ~440 ms + write
    // ~700 ms before sys_reset), so the deadline has to cover that whole window
    // or we'd race the commit and falsely succeed.
    let _ = port.set_timeout(Duration::from_millis(100));
    let mut err_buf = Vec::with_capacity(128);
    let mut chunk = [0u8; 128];
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match port.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                err_buf.extend_from_slice(&chunk[..n]);
                if err_buf.last() == Some(&b']') {
                    break;
                }
            }
            Err(e) if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::BrokenPipe) => {
                // TimedOut just means no bytes in this 100ms window — keep waiting
                // until the wall-clock deadline. BrokenPipe means disconnect, which
                // for flash_dev is the expected commit signal.
                if matches!(e.kind(), std::io::ErrorKind::BrokenPipe) {
                    break;
                }
            }
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

    // After re-enumeration, the host kernel's CDC layer may still be settling — the
    // first ping can race the DTR/RTS handshake and hang on a stale fd. Each attempt
    // uses a short port read timeout so a single failed try doesn't burn the full
    // 150 s open_port budget; the outer loop retries with backoff until either a
    // pong lands or the wall-clock deadline expires.
    println!("→ verifying with ping");
    let ping_deadline = Instant::now() + Duration::from_secs(15);
    let mut delay_ms = 200u64;
    loop {
        if try_ping_short(port_path).is_ok() {
            break;
        }
        if Instant::now() >= ping_deadline {
            return Err("ping after load_dev: never got pong".into());
        }
        std::thread::sleep(Duration::from_millis(delay_ms));
        delay_ms = (delay_ms * 2).min(2000);
    }
    println!("load_dev: success");
    Ok(())
}

/// Short-timeout ping for the post-commit retry loop. Opens the port with a 500ms
/// read timeout (vs open_port's 150s) so a stuck attempt fails fast and the caller
/// can back off and retry instead of burning the whole budget on one stale fd.
fn try_ping_short(port_path: &str) -> Result<(), String> {
    let mut port = serialport::new(port_path, 115_200)
        .timeout(Duration::from_millis(500))
        .open()
        .map_err(|e| format!("open: {e}"))?;
    let req = build_cmd_doc("ping", 1, vec![])?;
    port.write_all(&req).map_err(|e| format!("write: {e}"))?;
    let mut resp = Vec::with_capacity(256);
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
            Err(_) => break,
        }
    }
    if resp.is_empty() {
        return Err("no response".into());
    }
    let section = parse_resp(&resp)?;
    if resp_ascii(&section, "op") != Some("pong") {
        return Err("no pong".into());
    }
    Ok(())
}
