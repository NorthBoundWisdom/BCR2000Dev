#!/usr/bin/env python3
"""Render the audited display load evidence without hand-transcribing benchmark numbers."""

import argparse
import json
from pathlib import Path


def render(evidence):
    lines = [
        "# BCR status-panel display budget",
        "",
        "Real provider processes, Debug fake device, six target/rate conditions each running 60 seconds, plus an input-only baseline. Conditions run serially in isolated processes, not against real MIDI.",
        "The load map uses 24 logical IDs across three top-row groups to measure service throughput. It does not imply 24 top-row rings are simultaneously visible. Hardware has eight top-row rings in four groups and 24 fixed lower-row rings (32 physical, 56 logical display IDs).",
        "",
        "| Targets × Hz | Requests | Default accepted / quota refused | Explicit 300/s accepted / quota refused | 300/s request→fake p50 / p95 / p99 / max ms | 300/s input event→reader p50 / p95 / p99 / max ms |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    defaults = {(r["targets"], r["hz"]): r for r in evidence["default"]["conditions"]}
    for row in evidence["display300"]["conditions"]:
        before = defaults[(row["targets"], row["hz"])]
        for sample in (before, row):
            if (
                sample["errors"]
                or sample["other_rejections"]
                or sample["input_events_generated"] != sample["input_events_read"]
            ):
                raise ValueError("Incomplete or failed measurement is not a qualified budget result")
            if sample["accepted"] + sample["quota_rejected"] != sample["requests"]:
                raise ValueError("Request accounting differs")
        if not row["targets"]:
            continue

        def stats(value):
            return " / ".join(f"{value[k]:.3f}" for k in ("p50_ms", "p95_ms", "p99_ms", "max_ms"))

        lines.append(
            f"| {row['targets']} × {row['hz']} | {row['requests']} | {before['accepted']} / {before['quota_rejected']} | {row['accepted']} / {row['quota_rejected']} | {stats(row['request_to_fake_ms'])} | {stats(row['input_event_to_reader_ms'])} |"
        )
    base = evidence["display300"]["conditions"][0]
    ambiguous = sum(
        r["ambiguous_request_send_windows"]
        for group in ("default", "display300")
        for r in evidence[group]["conditions"]
    )
    lines += [
        "",
        "## Decision and use",
        "",
        "Choose the smallest mechanism change: the existing per-target mechanism is sufficient; add an explicit display-only startup quota. No batch contract, field or tool is added.",
        "`--display-write-limit 300` supports the measured 8–24 target 5–10 Hz workloads. The supported explicit range is 1..1000 requests/s. For the original three-role record, absent this flag the complete old aggregate budget path and default 60/s remain unchanged, including an existing `--write-limit` override. The optional extended multi-display record selects independent 60/s display buckets explicitly; see SURFACE_CLIENTS.md. The new flag requires private role provisioning via `--surface-client-tokens-stdin`; it changes only authenticated display writers, leaving owner/operator aggregate budgets and permissions unchanged.",
        "Begin at 5 Hz and increase to 10 Hz only as the consumer needs. Software quota is not the physical MIDI limit. An explicit high limit does not authorize new targets, inputs, motor output, preset changes or automatic lifecycle sends.",
        "The independent display bucket uses injected monotonic seconds. Nonfinite/backward clock values fail closed; wall-clock jumps do not refill it. The legacy aggregate path retains its original semantics.",
        "",
        "## Input service, journal and timing evidence",
        "",
        f"Every condition generated and read all {base['input_events_generated']} hardware input events. Input-only baseline with the explicit display setting: p50 {base['input_event_to_reader_ms']['p50_ms']:.3f} / p95 {base['input_event_to_reader_ms']['p95_ms']:.3f} / p99 {base['input_event_to_reader_ms']['p99_ms']:.3f} / max {base['input_event_to_reader_ms']['max_ms']:.3f} ms.",
        "The reader targeted 25 ms polling; raw poll start/end/count records give the actual cadence. Higher display rates increased some input latency tails, as shown above, but did not drop or gap any input in the measured runs. Each display condition also produced 300 existing input-triggered overlay refresh sends; those are accounted separately from accepted display requests.",
        f"All measured accepted display requests matched a fake receive; observed coalesced/missing sends = 0, ignored feedback = 0. {ambiguous} request windows across both complete runs contained more than one identical send because of an input-triggered refresh. Raw candidate timestamps are retained; the table uses the conservative last timestamp in such windows, not the most favorable candidate. Clock domains are Python monotonic and ProcessInfo.systemUptime; all matched deltas were finite and nonnegative.",
        "Feedback, including ignored feedback, uses the existing shared 1024-event FIFO journal and advances global sequence, never input_sequence. Therefore it can evict old input events if a reader falls behind. No separate input journal or hidden filtering is introduced. Poll continuously (100 ms or faster recommended here), preserve the global cursor, and fail closed/re-prepare on event_gap. At 240 feedback/s plus the measured 5 input/s, a 1024-event window is only about four seconds; this is not an offline history guarantee. Continuous reads saw every input throughout repeated journal wraps.",
        "Hardware aggregate quota exhaustion already returns `invalid_argument`, while simulation returns `rate_limited`; this F behavior is retained. The report keeps raw rejection codes. Quota attribution here uses known valid requests, the exact existing consumeWrites path and the high-quota comparison where the same workload has zero rejections; arbitrary invalid arguments must not be labeled quota errors.",
        "",
        "## Physical limit and limitations",
        "",
        "Reliable USB MIDI/device firmware maximum: **needs physical measurement**. A fake transport cannot establish loss/order limits. `H_STATUS_PANEL_ATTENDED.md` prepares the independent attended measurement; it is not executed by H.",
        "The first seven-host parallel attempt developed transport_unknown at about 39 seconds, including the input-only reader. Its raw files are preserved and it is not a passing performance result. The cause is unresolved; TIME_WAIT exhaustion is not established. The complete table instead uses a declared one-host-at-a-time plan. This does not qualify seven simultaneous hosts or predict multiple display clients' combined physical throughput.",
        "The complete precision values, input-only baselines, RTT/poll distributions, request/send matching counts, binary SHA/base/patch identities and raw-data hashes are in `status-panel-budget-evidence.json`. Runtime credentials are absent. Quantiles select floor((count-1)×p), without interpolation; milliseconds above are rounded to three decimals.",
        "",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content = render(json.loads(args.evidence.read_text()))
    if args.check:
        if args.output.read_text() != content:
            raise ValueError("Display budget documentation differs from evidence")
    else:
        args.output.write_text(content)
    print("Display budget evidence matches documentation")


if __name__ == "__main__":
    main()
