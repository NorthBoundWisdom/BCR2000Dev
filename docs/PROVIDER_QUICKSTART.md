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
is visible as a `feedback.suppressed` event. `write` permits explicit feedback requests and must
be given explicitly. Headless startup, connection, reconnection and source changes never replay retained feedback, even in write mode. The `provider.ready` record reports the choice as `hardware_output` (null without
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

## Attended physical workflow

Use an isolated copy of an explicitly learned map and configuration:

```sh
BCRProviderService --source hardware --hardware-output write \
  --hardware-map /private/isolated/hardware-map.json \
  --configuration /private/isolated/surface-configuration.json --port 0 --token-stdin
```

Read the startup `provider.ready.hardware_output` and require `write` when feedback is needed.
For observation only, omit `--hardware-output` (default `observe`, zero device sends).
After a write read `console_events` with its current generation and sequence: `feedback.sent`
records transport acceptance; `feedback.suppressed` records policy suppression. Software write
success does not mean the device displayed the value. Reprepare after generation changes.

For explicit hardware surface 1.4, add `--hardware-profile --surface-instance-id operator-bcr`.
Keep the learned `--hardware-map` required above. Read-only input observation uses default
`observe` and no display permission. For displays add BOTH `--hardware-output write` and
`--allow-surface-feedback`. SDK 1.4.0 must explicitly accept hardware; ordinary simulation
continues to advertise 1.3. This does not grant physical qualification.

Before preparing a physical four-role consumer, run the delivered `BCRProfileTool
--check-hardware-roles` mode described in `HARDWARE_ROLE_READINESS.md`. `ready:false` is a
preparation refusal, including when current buttons are visualization-only. This read-only report
never changes learned mappings or grants physical qualification.

## Additive tool compatibility and separate clients

Provider 1.0 的冻结范围是已有工具的名字、Schema、错误语义；新增工具属于加法，不破坏兼容。加法须登记且可核对，仅对应显式开启能力的工具在该能力启用时才出现。

See `PROVIDER_TOOL_COMPATIBILITY.md` and `provider-tool-compatibility.json`. The old frozen reference
contains 25 tools with `--robot-sim`; its default subset contains 21. The default headless catalogue is
21; explicit robot mode is 38. The included read-only `diagnostics/verify_provider_catalogue.py`
checks every present frozen descriptor and rejects unregistered or incorrectly gated additions.

For separate simulation operator and display clients see `SURFACE_CLIENTS.md`. The optional
`--surface-client-tokens-stdin` receives **owner, operator, display** credentials through one dedicated
private JSON pipe; no token belongs in argv, reports or a delivery. The default single-token mode is unchanged.
The runtime SDK excludes test doubles; `TEST-ONLY-surface-control-testing-1.4.0.zip` is a separate test asset.

Hardware source/profile, button edges, current preset and actual lights still require attended validation.
A local candidate package and a successful fake-device test do not confer that qualification.

## Synthetic status-panel demo (H)

Use an owned headless simulation host with feedback permission, an explicit display quota if desired,
and the private role provisioning described in `SURFACE_CLIENTS.md`:

```sh
BCRProviderService --port 0 --simulation-profile --surface-instance-id PANEL \
  --allow-surface-feedback --surface-client-tokens-stdin --display-write-limit 300
```

The process owner supplies the three-role JSON through an anonymous stdin pipe; never place credentials
in argv/files. Pass only the display credential through a separate anonymous FD to the SDK example:

```sh
PYTHONPATH=<delivery>/surface-control-sdk-1.4.0.zip python3 -B -m surface_panel_demo \
  --url <owned-ready-url> --instance-id PANEL --token-fd <DISPLAY_FD> --mapping bcr --hz 1 --duration 15
```

`status-panel-demo.md` documents synthetic actual recording, cleanup and source-stale/signal behavior.
`H_STATUS_PANEL_ATTENDED.md` prepares the hardware stage without executing it or promoting a candidate.
The default BCR hardware profile is intentionally refused because it has no extinguishable button target;
existing 1dot/12dot ring zero is a lit resting position. The default GUI does not expose this optional
control-contract endpoint; its existing actual VM/ControlPresentation render path is tested separately.

For a release artifact, the bundled no-device CLI rehearsal is:

```sh
python3 diagnostics/verify_status_panel_demo.py --artifact . --output <fresh-owned-directory> --simulation-only
```

Debug-only maintainers can omit `--simulation-only` to include the explicit fake-device candidate modes.
If the artifact has no hardware map, the checker creates a clearly TEST-ONLY map/candidate under its
new output directory using the offline profile tool, never changing the artifact, preset or qualification.
All rehearsals use only owned loopback processes, never a physical endpoint.
