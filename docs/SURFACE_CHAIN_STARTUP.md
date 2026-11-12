# BCR software chain startup

Use a dedicated delivered simulator process for each software chain. This page describes the
supplier side only; the consumer owns business mappings, authority, Mock device stop verification
and its own watchdog. Surface inputs are always `source: simulation`, never physical evidence.

## Pin and start

Verify `manifest.json` and every `files_sha256` entry before importing the bundled SDK. Record the
manifest SHA-256, `source_commit`, `surface_plugins_revision`, contract/SDK versions, profile and
`mapping_revision` in the chain report. Run commands from the delivery directory. The generic
held-enable/axes configuration has profile `bcr2000.mock` version `1.2`, mapping
`3d93301a62d6f9b6`; its parameters and controls are listed in `examples/simulation/README.md`.

```sh
RUN=$(mktemp -d)
chmod 700 "$RUN"
python3 -c 'import os,secrets,sys; fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,secrets.token_hex(32).encode()); os.close(fd)' "$RUN/token"
cat "$RUN/token" | ./BCRProviderService --simulation-configuration examples/simulation/chassis-controls.json \
  --surface-instance-id chain.chassis.A --port 0 --write-limit 60 \
  --allow-device-control --allow-surface-input --allow-surface-feedback \
  --token-stdin > "$RUN/provider.log" 2>&1 &
PROVIDER_PID=$!
```

Use a unique instance ID per process. Wait for the first stdout JSON event `provider.ready`,
which includes the actual loopback URL and `provider_id`; do not infer readiness from a port.
The generic SDK must send that ID using the `BCR-Provider-Id` header. Give the SDK the private
token file contents without logging them. Call `surface_control_discover`, pin the returned
instance/epoch/profile/mapping, and read a snapshot before acting. `--describe-surface` prints
static descriptors without starting a server; live discovery remains authoritative.

Parameter writes are allowed by default; `--read-only` disables them. Input additionally requires
`--allow-device-control` and `--allow-surface-input`. Display writes require
`--allow-surface-feedback`. For a trial that owns and resets this instance, also add
`--allow-simulation-control --allow-surface-reset`; leave those grants absent for ordinary chains.
No real-device connection or output transport is enabled by this startup.

The taskless arm/start/pause/cancel demonstration uses `--simulation-profile` in place of
`--simulation-configuration ...`. Its default mapping is `ef0e106767594759`, with ordinary
`simulation.arm/start/pause/cancel/state/progress/link` parameters. It is a different scenario
from the held-enable/axes configuration. Discover parameter mappings; do not hardcode geometry.
Consumer-specific samples under `examples/simulation/integrations/` are outside the public contract.

## Input lease and feedback cadence

For held enable (`button.1.1` in this configuration), request `hold_s: 0.5` and renew every 0.1 s
while the operator intent remains live. The host maximum is 5 s. Release with boolean false as
soon as intent ends. Only accepted momentary inputs declare holds. A toggle is not a deadman:
`hold_s` on one returns `unsupported_hold`. A consumer must stop on loss of connection, missed
fresh observations, a revoked epoch/mapping or lease deadline, using its own watchdog. Host
release events show input release; only the consumer's Mock actual state proves physical-effect stop.

Keep display feedback at **at most 4 updates/s per control**, preferably coalescing unchanged
values. Input, feedback and renewal share the default 60 writes/s process budget. Three feedback
channels at 4 Hz plus a 10 Hz lease renewal consume 22 writes/s before axes and other writers;
size the remaining input cadence accordingly. `--write-limit N` changes the common budget.
Unsequenced feedback still advances the input CAS sequence. On `stale_sequence`, no input was
executed: explicitly `refresh_sequence`, reassess current intent, then choose whether to submit a
new input. Never automatically replay a request with an unknown transport result.

## Stop and clean up

While connected, release enable, return both axes to their documented rest (scalar 64), and send
the separate stop intent if required by the consumer. Wait for the consumer's actual Mock stopped
state and record it independently of display feedback. Test release, disconnection and lease
expiry as three separate cases. Display indicator alone is not a stop acknowledgment.

```sh
kill -TERM "$PROVIDER_PID"
wait "$PROVIDER_PID"
rm -f "$RUN/token"
```

Delete only this run's remaining logs/directory after retaining redacted evidence. The simulator
is memory-only and creates no user configuration or hardware map. If a consumer starts its own
platform, stop only its named run, retain the requested cleanup evidence, and leave pre-existing
containers, networks and data volumes untouched. Never put credentials in argv, reports or commits.
