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

Snapshots seed known raw Mock input state without operator events. Raw input is stored separately
from display feedback. Consumers discard historical events at bootstrap. Only subsequent fresh
accepted `kind: input` events can select operations, and only through an explicit simulation
consumer. Input origin is trusted host metadata (`interface` or `remote`); clients cannot supply
hardware origin, timestamps or actual telemetry.

Display feedback uses the normal engine `SurfaceEffect.send` / session pipeline. It does not
write command parameters, create input events, trigger actions, or supply safety actual values.
BCR indicator off/on/blink has presentation 0/127/96: `blink` remains a semantic state, with static
96 in the BCR Mock, not a claim of physical flashing. Changing source/configuration clears the
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
