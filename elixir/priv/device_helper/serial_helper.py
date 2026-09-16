#!/usr/bin/env python3
"""Symphony serial capture helper.

Started by Symphony as an Elixir Port. Reads one JSON request per line on
stdin and writes one JSON frame per line on stdout; diagnostics go to stderr so
stdout stays a pure JSONL protocol.

Raw bytes are never decoded before transport: every read is base64-encoded as
it came off the wire, so invalid UTF-8 survives the trip and the display text is
a derived view built later, not the stored evidence.
"""

from __future__ import annotations

import base64
import json
import os
import queue
import sys
import threading
import time

try:
    import serial
    from serial import SerialException
except ImportError:  # pragma: no cover - reported as a protocol error instead
    serial = None

    class SerialException(Exception):
        pass


MAX_PAYLOAD_BYTES = 64 * 1024
READ_CHUNK_BYTES = 4096
# The port is polled rather than blocked on, so stdin stays responsive and a
# burst cannot delay control requests behind a full read timeout.
POLL_INTERVAL_SECONDS = 0.02


def monotonic_ns() -> int:
    return time.monotonic_ns()


def now_utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Session:
    """One open capture session on one serial port."""

    def __init__(self, session_id: str, port, config: dict):
        self.session_id = session_id
        self.port = port
        self.config = config
        self.seq = 0
        self.closed = False

    def next_seq(self) -> int:
        self.seq += 1
        return self.seq

    def frame(self, kind: str, **fields) -> dict:
        base = {
            "kind": kind,
            "session_id": self.session_id,
            "source_seq": self.next_seq(),
            "received_at": now_utc(),
            "monotonic_ns": monotonic_ns(),
        }
        base.update(fields)
        return base

    def data_frame(self, payload: bytes) -> dict:
        return self.frame("data", payload_base64=base64.b64encode(payload).decode("ascii"))

    def gap_frame(self, reason: str, from_seq, to_seq) -> dict:
        return self.frame("gap", from_seq=from_seq, to_seq=to_seq, reason=reason)

    def state_frame(self, state: str, detail: str) -> dict:
        return self.frame("state", state=state, detail=detail)


class HostGone(Exception):
    """Raised when the host closed the pipe we report on."""


class Helper:
    def __init__(self, out):
        self.out = out
        self.session: Session | None = None

    # ---------------------------------------------------------------- protocol

    def emit(self, frame: dict) -> None:
        try:
            self.out.write(json.dumps(frame, separators=(",", ":")) + "\n")
            self.out.flush()
        except (BrokenPipeError, ValueError) as error:
            # The host went away. There is nobody left to report to, so stop
            # rather than writing a traceback into a closed pipe.
            raise HostGone(str(error)) from error

    def respond(self, request_id: str, status: str, error=None) -> None:
        self.emit({"kind": "response", "request_id": request_id, "status": status, "error": error})

    def handle(self, request: dict) -> bool:
        """Handle one request; returns False when the helper should exit."""
        request_id = request.get("request_id", "")
        command = request.get("command")

        if command == "open":
            self.respond(request_id, *self.open_port(request.get("payload") or {}))
        elif command == "close":
            self.respond(request_id, *self.close_port(request.get("payload") or {}))
        elif command == "write":
            self.respond(request_id, *self.write_port(request.get("payload") or {}))
        elif command == "ping":
            self.respond(request_id, "ok")
        elif command == "exit":
            self.close_port({"session_id": (self.session.session_id if self.session else "")})
            self.respond(request_id, "ok")
            return False
        else:
            self.respond(request_id, "error", "unknown command: %s" % command)

        return True

    # ----------------------------------------------------------------- session

    def open_port(self, payload: dict):
        if serial is None:
            return "error", "pyserial is not available in this environment"

        if self.session is not None:
            return "error", "a session is already open in this helper"

        session_id = payload.get("session_id")
        port_name = payload.get("port")

        if not session_id or not port_name:
            return "error", "open requires session_id and port"

        try:
            port = serial.Serial(
                port=port_name,
                baudrate=int(payload.get("baudrate", 115200)),
                bytesize=int(payload.get("bytesize", 8)),
                parity=str(payload.get("parity", "N")),
                stopbits=float(payload.get("stopbits", 1)),
                timeout=max(int(payload.get("read_timeout_ms", 100)), 1) / 1000.0,
            )
        except (SerialException, ValueError, OSError) as error:
            return "error", "open failed: %s" % error

        self.session = Session(session_id, port, payload)
        self.emit(self.session.state_frame("connected", "port %s opened" % port_name))
        return "ok", None

    def close_port(self, payload: dict):
        session = self.session

        if session is None:
            return "ok", None

        if payload.get("session_id") and payload["session_id"] != session.session_id:
            return "error", "session_id does not match the open session"

        self.session = None
        try:
            session.port.close()
        except Exception as error:  # noqa: BLE001 - closing must never crash the helper
            print("close failed: %s" % error, file=sys.stderr)

        self.emit(session.state_frame("disconnected", "port closed"))
        return "ok", None

    def write_port(self, payload: dict):
        session = self.session

        if session is None:
            return "error", "no open session"

        data = payload.get("data_base64")
        if not isinstance(data, str):
            return "error", "write requires data_base64"

        try:
            session.port.write(base64.b64decode(data, validate=True))
        except Exception as error:  # noqa: BLE001 - reported as a protocol error
            self.emit(session.state_frame("error", "write failed: %s" % error))
            return "error", "write failed: %s" % error

        return "ok", None

    # ------------------------------------------------------------------ reading

    def pump(self) -> None:
        """Read whatever the port has and emit it as data or gap frames."""
        session = self.session
        if session is None or session.closed:
            return

        try:
            waiting = session.port.in_waiting
        except Exception as error:  # noqa: BLE001 - a lost port is a disconnect
            self.mark_disconnected(session, "in_waiting failed: %s" % error)
            return

        if not waiting:
            return

        dropped = 0

        while waiting > 0:
            try:
                chunk = session.port.read(min(waiting, READ_CHUNK_BYTES))
            except Exception as error:  # noqa: BLE001
                self.mark_disconnected(session, "read failed: %s" % error)
                return

            if not chunk:
                break

            # A single frame is capped, so a burst is split rather than dropped;
            # anything that still cannot be sent is reported as an explicit gap.
            if len(chunk) > MAX_PAYLOAD_BYTES:
                for offset in range(0, len(chunk), MAX_PAYLOAD_BYTES):
                    self.emit(session.data_frame(chunk[offset : offset + MAX_PAYLOAD_BYTES]))
            else:
                self.emit(session.data_frame(chunk))

            try:
                waiting = session.port.in_waiting
            except Exception:  # noqa: BLE001
                waiting = 0

        if dropped:
            self.emit(session.gap_frame("helper buffer overflow", None, None))

    def mark_disconnected(self, session: Session, detail: str) -> None:
        self.session = None
        try:
            session.port.close()
        except Exception:  # noqa: BLE001
            pass

        self.emit(session.state_frame("disconnected", detail))

    def run(self) -> int:
        try:
            return self.serve()
        except HostGone:
            self.close_port({})
            return 0

    def serve(self) -> int:
        pending = queue.Queue()

        # stdin is read on its own thread: `readline` buffers ahead, so polling
        # the descriptor directly would miss requests that are already in the
        # interpreter's buffer and the host would wait forever for a reply.
        reader = threading.Thread(target=read_requests, args=(pending,), daemon=True)
        reader.start()

        while True:
            # Drain the port on every tick, whether or not a request arrived.
            self.pump()

            try:
                line = pending.get(timeout=POLL_INTERVAL_SECONDS)
            except queue.Empty:
                continue

            if line is None:
                # stdin closed: the host went away, so stop capturing instead of
                # holding the port open.
                self.close_port({})
                return 0

            line = line.strip()
            if not line:
                continue

            try:
                request = json.loads(line)
            except json.JSONDecodeError as error:
                print("ignoring unparsable request: %s" % error, file=sys.stderr)
                continue

            if not isinstance(request, dict):
                print("ignoring non-object request", file=sys.stderr)
                continue

            if not self.handle(request):
                return 0


def read_requests(pending: "queue.Queue") -> None:
    for line in sys.stdin:
        pending.put(line)

    pending.put(None)


def main() -> int:
    helper = Helper(sys.stdout)

    try:
        return helper.run()
    except KeyboardInterrupt:  # pragma: no cover - interactive use only
        return 130
    finally:
        # The host may have closed the pipe already; point the wrapper at
        # devnull so the interpreter's final flush does not write a traceback
        # into a stream nobody is reading.
        try:
            sys.stdout = open(os.devnull, "w")  # noqa: SIM115 - process is exiting
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())