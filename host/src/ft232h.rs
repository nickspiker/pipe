//! FT232H wrapper for PIPE wire I/O via MPSSE.
//!
//! This board's FT232H has a blank/uninitialised EEPROM, so async bit-bang
//! mode doesn't deliver bulk IN data. MPSSE works (openFPGALoader uses it
//! for SVF programming). We sample/drive the wire by batching GET_BITS_LOW
//! and SET_BITS_LOW commands.
//!
//! Wiring (discovered by polling): FPGA pin E16 (bridged to F15) → 400 Ω →
//! header pin D7 → FT232H **ADBUS7**.

use ftdi_nusb::{mpsse::MpsseContext, BitMode, FtdiDevice};

pub const FT232H_VID: u16 = 0x0403;
pub const FT232H_PID: u16 = 0x6014;

/// ADBUS bit index the PIPE wire is connected to on this hardware.
pub const PIPE_ADBUS_BIT: u8 = 7;
pub const PIPE_PIN_MASK: u8 = 1 << PIPE_ADBUS_BIT;

const MPSSE_GET_BITS_LOW: u8 = 0x81;
const MPSSE_SEND_IMMEDIATE: u8 = 0x87;

pub struct Ft232h {
    dev: FtdiDevice,
    mpsse: MpsseContext,
}

impl Ft232h {
    /// Open the FT232H and initialise MPSSE at `clock_hz`. Resets the chip,
    /// disables event/error chars (which would otherwise corrupt the byte
    /// stream), and runs the MPSSE sync handshake to flush any residual
    /// state from prior MPSSE clients (e.g., openFPGALoader).
    pub fn open(clock_hz: u32) -> Result<Self, ftdi_nusb::Error> {
        let mut dev = FtdiDevice::open(FT232H_VID, FT232H_PID)?;
        dev.usb_reset()?;
        dev.set_bitmode(0, BitMode::Reset)?;
        dev.flush_all()?;
        dev.set_event_char(0, false)?;
        dev.set_error_char(0, false)?;
        dev.set_latency_timer(16)?;
        let mpsse = MpsseContext::init(&mut dev, clock_hz)?;
        std::thread::sleep(std::time::Duration::from_millis(50));
        dev.flush_all()?;
        // Force a known MPSSE state by exchanging the bad-command handshake.
        mpsse.sync_mpsse(&mut dev)?;
        Ok(Self { dev, mpsse })
    }

    /// Drive ADBUS pin directions and values on the low byte.
    /// `direction`: 1 bit per pin (1 = output, 0 = input).
    pub fn set_low(&mut self, value: u8, direction: u8) -> Result<(), ftdi_nusb::Error> {
        self.mpsse.set_gpio_low(&mut self.dev, value, direction)
    }

    /// Combine SET_BITS_LOW (configure dir + drive), then GET_BITS_LOW after a
    /// short MPSSE no-op, in a single USB write. Useful for "drive briefly,
    /// release, sample once" patterns where USB round-trip latency would
    /// otherwise miss the FPGA's response window. Returns the sampled byte.
    pub fn drive_then_sample(
        &mut self,
        drive_value: u8,
        drive_direction: u8,
    ) -> Result<u8, ftdi_nusb::Error> {
        const MPSSE_SET_BITS_LOW: u8 = 0x80;
        let cmd = [
            MPSSE_SET_BITS_LOW,
            drive_value,
            drive_direction,
            MPSSE_SET_BITS_LOW,
            0x00,
            0x00, // release: all inputs
            MPSSE_GET_BITS_LOW,
            MPSSE_SEND_IMMEDIATE,
        ];
        self.dev.write_data(&cmd)?;
        let mut buf = [0u8; 1];
        let mut got = 0;
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
        while got < 1 {
            if std::time::Instant::now() > deadline {
                break;
            }
            let r = self.dev.read_data(&mut buf)?;
            if r == 0 {
                std::thread::sleep(std::time::Duration::from_millis(1));
                continue;
            }
            got += r;
        }
        Ok(buf[0])
    }

    /// Hold an ADBUS configuration for `ms` milliseconds, then release all
    /// pins back to input.
    pub fn hold_drive(
        &mut self,
        value: u8,
        direction: u8,
        ms: u64,
    ) -> Result<(), ftdi_nusb::Error> {
        self.set_low(value, direction)?;
        std::thread::sleep(std::time::Duration::from_millis(ms));
        self.set_low(0x00, 0x00)?;
        Ok(())
    }

    /// Single-shot read of the 8 ADBUS pins (one USB round-trip, ~1 ms).
    pub fn read_low_once(&mut self) -> Result<u8, ftdi_nusb::Error> {
        self.mpsse.get_gpio_low(&mut self.dev)
    }

    /// Issue `count` back-to-back GET_BITS_LOW commands in a single MPSSE
    /// transaction (one USB write, then drain reads). At the FT232H's
    /// internal MPSSE rate this gives a continuous sample window — the
    /// chip's TX buffer (~1 KB) gates the chip but every byte returned
    /// represents an evenly-spaced sample. Returns the raw stream; the
    /// caller should be prepared for a couple of 0xFA-tagged bad-command
    /// echo bytes at the very start of the first call after `open()`.
    pub fn sample_low(&mut self, count: usize) -> Result<Vec<u8>, ftdi_nusb::Error> {
        if count == 0 {
            return Ok(Vec::new());
        }
        let mut cmds = Vec::with_capacity(count + 1);
        cmds.extend(std::iter::repeat(MPSSE_GET_BITS_LOW).take(count));
        cmds.push(MPSSE_SEND_IMMEDIATE);
        eprintln!("[sample_low] writing {} bytes", cmds.len());
        match self.dev.write_data(&cmds) {
            Ok(n) => eprintln!("[sample_low] wrote {}", n),
            Err(e) => {
                eprintln!("[sample_low] write err: {:?}", e);
                return Err(e);
            }
        }

        let mut out = vec![0u8; count];
        let mut got = 0;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while got < count {
            if std::time::Instant::now() > deadline {
                eprintln!("[sample_low] deadline; got {}/{}", got, count);
                break;
            }
            let r = match self.dev.read_data(&mut out[got..]) {
                Ok(n) => n,
                Err(e) => {
                    eprintln!("[sample_low] read err after {} got: {:?}", got, e);
                    return Err(e);
                }
            };
            if r == 0 {
                std::thread::sleep(std::time::Duration::from_millis(1));
                continue;
            }
            got += r;
        }
        out.truncate(got);
        Ok(out)
    }

    pub fn mpsse_clock_hz(&self) -> u32 {
        self.mpsse.clock_hz()
    }

    pub fn write_bytes(&mut self, buf: &[u8]) -> Result<usize, ftdi_nusb::Error> {
        self.dev.write_data(buf)
    }

    pub fn read_bytes(&mut self, buf: &mut [u8]) -> Result<usize, ftdi_nusb::Error> {
        self.dev.read_data(buf)
    }
}
