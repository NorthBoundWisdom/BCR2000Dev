# Optional Surface Control simulation 1.1

The `surface_control_*` tools are a separate, optional software control contract. Provider 1.0,
its Schema, SDK `bcr_provider`, console journal, errors and business plugin tools retain their
existing behavior. A simulation event never qualifies as a physical operator input.

The profile `bcr2000.mock` version `1.1` (contract `1.1`, SurfacePlugins `68b7a5c`) describes stable
controls such as `pushEncoder.1.1`; clients discover mappings instead of interpreting the ID geometry.
The contract, generic Python SDK, schemas and fixtures have one source, the locked SurfacePlugins
package; this host only adapts its Mock and session to them.

Capabilities use the shared vocabulary: `simulation`, `controls.stable_ids`, each `input.*` and
`feedback.*` kind actually present (`input.relative` appears only while a relative encoder is
assigned), and `input.hold`. Host-private ones are `x.bcr.display_only_feedback`,
`x.bcr.explicit_input_permissions` and `x.bcr.indicator_blink_static`. `mapping_revision` is the
deterministic `profile.mappingRevision` of the published profile: it changes only when a
control's kind, encoding, range, feedback kinds, mapping or hold changes, and stale requests are
checked mapping before epoch (`stale_mapping`, then `stale_epoch`). Every context change still
changes the epoch. Absolute controls use integer scalar ranges
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

## Button holds (contract 1.1)

Every button declares `hold: {rest_value: false, max_hold_s: 5}`. Five seconds bounds how long a
lost client can leave a simulated button pressed; consumers renew well inside it. An input of
`true` with `hold_s` (0, 5] is accepted with `hold_deadline = time + hold_s`; an input of `false`, or
an accepted value without `hold_s`, clears the lease. `surface_control_renew({expected, control_id,
hold_s})` extends a live lease without consuming a sequence or writing an event. It requires the
same permissions as input (surface input, parameter write, device control) and is charged to the
write budget. `hold_s` on a continuous control returns `unsupported_hold`.

The host advances leases by its own monotonic clock: a MainActor timer is scheduled at the
earliest deadline, and every request first processes due leases. Expiry releases the Mock button
through the ordinary simulated input path (so a momentary parameter returns to its minimum),
then records `input / accepted / origin remote / reason hold_expired`. Renewing after expiry returns
`hold_expired`. Any context change (reset, mapping/page/configuration, source) revokes every lease
and releases held buttons; while the hardware source is active, the release is applied as soon
as the Mock is active again. `hold_expiry_pending` is passed through if a lease is due but not
processed (only possible in in-process fault probes with automatic expiry disabled). The
explicit simulation profile maps `button.1.3` to `simulation.hold` (momentary) for the shared 1.1
fixture `hold_input` role.

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
encoding change; there is no per-control clear operation in contract 1.0 or 1.1. Changing source/configuration clears the
simulation display before any physical feedback. Reset explicitly creates a fresh all-off Mock
context and clears the new journal; source, mapping, page and configuration changes also revoke
old context. No input is replayed after reset/restart or an event gap.

## Public delivery and examples

`configs/package_provider.py` creates a self-contained local artifact with the unchanged legacy
Provider assets (`bcr-provider-sdk-1.0.0.zip`, Provider 1.0 schema) and the optional Surface 1.1
delivery copied byte for byte from the materialized `build/seed/SurfacePlugins`:
`surface-control-sdk-1.1.0.zip` (`surface_control/__init__.py`), and under `surface-control/` the tool
descriptors, scenario schema, v1 and v1.1 fixtures and the contract/scenario documents.
`manifest.json` records `surface_control_contract: 1.1`, `surface_control_sdk: 1.1.0`, the locked and
materialized shared revision, the shared source path and SHA-256 of every Surface file, plus
SHA-256 of every delivered file, host source commit and dirty state. Pin the manifest SHA-256
before importing any delivered SDK. No tag/release is implied.

`examples/surface_roundtrip.py` is a minimal generic consumer: it verifies the pin, imports only the
delivered SDK, and pins the provider identity with `provider_header="BCR-Provider-Id"` when given
`--provider-id`. The Pipe taskless integration example and the SDK unit tests now live only in
SurfacePlugins (`integrations/pipe/`, `clients/python/tests/`) and are not part of this delivery;
that example runs as the owner of its simulation instance and therefore needs reset permission.
Transport ambiguity, stale input, identity change or gap ends a consumer with no write retry;
inspect the existing journal and explicitly create a new context to continue.
