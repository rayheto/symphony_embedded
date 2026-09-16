#!/usr/bin/env python3
"""PTY peer for the serial capture tests.

Opens a pseudo-terminal, prints the slave path, and then plays the device: the
test sends it bytes to push onto the wire and it can also close the slave to
simulate a USB disconnect. This is a *test* double — a PTY run never counts as a
board run.
"""

from __future__ import annotations

import base64
import os
import pty
import sys


def main() -> int:
    master, slave = pty.openpty()
    slave_path = os.ttyname(slave)

    sys.stdout.write("PORT %s\n" % slave_path)
    sys.stdout.flush()

    while True:
        line = sys.stdin.readline()
        if not line:
            break

        line = line.strip()
        if not line:
            continue

        command, _, argument = line.partition(" ")

        if command == "write":
            os.write(master, base64.b64decode(argument))
            sys.stdout.write("OK\n")
        elif command == "close":
            # Closing the master is what a yanked cable looks like from the
            # reader's side: the slave the helper holds now fails on the next
            # read instead of quietly reporting "nothing to read".
            os.close(master)
            sys.stdout.write("OK\n")
        elif command == "quit":
            break
        else:
            sys.stdout.write("ERR unknown command\n")

        sys.stdout.flush()

    try:
        os.close(master)
    except OSError:
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())