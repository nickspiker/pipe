//! Host-side PIPE protocol smoke test.
//!
//! Talks to `top_pipe_codec.v` via FT232H MPSSE in batched form: one big USB
//! write programs an entire run (drive + sample + drive + sample × N) at
//! slot-rate timing using MPSSE "Clock For N Bytes" as a precise delay
//! primitive. Reads the queued GET_BITS_LOW responses back, walks them
//! through `Codec::host()`, and prints decoded bytes.
//!
//! Sequence:
//!   1. Sample 64 slots with host driving 0 (idle) — verify wire shows the
//!      enclave's 1010 idle pattern.
//!   2. Inject host_tx=1 at slot 64 and idle thereafter — verify the
//!      enclave's echo (tx_data <- rx_data) shifts subsequent slot
//!      emissions, and that the host codec recovers the response bit.

use pipe_host::codec::Codec;
use pipe_host::ft232h::{Ft232h, PIPE_PIN_MASK};
use std::time::Duration;

const MPSSE_CLOCK_HZ: u32 = 6_000_000;
const PAIR_SLOTS: usize = 32;      // 32 enclave+host pairs = 64 total slots
const INJECT_AT: usize = 16;       // host injects a 1 at this slot index

const MPSSE_SET_BITS_LOW: u8 = 0x80;
const MPSSE_GET_BITS_LOW: u8 = 0x81;
const MPSSE_CLOCK_BYTES: u8 = 0x8F;
const MPSSE_SEND_IMMEDIATE: u8 = 0x87;

fn clock_for(bytes: u16) -> [u8; 3] {
    let n = bytes - 1;
    [MPSSE_CLOCK_BYTES, (n & 0xFF) as u8, ((n >> 8) & 0xFF) as u8]
}

fn calibrate_half_slot_bytes(ft: &mut Ft232h) -> Result<u16, ftdi_nusb::Error> {
    // Sample 4096 bytes back-to-back. Each GET_BITS_LOW in this batch takes
    // a fixed number of MPSSE cycles; measure the *average bit period* on
    // ADBUS7 (the wire) to figure out how many GET_BITS_LOW commands
    // correspond to one FPGA half-slot.
    // Build a chunked sample stream that fits the FT232H's TX FIFO (~1 KB).
    let mut samples = Vec::new();
    for _ in 0..4 {
        let chunk = ft.sample_low(256)?;
        if chunk.is_empty() {
            break;
        }
        samples.extend_from_slice(&chunk);
    }
    if samples.len() < 64 {
        return Ok(8);
    }
    // Skip head (may contain 0xFA badcmd echo), then find edges on bit 7.
    let valid = &samples[16..];
    let mask = 1u8 << 7;
    let mut prev = valid[0] & mask;
    let mut edge_positions = Vec::new();
    for (i, &b) in valid.iter().enumerate().skip(1) {
        let cur = b & mask;
        if cur != prev {
            edge_positions.push(i);
            prev = cur;
        }
    }
    if edge_positions.len() < 4 {
        eprintln!("Calibration: only {} edges; using default 8", edge_positions.len());
        return Ok(8);
    }
    // Mean gap between edges = number of GET_BITS_LOW per half-slot.
    let mut gaps: Vec<usize> = edge_positions.windows(2).map(|w| w[1] - w[0]).collect();
    gaps.sort();
    let median_gap = gaps[gaps.len() / 2];
    eprintln!(
        "Calibration: {} edges across {} samples, median gap = {} samples/half-slot",
        edge_positions.len(),
        valid.len(),
        median_gap
    );
    // The MPSSE Clock-For-N-Bytes command and the GET_BITS_LOW command are
    // each one byte-time on the chip, so 1 GET_BITS_LOW + N+1 "clock-for"
    // byte cycles takes N+2 byte times. Use one Clock-For-N command to
    // generate a delay equal to the median gap, accounting for the
    // GET_BITS_LOW byte itself (≈ 1).
    let half = median_gap.saturating_sub(1).max(1) as u16;
    eprintln!("→ half_slot_bytes = {}", half);
    Ok(half)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut ft = Ft232h::open(MPSSE_CLOCK_HZ)?;
    eprintln!("FT232H MPSSE @ {} MHz", ft.mpsse_clock_hz() / 1_000_000);

    // Drain MPSSE pipeline of any 0xFA bad-cmd echoes from sync_mpsse.
    let _ = ft.sample_low(64)?;

    let half_slot_bytes = calibrate_half_slot_bytes(&mut ft)?;

    // ---- Build the command sequence ------------------------------------
    // Each slot pair:
    //   * Host slot: SET_BITS_LOW drive(host_tx) PIPE_PIN_MASK,
    //                Clock For half_slot_bytes,
    //                SET_BITS_LOW 0 0 (release),
    //                Clock For half_slot_bytes.
    //   * Enclave slot: GET_BITS_LOW,
    //                Clock For half_slot_bytes,
    //                GET_BITS_LOW,
    //                Clock For half_slot_bytes.
    //   The enclave-slot samples bracket the slot so we can correlate
    //   phase. The first GET captures the early enclave drive; the second
    //   captures the late enclave drive (after host released).

    let mut cmds: Vec<u8> = Vec::new();
    let mut host_codec = Codec::host();
    let mut host_drives: Vec<u8> = Vec::with_capacity(PAIR_SLOTS);

    // Each per-loop iteration uses 4 delay commands + 2 SET_BITS_LOW + 2
    // GET_BITS_LOW. SET_BITS_LOW and GET_BITS_LOW take ~1 byte cycle each;
    // Clock-For-N takes ~(N+2) byte cycles. We want total per-iter to equal
    // exactly 2 × FPGA slot = 4 × half_slot_bytes byte cycles, so each
    // delay's `bytes` arg should be half_slot_bytes - 1 (so its execution
    // time is half_slot_bytes; the 4 setup cycles for SET/GET commands
    // amount to the slack absorbed by leaving N slightly under target).
    // The calibration counts MPSSE *clock* cycles per half-slot (each
    // GET_BITS_LOW takes 1 clock cycle). Clock-For-N+1 generates (N+1)×8
    // MPSSE clock cycles, plus ~1 cycle command setup. SET_BITS_LOW and
    // GET_BITS_LOW also take 1 clock cycle each.
    //
    // Per loop iteration: 4 cmds (~4 clock cycles) + 4 waits. To total
    // exactly 2 × half_slot_clocks × 2 = 4 × half_slot_clocks, each wait
    // should consume (half_slot_clocks - 1) clock cycles → bytes value
    // is round((half_slot_clocks - 1) / 8) - 1 (since each clock_for(bytes)
    // generates 8*bytes clock cycles + 1 cmd cycle = 8*bytes + 1).
    let half_clocks = half_slot_bytes as u32; // calibration is in clock cycles
    let target_wait_clocks = half_clocks.saturating_sub(1); // leave 1 cycle for the framing cmd
    let bytes = (target_wait_clocks / 8).max(1) as u16;
    let delay_bytes = bytes;
    eprintln!(
        "half-slot ≈ {} clock cycles → delay_bytes = {} (≈ {} clock cycles per wait)",
        half_clocks,
        delay_bytes,
        delay_bytes as u32 * 8 + 1
    );

    for i in 0..PAIR_SLOTS {
        let host_tx = if i == INJECT_AT { 1u8 } else { 0u8 };
        let wire_drive = host_codec.tx(host_tx);
        host_drives.push(wire_drive);

        let drive_value = if wire_drive != 0 { PIPE_PIN_MASK } else { 0 };

        // Host slot: drive, wait half-slot, release, wait half-slot.
        cmds.extend_from_slice(&[MPSSE_SET_BITS_LOW, drive_value, PIPE_PIN_MASK]);
        cmds.extend_from_slice(&clock_for(delay_bytes));
        cmds.extend_from_slice(&[MPSSE_SET_BITS_LOW, 0x00, 0x00]);
        cmds.extend_from_slice(&clock_for(delay_bytes));

        // Enclave slot: tristate (input), sample twice.
        cmds.extend_from_slice(&[MPSSE_GET_BITS_LOW]);
        cmds.extend_from_slice(&clock_for(delay_bytes));
        cmds.extend_from_slice(&[MPSSE_GET_BITS_LOW]);
        cmds.extend_from_slice(&clock_for(delay_bytes));
    }
    cmds.push(MPSSE_SEND_IMMEDIATE);

    eprintln!(
        "Built {} MPSSE bytes for {} slot pairs; expecting {} sample bytes back",
        cmds.len(),
        PAIR_SLOTS,
        PAIR_SLOTS * 2
    );

    // ---- Execute ------------------------------------------------------
    // ftdi-nusb's write_data tops out at writebuffer_chunksize per call;
    // for >65k bytes we'd need to chunk. We're well under that.
    use std::time::Instant;
    let t0 = Instant::now();
    ft_write_all(&mut ft, &cmds)?;
    let mut responses = vec![0u8; PAIR_SLOTS * 2];
    ft_read_exact(&mut ft, &mut responses, Duration::from_secs(5))?;
    let elapsed = t0.elapsed();
    eprintln!(
        "Executed in {:.1} ms, got {} response bytes",
        elapsed.as_secs_f64() * 1000.0,
        responses.len()
    );

    // ---- Decode -------------------------------------------------------
    // responses[2k]   = early sample of enclave slot k (right after host released)
    // responses[2k+1] = late sample of enclave slot k (well into the enclave drive)
    // Use the late sample for the codec's wire_in.
    let enclave_samples: Vec<u8> = responses
        .chunks_exact(2)
        .map(|p| (p[1] >> 7) & 1)
        .collect();

    let mut decoded_from_enc: Vec<u8> = Vec::with_capacity(PAIR_SLOTS);
    for &w in &enclave_samples {
        decoded_from_enc.push(host_codec.rx(w));
    }

    // ---- Report -------------------------------------------------------
    let idle_window = &enclave_samples[..INJECT_AT.min(enclave_samples.len())];
    let idle_ones = idle_window.iter().filter(|&&b| b == 1).count();
    eprintln!(
        "Idle window: {}/{} samples high — expected ~all 1 (enclave idle drives 1)",
        idle_ones,
        idle_window.len()
    );

    println!("\nFirst 32 enclave samples (wire bits, '*' = injection slot):");
    for (i, &w) in enclave_samples.iter().take(32).enumerate() {
        let mark = if i == INJECT_AT { '*' } else { ' ' };
        print!("{}{}", w, mark);
    }
    println!();
    println!("Decoded RX (what host_codec thinks the enclave is sending):");
    for (i, &d) in decoded_from_enc.iter().take(32).enumerate() {
        let mark = if i == INJECT_AT { '*' } else { ' ' };
        print!("{}{}", d, mark);
    }
    println!();

    // Around the injection: did we see the enclave's echo?
    let start = INJECT_AT.saturating_sub(2);
    let end = (INJECT_AT + 8).min(enclave_samples.len());
    println!("\nAround injection (slot {}):", INJECT_AT);
    println!("  slot:        {}", (start..end).map(|i| format!("{:2}", i)).collect::<Vec<_>>().join(" "));
    println!("  host_drove:  {}", host_drives[start..end].iter().map(|b| format!(" {}", b)).collect::<Vec<_>>().join(" "));
    println!("  wire_late:   {}", enclave_samples[start..end].iter().map(|b| format!(" {}", b)).collect::<Vec<_>>().join(" "));
    println!("  decoded_rx:  {}", decoded_from_enc[start..end].iter().map(|b| format!(" {}", b)).collect::<Vec<_>>().join(" "));

    Ok(())
}

fn ft_write_all(ft: &mut Ft232h, cmds: &[u8]) -> Result<(), ftdi_nusb::Error> {
    let mut sent = 0;
    while sent < cmds.len() {
        let n = ft.write_bytes(&cmds[sent..])?;
        if n == 0 {
            break;
        }
        sent += n;
    }
    Ok(())
}

fn ft_read_exact(
    ft: &mut Ft232h,
    buf: &mut [u8],
    timeout: Duration,
) -> Result<(), ftdi_nusb::Error> {
    let deadline = std::time::Instant::now() + timeout;
    let mut got = 0;
    while got < buf.len() {
        if std::time::Instant::now() > deadline {
            eprintln!("ft_read_exact timeout; got {} of {}", got, buf.len());
            break;
        }
        let n = ft.read_bytes(&mut buf[got..])?;
        if n == 0 {
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }
        got += n;
    }
    Ok(())
}
