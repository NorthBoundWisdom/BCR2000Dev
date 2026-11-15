# G-7 Provider tick measurement

This is measurement, not a claimed optimization. The task's historical approximately 3.5 ms per
Debug tick was not reproduced on the current source. No speculative caching, lost clock steps,
trace reduction, journal suppression or changed SSE cadence was introduced.

## Reproducible method

```sh
python3 configs/profile_provider_tick.py --output build/g/g7/controlled-before
python3 configs/profile_provider_tick.py --output build/g/g7/controlled-repeat
```

The tool builds the existing Debug libraries, links a small `-Onone` probe against those exact
objects, and measures five independent 500-iteration samples. It uses the existing
`ProviderApplication` and injected clock advanced by 0.02 seconds per tick. Both robot and chassis
are enabled; two configurations are measured separately: no actual observations, and initialized
six-joint/three-axis actual observations. There are no ports, physical devices, wall-clock sleeps
or running GUI. Output JSON preserves every sample, source revision, Provider source hash and
per-component medians. It is a diagnostic command, not another production test runner.

Same tick, same initialized configuration through XCTest is also retained as the existing
`EventRetentionTests.testManyIdleTicksPreserveEarlyEventsAndLegacyTimeRevisionTraceAndSSE`:
2000 ticks, full original time/revision/trace/early-event/SSE assertions. Its whole-case time
includes setup and all assertions, so it must not be presented as an isolated per-tick time.

## Actual current numbers

Measured on Debug `966d4879e7bf8a624fe61fa7fed46c069a1cb14b`; no Provider product source change
between runs (Provider source SHA-256
`bac9b250e4da24e66b83f2bf0e10dda071fd7e338099e304f8bf55517725691c`).
All entries below are medians in milliseconds per call, directly from the two `report.json` files.

| Configuration / component | First run | Repeat, no product optimization |
| --- | ---: | ---: |
| Uninitialized tick | 0.0927138333208859 | 0.08471866662148386 |
| Uninitialized state() | 0.07406000001356006 | 0.07125041668768972 |
| Uninitialized two typed snapshots | 0.002144833328202367 | 0.0022684999275952578 |
| Uninitialized two snapshots + JSONValue encoding | 0.07139716669917107 | 0.07049658324103802 |
| Initialized tick | 0.3623780000489205 | 0.3415779999922961 |
| Initialized state() | 0.1987121666315943 | 0.1896781666437164 |
| Initialized two typed snapshots | 0.08795208332594484 | 0.08608075010124594 |
| Initialized two snapshots + JSONValue encoding | 0.19682983332313597 | 0.1840575833339244 |

The initialized case costs more because snapshots contain actual joint kinematics/pose. The
`state()` and snapshot-plus-encoding measurements show that building the two actual snapshots and
encoding the Provider 1.0 state is a substantial part of current tick work. The latter measurements
include snapshot construction; they are not an exclusive encoder profile. The rest includes
simulation advancement, trace retention, strict replacement validation and event timestamping.

Existing native XCTest whole-case times: G baseline 0.915 seconds, after G6 0.753 seconds for the
same 2000-tick test (including setup/assertions). Native runs were parallel, whereas the probe is
standalone, so neither difference is claimed as an optimization result. Exact baseline/final
xUnit paths and command logs are in the G-B handoff.

The previous `test-performance.md` P3 records already implemented immutable descriptor caches,
formatter reuse and JSON fast encoding. Its historical EventRetention **class total** was 3.594
seconds before and 0.887 seconds after, and its real-process class times differ again. Those
class totals do not establish 3.5 milliseconds for this single tick; an exact original per-tick
fixture/runner is not identified in that document. We therefore cannot assign a causal before/
after speedup from that old number to this round.

The Provider 1.0 SSE event per tick is explicitly a compatibility contract. Skipping publication,
changing the simulated step, narrowing state or dropping old trace assertions would change
behavior. Since current controlled measurements do not show the reported 3.5 ms problem, G7
introduces only this reproducible measurement and report. Shared JSON parsing is evaluated
separately in G9; it is not silently counted as a G7 optimization.
