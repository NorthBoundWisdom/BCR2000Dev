# Optional Surface Control simulation 1.0

The `surface_control_*` tools are a separate, optional software control contract. Provider 1.0,
its Schema, SDK `bcr_provider`, console journal, errors and business plugin tools retain their
existing behavior. A simulation event never qualifies as a physical operator input.

The profile `bcr2000.mock` version `1.0` describes stable controls such as `pushEncoder.1.1`;
clients discover mappings instead of interpreting the ID geometry. The same generic SDK accepts
XTouch's `xtouch.compact.standard.simulation` profile. Absolute controls use integer scalar ranges
0–127 (0–16383 for the explicitly selected Mock NRPN experiment); relative controls use signed
integer detents and declare a separate absolute feedback range. Buttons use booleans. Mock
assumptions remain software behavior, with no physical qualification implied.

## Isolated startup and readiness

Supply a fresh 64-character lowercase hexadecimal credential through an anonymous stdin pipe
(`--token-stdin`), or the existing `BCR_PROVIDER_TOKEN` environment variable. Never put the token
in argv or a report. From the delivered directory, launch:

```sh
./BCRProviderService --port 0 --source mock --simulation-profile \
  --surface-instance-id trial-A --allow-device-control --allow-simulation-control \
  --allow-surface-input --allow-surface-feedback --allow-surface-reset --token-stdin
```

The first stdout JSON line is `provider.ready` with the actual loopback URL, PID and legacy
`source: mock`. `surface_control_discover` provides authoritative `source: simulation`, profile,
instance, epoch, mapping revision and current decimal sequence. Readiness is not inferred from
an open port. SIGINT/SIGTERM stop only this process. The profile is memory-only and cannot be
combined with a stored/seed configuration. Its ordinary parameters are `simulation.arm`,
`simulation.start`, `simulation.pause`, `simulation.cancel`, `simulation.state`,
`simulation.progress`, and `simulation.link`. These are neutral mapping keys; no business
operation is implemented by the provider.

Input, display feedback and reset each require their separate process permission, all OFF by
default. Parameter writes must be allowed; input also requires device control and reset requires
simulation control. Input retains `agentWritable` and `externallyProtected` checks. No option
permits simulation input or display writes to a hardware source. The optional contract itself is
installed only with an explicit simulation profile, surface instance ID or surface permission flag.
Ordinary GUI/Provider startup does not validate legacy configurations against its stricter IDs or
install the new tools. When explicitly installed, the adapter observes Mock input through the same
SurfaceSession; a GUI does not implicitly enable the optional contract.

## Input, feedback and recovery

Every mutation pins all five identity fields plus `expected_sequence`. Accepted and ignored
writes each consume one sequence. Replaying the same request is rejected as `stale_sequence`.
Repeated absolute/button input with the same raw value is ignored; same-side dial ticks never
renew an old business intent in the sample consumer. Relative detents remain separate inputs.

While surface control is installed (simulation profile, surface instance ID or any surface
permission flag), the legacy Provider `console_mock_input` tool returns `permission_denied` and
points to `surface_control_input`, so no simulated input bypasses the separate input permission and
CAS fences. Without the optional contract, Provider 1.0 keeps its exact behavior. The adapter
records only local interface input (`origin: interface`) and its own remote requests (`origin:
remote`); any other writer's Mock input revokes the context (new epoch, sequence 0, reseeded inputs,
no event) and adds a diagnostic to the gateway audit list instead of appearing as a remote intent.

An absolute `scalar` input sets the requested Mock input position directly. It does not compute a
delta from the currently shown position, so a display overlay with the same value cannot turn the
input into `no_change`. Repeated values are judged against the last accepted input only.

Failures are fail-closed but recoverable: if recording an observed local input fails, the adapter
writes a diagnostic and the next call changes epoch. While the failing condition persists (for
example a regressed host clock) calls report it; afterwards discovery succeeds again without an
admin reset. Context changes are detected through `SurfaceSession.mappingContextRevision`, which
changes on configuration, parameter definition, assignment, bulk assignment, page, source,
learning/hardware map and Mock NRPN changes, and not on ordinary input, parameter or feedback writes.

Every fallible check (identity, sequence, clock, value range, protection, display encoding, reset
configuration) completes before the write budget is charged and before the engine changes. After
an engine change only the journal record remains; if that record fails, the context is revoked so the
journal and engine cannot silently disagree. Reset runs the Mock/session reset first and commits the
new control session last. Tool errors keep host codes such as `unsupported` and `rate_limited`;
only unrecognized errors use `invalid_argument`.

Snapshots seed known raw Mock input state without operator events. Raw input is stored separately
from display feedback. Consumers discard historical events at bootstrap. Only subsequent fresh
accepted `kind: input` events can select operations, and only through an explicit simulation
consumer. Input origin is trusted host metadata (`interface` or `remote`); clients cannot supply
hardware origin, timestamps or actual telemetry.

Display feedback uses the normal engine `SurfaceEffect.send` / session pipeline. It does not
write command parameters, create input events, trigger actions, or supply safety actual values.
BCR indicator off/on/blink has presentation 0/127/96: `blink` remains a semantic state, with static
96 in the BCR Mock, not a claim of physical flashing. A button has one LED display slot, so button
controls declare only `indicator` feedback; `value` on a button returns `unsupported_feedback`.
Continuous controls declare only `value`.

A display overlay is per control and persists: while it is set, that control shows the overlay
instead of its parameter (target or actual) feedback, even when the mapped parameter later changes
through input, GUI or Provider writes. Inputs and parameter values are not affected. The overlay is
removed only by `surface_control_reset`, a source change, or a configuration/assignment/page/Mock
encoding change; there is no per-control clear operation in contract 1.0. Changing source/configuration clears the
simulation display before any physical feedback. Reset explicitly creates a fresh all-off Mock
context and clears the new journal; source, mapping, page and configuration changes also revoke
old context. No input is replayed after reset/restart or an event gap.

## Public delivery and examples

`configs/package_provider.py` creates a self-contained local artifact with both unchanged legacy
Provider assets and `surface-control-sdk-1.0.0.zip`, independent contract schemas, generic client,
and examples. `manifest.json` pins every file, host source commit, dirty state and exact shared
revision. Pin the manifest SHA-256 before importing any delivered SDK. No tag/release is implied.

`examples/pipe_surface_trial.py` is an optional consumer for the explicit scenario
`surface-pipe-taskless-v1`. It imports only the delivered generic SDK and an explicitly supplied,
read-only Pipe tools directory. It verifies owned ready independent Mock state, creates a fresh
`taskless-controller-trial-v1` workflow, and reuses Pipe's `ActionGate`, `dispatch` and durable
journal. Fresh input drives start/pause/cancel; only later authoritative platform snapshots drive
state/progress/link feedback. The report records artifact/source/tool hashes, fences, sequence,
platform versions and event cursors, without credentials. It never starts/stops a platform stack.
Use `PYTHONDONTWRITEBYTECODE=1` and the delivered example's `--help` for required arguments.

The taskless trial proves real platform orchestration, not a Worker, robot, welding process,
physical input, or device stop acknowledgment. The production Pipe bridge remains hardware-only.
Transport ambiguity, stale input, identity change or gap ends the consumer with no write retry;
inspect the existing journal and explicitly create a new trial context to continue.
