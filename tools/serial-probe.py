#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Probe a USB CDC-ACM serial port: open raw, run commands, print output.

Usage: serial-probe.py PORT [--timeout SEC] [cmd ...]
Uses only the stdlib (no pyserial) so it runs on a bare macOS/Linux host.
"""
import os
import select
import sys
import termios
import time
import tty


def open_port(port: str) -> int:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def drain(fd: int, seconds: float) -> str:
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except (BlockingIOError, OSError):
            continue
        if not chunk:
            break
        buf += chunk
    return buf.decode("utf-8", "replace")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    port = sys.argv[1]
    timeout = 3.0
    commands = []
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--timeout":
            timeout = float(args[i + 1])
            i += 2
            continue
        commands.append(args[i])
        i += 1

    fd = open_port(port)
    try:
        os.write(fd, b"\n")
        time.sleep(0.5)
        print(drain(fd, 1.0), end="")
        for cmd in commands:
            os.write(fd, (cmd + "\n").encode())
            sys.stdout.write(drain(fd, timeout))
            sys.stdout.flush()
        if not commands:
            sys.stdout.write(drain(fd, timeout))
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
