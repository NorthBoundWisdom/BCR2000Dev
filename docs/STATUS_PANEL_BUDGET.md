# BCR status-panel display budget

Real provider processes, Debug fake device, six target/rate conditions each running 60 seconds, plus an input-only baseline. Conditions run serially in isolated processes, not against real MIDI.
The load map uses 24 logical IDs across three top-row groups to measure service throughput. It does not imply 24 top-row rings are simultaneously visible. Hardware has eight top-row rings in four groups and 24 fixed lower-row rings (32 physical, 56 logical display IDs).

| Targets × Hz | Requests | Default accepted / quota refused | Explicit 300/s accepted / quota refused | 300/s request→fake p50 / p95 / p99 / max ms | 300/s input event→reader p50 / p95 / p99 / max ms |
| --- | --- | --- | --- | --- | --- |
| 8 × 5 | 2400 | 2400 / 0 | 2400 / 0 | 0.830 / 1.580 / 2.406 / 10.092 | 15.989 / 30.703 / 33.428 / 34.128 |
| 8 × 10 | 4800 | 3578 / 1222 | 4800 / 0 | 0.751 / 1.740 / 3.136 / 16.430 | 16.091 / 30.169 / 32.669 / 33.783 |
| 16 × 5 | 4800 | 3553 / 1247 | 4800 / 0 | 0.793 / 2.030 / 3.878 / 20.798 | 16.024 / 32.002 / 36.399 / 40.564 |
| 16 × 10 | 9600 | 3600 / 6000 | 9600 / 0 | 0.758 / 1.354 / 1.995 / 28.470 | 16.284 / 31.386 / 34.113 / 37.205 |
| 24 × 5 | 7200 | 3600 / 3600 | 7200 / 0 | 0.939 / 2.358 / 3.636 / 31.031 | 16.766 / 31.681 / 34.679 / 36.883 |
| 24 × 10 | 14400 | 3600 / 10800 | 14400 / 0 | 0.826 / 1.370 / 1.970 / 36.049 | 16.313 / 32.576 / 37.912 / 43.765 |

## Decision and use

Choose the smallest mechanism change: the existing per-target mechanism is sufficient; add an explicit display-only startup quota. No batch contract, field or tool is added.
`--display-write-limit 300` supports the measured 8–24 target 5–10 Hz workloads. The supported explicit range is 1..1000 requests/s. Absent this flag, the complete old aggregate budget path and default 60/s remain unchanged, including an existing `--write-limit` override. The new flag requires private role provisioning via `--surface-client-tokens-stdin`; it changes only authenticated display writers, leaving owner/operator aggregate budgets and permissions unchanged.
Begin at 5 Hz and increase to 10 Hz only as the consumer needs. Software quota is not the physical MIDI limit. An explicit high limit does not authorize new targets, inputs, motor output, preset changes or automatic lifecycle sends.
The independent display bucket uses injected monotonic seconds. Nonfinite/backward clock values fail closed; wall-clock jumps do not refill it. The legacy aggregate path retains its original semantics.

## Input service, journal and timing evidence

Every condition generated and read all 300 hardware input events. Input-only baseline with the explicit display setting: p50 12.942 / p95 28.045 / p99 32.760 / max 36.766 ms.
The reader targeted 25 ms polling; raw poll start/end/count records give the actual cadence. Higher display rates increased some input latency tails, as shown above, but did not drop or gap any input in the measured runs. Each display condition also produced 300 existing input-triggered overlay refresh sends; those are accounted separately from accepted display requests.
All measured accepted display requests matched a fake receive; observed coalesced/missing sends = 0, ignored feedback = 0. 4 request windows across both complete runs contained more than one identical send because of an input-triggered refresh. Raw candidate timestamps are retained; the table uses the conservative last timestamp in such windows, not the most favorable candidate. Clock domains are Python monotonic and ProcessInfo.systemUptime; all matched deltas were finite and nonnegative.
Feedback, including ignored feedback, uses the existing shared 1024-event FIFO journal and advances global sequence, never input_sequence. Therefore it can evict old input events if a reader falls behind. No separate input journal or hidden filtering is introduced. Poll continuously (100 ms or faster recommended here), preserve the global cursor, and fail closed/re-prepare on event_gap. At 240 feedback/s plus the measured 5 input/s, a 1024-event window is only about four seconds; this is not an offline history guarantee. Continuous reads saw every input throughout repeated journal wraps.
Hardware aggregate quota exhaustion already returns `invalid_argument`, while simulation returns `rate_limited`; this F behavior is retained. The report keeps raw rejection codes. Quota attribution here uses known valid requests, the exact existing consumeWrites path and the high-quota comparison where the same workload has zero rejections; arbitrary invalid arguments must not be labeled quota errors.

## Physical limit and limitations

Reliable USB MIDI/device firmware maximum: **needs physical measurement**. A fake transport cannot establish loss/order limits. `H_STATUS_PANEL_ATTENDED.md` prepares the independent attended measurement; it is not executed by H.
The first seven-host parallel attempt developed transport_unknown at about 39 seconds, including the input-only reader. Its raw files are preserved and it is not a passing performance result. The cause is unresolved; TIME_WAIT exhaustion is not established. The complete table instead uses a declared one-host-at-a-time plan. This does not qualify seven simultaneous hosts or predict multiple display clients' combined physical throughput.
The complete precision values, input-only baselines, RTT/poll distributions, request/send matching counts, binary SHA/base/patch identities and raw-data hashes are in `status-panel-budget-evidence.json`. Runtime credentials are absent. Quantiles select floor((count-1)×p), without interpolation; milliseconds above are rounded to three decimals.
