# BCR provider 1.0 local handoff

Requires macOS 14+ and a matching executable architecture. The standalone provider does not load a
GUI, Agent backend, real robot/chassis driver or a consumer project's business configuration.
The reference simulators are optional and clearly report `source=simulation`.

Set `BCR_PROVIDER_TOKEN` using a trusted local credential mechanism (64 lowercase hexadecimal bytes;
never put it in argv, a committed file or logs). Start the published executable:

```sh
./BCRProviderService --port 18787 --robot-sim --chassis-sim \
  --allow-robot-control --allow-chassis-control --allow-simulation-control
```

Only `127.0.0.1` is accepted. No control grants are enabled without explicit owner flags. A JSON
`provider.ready` record supplies the actual endpoint and startup-unique `provider_id`; normal RPC uses the published Python SDK and
the same local credential. `--help` lists owner startup options; clients need not modify app-private
settings. `--no-console` runs reference devices without any console or Agent runtime. Use `--clock
manual` for reproducible tests and `simulation_advance`; realtime mode has an autonomous clock/watchdog.

Place the published SDK zip on `PYTHONPATH`:

```sh
export PYTHONPATH="$PWD/bcr-provider-sdk-1.0.0.zip"
export BCR_PROVIDER_URL=http://127.0.0.1:18787/mcp
export BCR_PROVIDER_ID='<provider_id from this process owner ready record>'
python3 examples/read_capabilities.py
python3 examples/observe_console.py
```

See `PROVIDER_API.md`, `schemas/provider.schema.json`, and MCP `provider_contract` / `tools/list` for
the machine-readable contract. Model units/frames, supported and unsupported operations, source,
generation, controls and errors are explicit. Readbacks and targets are different fields. Fresh
control requires initialize → acquire → enable → a bounded, sequenced command. Read snapshots after
uncertain writes; no automatic command retry or input replay is performed by the SDK.
Every example pins the instance through `BCR-Provider-Id`. A process restart changes that identity;
explicitly select the new instance rather than automatically trusting a process that reuses the port.

Public profiles are optional `--configuration` / `--hardware-map` seed files. `--data-dir` stores owned
profiles with backups for legacy migration; runtime values and credentials are not persisted. Invalid
profiles fail startup rather than silently becoming a hardware configuration. Without it, profile
changes are intentionally memory-only.

For the physical BCR console, explicitly use `--source hardware --hardware-map <learned-map.json>`
and `--allow-device-control`; missing hardware fails without a Mock fallback. Do not infer MIDI
identities or write a device preset.

With `--source hardware`, `--hardware-output observe|write` chooses whether the service may write the
device. The default `observe` takes inputs and updates parameters as usual but sends nothing: no
feedback, no LED writes and no full resynchronisation on connect or reconnect; each held-back message
is visible as a `feedback.suppressed` event. `write` restores feedback and resynchronisation and must
be given explicitly. The `provider.ready` record reports the choice as `hardware_output` (null without
hardware); the option is refused without `--source hardware`. The published diagnostic entry is:

```sh
python3 diagnostics/bcr_device_diagnostics.py snapshot --provider "$BCR_PROVIDER_URL" \
  --expected-provider-id "$BCR_PROVIDER_ID" --output snapshot.json
```

It requests read-only identity/CC snapshots and coordinates input suppression/classification using
the public provider API. Wait until pending feedback is drained. The diagnostic token is private to
that call; if its process crashes, inspect `get_status.diagnostic_readback` and explicitly invoke
`console_diagnostics` with `operation=abort` before using new inputs. Source/mapping/connection changes
invalidate the event generation. These frames are readback, not operator approvals. User input events
and platform/device actions require their own consumer-side interpretation.

The manifest records hashes, source commit and working-tree status. This is a reproducible local
handoff; uploading a public release or connecting industrial actuators requires separate scope.
