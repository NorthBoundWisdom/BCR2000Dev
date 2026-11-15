# Provider 1.0 tool compatibility

Provider 1.0 的冻结范围是已有工具的名字、Schema、错误语义；新增工具属于加法，不破坏兼容。加法须登记且可核对，仅对应显式开启能力的工具在该能力启用时才出现。

The reference artifact-05 manifest SHA-256 is
`aca7e2112531acc1d1ccf0f6c361107ca06df2da21bfb3bc32511ab4be881ad8`.
Its catalogue has 21 tools in default startup and 25 with `--robot-sim`. Pipe's observed 25→45
comparison used robot mode, not default startup. F preserves each of those 25 full descriptors.
It removes accidentally exposed GUI-only capabilities from the headless service and does not change GUI tools.

| Startup | Old artifact-05 | F starting point | F corrected | Difference from old |
| --- | ---: | ---: | ---: | --- |
| No new option (ordinary Mock console) | 21 | 30 | 21 | none |
| `--robot-sim` | 25 | 45 | 38 | 13 registered shared/robot tools |
| `--chassis-sim` | 25 | 45 | 38 | 13 registered shared/chassis tools |
| `--robot-sim --chassis-sim` | 28 | 59 | 52 | 24 registered shared/robot/chassis tools |
| `--no-console` | 3 | 5 | 3 | none |

The 20 names in the Pipe comparison are all listed below. None modifies an existing tool's Schema/error behavior.

| Added tool | Starting-point default | Corrected headless gate |
| --- | --- | --- |
| `list_midi_endpoints` | exposed | omitted: headless callback unavailable; GUI only |
| `set_midi_endpoints` | exposed | omitted: headless callback unavailable; GUI only |
| `get_preset_alignment` | exposed | omitted: headless callback unavailable; GUI only |
| `preview_preset_alignment` | exposed | omitted: headless callback unavailable; GUI only |
| `apply_preset_alignment` | exposed | omitted: headless callback unavailable; GUI only |
| `restore_preset` | exposed | omitted: headless callback unavailable; GUI only |
| `dismiss_preset_alignment` | exposed | omitted: headless callback unavailable; GUI only |
| `surface_capabilities` | exposed | `--robot-sim` or `--chassis-sim` |
| `surface_events` | exposed | `--robot-sim` or `--chassis-sim` |
| `surface_robot_acquire` | absent | `--robot-sim` |
| `surface_robot_advance` | absent | `--robot-sim` |
| `surface_robot_enable` | absent | `--robot-sim` |
| `surface_robot_initialize` | absent | `--robot-sim` |
| `surface_robot_move` | absent | `--robot-sim` |
| `surface_robot_release` | absent | `--robot-sim` |
| `surface_robot_renew` | absent | `--robot-sim` |
| `surface_robot_reset` | absent | `--robot-sim` |
| `surface_robot_snapshot` | absent | `--robot-sim` |
| `surface_robot_stop` | absent | `--robot-sim` |
| `surface_robot_trace` | absent | `--robot-sim` |

`--chassis-sim` independently adds `surface_chassis_acquire/advance/drive/enable/initialize/release/renew/reset/snapshot/stop/trace`.
Their names and the shared pair are registered in the machine record. The legacy chassis state/command/trace and
simulation_advance are selected by the existing chassis capability.

Seven `surface_control_*` tools (discover, snapshot, input, feedback, events, reset, renew) are a separate group.
It appears with any of `--simulation-profile`, `--simulation-configuration PATH`, `--surface-instance-id ID`,
`--allow-surface-input`, `--allow-surface-feedback`, `--allow-surface-reset`, or `--hardware-profile`.
The last requires `--source hardware --hardware-map PATH`; invalid combinations fail startup. Permission flags
change authorization, not the seven tool names. The instance flag enables the optional contract without granting a write.
Each single enabling flag and robot/surface combinations have real-process black-box coverage.

## Read-only verification

The delivered `provider-tool-compatibility.json` contains all 25 full descriptors, with full-descriptor SHA-256 and separate
description/inputSchema/outputSchema hashes. The same descriptors remain independently
readable from the frozen reference artifact.
Hash encoding is UTF-8 JSON, object keys sorted, `ensure_ascii=false`, compact comma/colon separators,
no trailing newline. Array order and every descriptor field are preserved. Hashes do not cover arbitrary wire whitespace.
No assertion claims arbitrary JSON key order or whitespace is byte stable. The canonical descriptor bytes are identical.
The unchanged Provider schema and SDK 1.0.0 files retain their separate manifest hashes.

Run from outside the source tree, passing a private credential through stdin (never an argv literal):

```sh
python3 <delivery>/diagnostics/verify_provider_catalogue.py \
  --url http://127.0.0.1:<port>/mcp --provider-id <owned-ready-provider-id> \
  --token-stdin --robot
```

Omit `--robot` for default startup; use `--chassis`, `--surface`, `--no-console` to describe the actual selected capabilities.
The command performs only `tools/list`; it writes no input, display or device operation. An offline `--catalogue FILE`
checks a previously recorded tools array. The output distinguishes the frozen reference total (25), present unchanged frozen
members, absent capability-disabled members, and registered additions. Unknown tools, changed frozen descriptors,
missing expected members or incorrect capability gates fail closed. Failure diagnostics never echo peer-controlled text.

Pipe may adopt a matching local candidate for Provider 1.0 compatibility after independently verifying its manifest and
this command. This compatibility decision does not grant physical preset/button/LED or business-chain qualification.
