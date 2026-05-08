#!/usr/bin/env python3
# host.py — PC-side PIPE driver. Phase A stub.
#
# Watches the wire for the heartbeat, sends challenges, receives MACs,
# verifies against an enrolled key.

import sys


def main():
    print("pipe/host: not yet implemented (Phase A scaffold).", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
