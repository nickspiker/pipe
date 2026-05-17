# pipe-bridge-rp2040

Dumb USB-CDC ↔ PIPE wire bridge for the Waveshare RP2040-Zero. Replaces the FT232H bit-bang bridge, which couldn't do the mirror-XOR codec's `wire = own_idle ^ tx_data ^ other_last` cycle-accurately at slot rate (USB latency murders the `other_last` feedback path).

## Hardware

- **Board**: Waveshare RP2040-Zero (RP2040, dual Cortex-M0+ @ 133 MHz, 2 MB QSPI flash, USB-C, ~18 × 23 mm)
- **Wire pin**: GP0 (Phase 1: plain GPIO. Phase 2: PIO-driven for mirror-XOR codec timing.)
- **GND**: shared with the ECP5 board (CRITICAL — single-wire resistive coupling requires a common ground reference per Claim 1e)
- **Series resistor**: 470 Ω in line on the wire (protects both ends if they momentarily drive opposite levels)

## Toolchain setup (one-time)

```bash
# 1. Cortex-M0+ target
rustup target add thumbv6m-none-eabi

# 2. UF2 converter (auto-flashes when the board is in BOOTSEL mode)
cargo install elf2uf2-rs
```

## Flash workflow

```bash
# 1. Hold BOOT on the RP2040-Zero
# 2. Plug USB-C into the host
# 3. Release BOOT — board enumerates as RPI-RP2 mass-storage device
# 4. From this directory:
cargo run --release
```

`elf2uf2-rs -d` auto-detects the `RPI-RP2` mount, converts the ELF to UF2, copies it across — the board reboots into the new firmware in ~2 seconds. After that, the board enumerates as `/dev/ttyACM0` (Linux) / `COMx` (Windows) / `/dev/cu.usbmodem*` (macOS).

To re-flash: hold BOOT, replug USB (or tap the on-board reset trace if you've soldered one in), then `cargo run --release` again.

## Phase 1: USB-CDC echo + GPIO bit-bang (this scaffold)

What it does:
- USB enumerates as a CDC ACM serial port
- Bytes received over USB are echoed back to the host
- Each received byte's bits drive GP0 (LSB-first, no precise timing yet)

Verifies: USB stack works, board doesn't brick, GP0 is driving the wire. Confirm with a logic analyzer or scope on GP0.

```bash
# Linux smoke test:
sudo screen /dev/ttyACM0 115200
# type 'a' — should echo back; GP0 should pulse 8 times
```

## Phase 2: PIO mirror-XOR codec (TODO)

Replace the bit-bang in `src/main.rs::echo` with a PIO state machine implementing the mirror-XOR codec from [`rtl/codec.v`](../../rtl/codec.v) and [`host/src/codec.rs`](../../host/src/codec.rs).

PIO timing budget:
- Slot rate ~50 kbps (slot period 20 µs)
- PIO clock = sys_clk = 125 MHz → 2,500 PIO cycles per slot
- Plenty of headroom to:
  1. Drive `wire = OWN_IDLE_HOST ^ tx_data ^ other_last`
  2. Sample wire mid-slot
  3. Decode `other_data = wire ^ other_idle ^ own_last`
  4. Update `own_last`, `other_last`

Approximate PIO program length: ~20-30 instructions per state machine. One SM per direction (encode + decode), or one SM doing both via interleaved schedule.

## Why the FT232H couldn't do this

The mirror-XOR codec's encode rule for slot N+1 depends on `other_last` (the bit just decoded from slot N). FT232H bit-bang is a USB-pipelined SPI/MPSSE engine: the host computes what to drive, queues it over USB, FT232H emits it. By the time the host reads back the result of slot N, multiple slots have elapsed.

PIO on the RP2040 runs the codec right next to the pin with deterministic cycle timing — perfect fit.
