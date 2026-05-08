# PIPE host-side tools

PC-side software for talking to a PIPE-enabled FPGA. The host:

1. Watches the wire for the heartbeat (idle 1010 pattern).
2. Initiates a challenge by skipping a beat (host init bit = unexpected 0).
3. Sends challenge bits at the bit rate locked by its CDR.
4. Watches for the enclave's TX init (unexpected 1).
5. Receives 256 bits of MAC.
6. Verifies `MAC == BLAKE3_keyed(challenge || nonce, key)` against an enrolled key.

The host has no special clock relationship with the enclave — its CDR locks onto the heartbeat. Any clock difference within the CDR's drift margin (target A#125:1) is fine.

## Files (Phase A: stubs)

- `host.py` — entry point: idle watcher, challenge sender, MAC receiver
- `cdr_rx.py` — software CDR (8x oversample, early/late phase detector)
- `verify_mac.py` — keyed-BLAKE3 MAC verification against enrolled key

## Hardware

For early bringup the host talks to the enclave through whatever USB-serial bridge is convenient (FT232 etc). Once the protocol is solid, the long-term plan is a direct GPIO line on the host side too — with an optocoupler or galvanic isolator if the host is on a different power domain.
