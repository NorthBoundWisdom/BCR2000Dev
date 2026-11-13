#!/usr/bin/env python3
"""Time one read-only BCR2000 transfer for marquee observation (PLAN G1).

Sends only request SysEx (identity, snapshot, preset names, preset dump), or
nothing at all in listen mode, and prints frame counts and timing. Reply contents are never printed or saved.

slow-lock is the one write: it requires --confirm-write and sends only the fixed, idempotent
`$rev R1` / `$preset` / `.lock on` x N / `$end` at a slow pace, one acknowledged line at a time,
so an observer can count marquee steps per written line. Run it only when the temporary preset
already has `.lock on`; it never stores or recalls a preset.
"""

import argparse
import json
import sys
import time

from bcr_protocol import identity_info
from macos_bcr_roundtrip import MacBCR
from midi_feedback_probe import resolve

OPERATIONS = ("identity", "snapshot", "names", "temp", "stored", "listen", "slow-lock")


def request(operation, device, preset):
    header = [0xF0, 0, 0x20, 0x32, device, 0x15]
    body = {
        "identity": [0x01],
        "snapshot": [0x43],
        "names": [0x42, 0x7E],
        "temp": [0x40, 0x7F],
        "stored": [0x40, preset],
    }[operation]
    return bytes(header + body + [0xF7])


def is_end(frame):
    return frame[9:-1].strip() == b"$end"


def phases(frames, stamps):
    """Split device replies into runs of write acknowledgements and dump lines.

    Acknowledgements are the 11-byte 0x21 replies to each written BCL line;
    other replies are dump/name lines. Only counts, timing and error-code totals
    are reported, never line content.
    """
    runs = []
    for frame, stamp in zip(frames, stamps):
        kind = "ack" if len(frame) == 11 and frame[6] == 0x21 else "line"
        if not runs or runs[-1]["kind"] != kind or stamp - runs[-1]["last"] > 1.0:
            runs.append({"kind": kind, "first": stamp, "last": stamp, "count": 0, "errors": 0, "perSecond": {}})
        run = runs[-1]
        run["count"] += 1
        run["last"] = stamp
        if kind == "ack" and frame[9] != 0:
            run["errors"] += 1
        bucket = int(stamp - run["first"])
        run["perSecond"][bucket] = run["perSecond"].get(bucket, 0) + 1
    origin = stamps[0] if stamps else 0
    return [
        {
            "kind": run["kind"],
            "startS": round(run["first"] - origin, 2),
            "count": run["count"],
            "spanS": round(run["last"] - run["first"], 2),
            "perS": round((run["count"] - 1) / (run["last"] - run["first"]), 1) if run["last"] > run["first"] else None,
            "errors": run["errors"],
            "countsPerSecond": [run["perSecond"].get(i, 0) for i in range(max(run["perSecond"]) + 1)],
        }
        for run in runs
    ]


def listen(args):
    """Passively timestamp replies while the App writes; sends nothing."""
    backend = MacBCR()
    try:
        source = resolve(backend.ports(True), args.input, "input")
        backend.open(source, None)
        print(f"Listening up to {args.timeout:.0f} s; sends nothing.", file=sys.stderr, flush=True)
        stamps, deadline, last = [], time.monotonic() + args.timeout, None
        while time.monotonic() < deadline:
            backend.collect(0.01)
            now = time.monotonic()
            count = len(backend.frames.frames)
            if count > len(stamps):
                stamps.extend([now] * (count - len(stamps)))
                last = now
            if last is not None and now - last > args.quiet:
                break
        if backend.events.dropped:
            raise RuntimeError("MIDI input overflow")
        print(
            json.dumps({"operation": "listen", "frames": len(stamps), "phases": phases(backend.frames.frames, stamps)}),
            flush=True,
        )
    finally:
        backend.close()


def slow_lock(backend, device, args):
    lines = ["$rev R1", "$preset"] + [".lock on"] * args.lines + ["$end"]
    stamps = []
    for index, line in enumerate(lines):
        backend.collect(0.01)
        start = len(backend.frames.frames)
        frame = bytes([0xF0, 0, 0x20, 0x32, device, 0x15, 0x20, index >> 7, index & 0x7F]) + line.encode() + b"\xf7"
        sent = time.monotonic()
        backend._send_bytes(frame)
        while True:
            backend.collect(0.005)
            acks = [
                f for f in backend.frames.frames[start:] if len(f) == 11 and f[6] == 0x21 and f[7] * 128 + f[8] == index
            ]
            if acks:
                if acks[0][9] != 0:
                    raise RuntimeError(f"Line {index} rejected with error {acks[0][9]}")
                break
            if time.monotonic() - sent > 2:
                raise RuntimeError(f"No acknowledgement for line {index}")
        stamps.append(round(time.monotonic() - sent, 3))
        print(f"line {index + 1}/{len(lines)} acknowledged", file=sys.stderr, flush=True)
        if index + 1 < len(lines):
            time.sleep(args.interval)
    print(
        json.dumps({"operation": "slow-lock", "lines": len(lines), "intervalS": args.interval, "ackS": stamps}),
        flush=True,
    )


def run(args):
    if args.operation == "listen":
        return listen(args)
    if args.operation == "slow-lock" and not args.confirm_write:
        raise ValueError("slow-lock writes the device; pass --confirm-write")
    backend = MacBCR()
    try:
        source = resolve(backend.ports(True), args.input, "input")
        destination = resolve(backend.ports(False), args.output, "output")
        backend.open(source, destination)
        _, replies = backend.query(1, 1)
        identities = [info for frame in replies if (info := identity_info(frame)) is not None]
        if len(identities) != 1:
            raise ValueError("Expected exactly one BCR2000 identity response")
        device = identities[0]["deviceID"]
        for remaining in range(args.countdown, 0, -1):
            print(f"{remaining}…", file=sys.stderr, flush=True)
            time.sleep(1)
        backend.collect(0.1)
        if args.operation == "slow-lock":
            return slow_lock(backend, device, args)
        start = len(backend.frames.frames)
        stamps = []
        sent = time.monotonic()
        backend._send_bytes(request(args.operation, device, args.preset))
        deadline = sent + args.timeout
        quiet_after = None
        messages = 0
        while time.monotonic() < deadline:
            messages += len(backend.collect(0.01))
            now = time.monotonic()
            count = len(backend.frames.frames) - start
            if count > len(stamps):
                stamps.extend([now] * (count - len(stamps)))
                quiet_after = now
            frames = backend.frames.frames[start:]
            if args.operation in ("names", "temp", "stored") and frames and is_end(frames[-1]):
                break
            if quiet_after is not None and now - quiet_after > args.quiet:
                break
            if quiet_after is None and messages and now - sent > args.quiet:
                break
        if backend.events.dropped:
            raise RuntimeError("MIDI input overflow")
        report = {
            "operation": args.operation,
            "frames": len(stamps),
            "ccMessages": messages,
            "firstReplyS": round(stamps[0] - sent, 3) if stamps else None,
            "spanS": round(stamps[-1] - stamps[0], 3) if len(stamps) > 1 else 0,
            "framesPerS": round((len(stamps) - 1) / (stamps[-1] - stamps[0]), 1)
            if len(stamps) > 1 and stamps[-1] > stamps[0]
            else None,
            "reachedEnd": bool(stamps) and is_end(backend.frames.frames[start + len(stamps) - 1]),
        }
        print(json.dumps(report), flush=True)
    finally:
        backend.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=OPERATIONS)
    parser.add_argument("--preset", type=int, default=0, help="stored preset index 0-31 (stored only)")
    parser.add_argument("--input", type=int)
    parser.add_argument("--output", type=int)
    parser.add_argument("--countdown", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=45)
    parser.add_argument("--lines", type=int, default=20, help="slow-lock: number of .lock on lines (1-60)")
    parser.add_argument("--interval", type=float, default=2, help="slow-lock: seconds between lines (0.5-5)")
    parser.add_argument("--confirm-write", action="store_true", help="required for slow-lock")
    parser.add_argument("--quiet", type=float, default=1.5, help="stop after this many silent seconds")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native macOS probe required")
    if not 1 <= args.lines <= 60 or not 0.5 <= args.interval <= 5:
        parser.error("Invalid slow-lock lines or interval")
    if not 0 <= args.preset <= 31 or not 0 <= args.countdown <= 10:
        parser.error("Invalid preset or countdown")
    run(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
