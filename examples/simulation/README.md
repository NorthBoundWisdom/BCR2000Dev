# Configurable simulation inputs

`chassis-controls.json` is a simulation-only SurfaceConfiguration v7 file. It contains ordinary
parameters and control bindings; it opens no device and grants no actuator authority.

```sh
BCRProviderService --simulation-configuration examples/simulation/chassis-controls.json \
  --surface-instance-id example.axes --allow-device-control \
  --allow-surface-input --allow-surface-feedback --token-stdin --port 0
BCRProviderService --simulation-configuration examples/simulation/chassis-controls.json --describe-surface
```

Supply the token through a dedicated pipe as described in SURFACE_SIMULATION.md. Never put a token in argv.
This option enables the same memory-only Mock mode as `--simulation-profile`; the two options are
mutually exclusive. `--source hardware`, `--configuration`, `--hardware-map`, `--data-dir` and
`--no-console` cannot be combined with the configurable fixture option. The historical option retains its existing startup policy.

| Role | Control | Parameter | Input/display |
| --- | --- | --- | --- |
| Held enable | `button.1.1` | `simulation.enable` | boolean, momentary, hold ≤5 s |
| Speed axis | `pushEncoder.1.1` | `simulation.speed` | absolute scalar 0–127, rest 64 |
| Steering axis | `pushEncoder.1.2` | `simulation.steer` | absolute scalar 0–127, rest 64 |
| Stop intent | `button.1.2` | `simulation.stop` | boolean, toggle, no hold |
| Speed feedback | `encoder.1.1` | `simulation.speed_feedback` | numeric display 0–127 |
| Steering feedback | `encoder.1.2` | `simulation.steer_feedback` | numeric display 0–127 |
| Stopped feedback | `button.1.3` | `simulation.stopped` | off/on/blink indicator |

The feedback bindings are writable simulation parameters, so their controls also accept input.
Feedback writes update only the display overlay, without changing the parameter or generating input.
Both axes use the existing raw MIDI-independent scalar contract with range 0–127; the consumer
maps their centre 64 and deadband 3 to its own normalized business values.

The file uses the existing SurfaceConfiguration encoding, restricted to `version`, `name`,
`parameters`, `assignments`, and empty `pages`/`macros`. The version must be 7. Parameters use
ParameterDefinition fields and must be writable and unprotected. Assignments use ControlAssignment
fields, including `buttonBehavior`, `encoderMode` and `encoderStep`; only `target.parameter` is
allowed. Unknown fields at any level, duplicate assignments/parameter IDs, nonexistent controls,
unknown parameters, invalid numbers and invalid modes fail startup with a diagnostic. No migration,
persistence or fallback is performed for this simulation input file.

In configurable mode only momentary button bindings declare a hold lease. The historical
`--simulation-profile` keeps its ordinary bindings and hold declarations. Its contract 1.2 mapping
revision is `bd169e1fddae247e` (former contract 1.1: `2813b4891860c6da`).
This example's contract 1.2 mapping revision is **`3d93301a62d6f9b6`**, pinned in `chassis-roles.json`.
The example's former 1.1 revision was `2b2ae6638f08af35`. All seven assigned controls declare
`accepts_input: true`; every other unbound control declares false.
The role mapping is consumer-owned; it conveys simulation roles and no hardware authority.

Read-only Pipe assembly check (does not start Pipe, import with bytecode writing disabled):

```sh
python3 -B configs/verify_simulation_roles.py --provider build/swiftpm/debug/BCRProviderService
```

Use `--pipe-root` if the consumer checkout is elsewhere, and `--sdk` to select the verified SDK.
Missing Pipe source is reported as SKIP. An incompatible consumer is reported as a failure with its
actual error; the check does not change the consumer or patch its version/capability tables.

The current Pipe consumer was verified against this example under contract 1.1 before the upgrade.
Its existing contract allowlist contains only 1.1, and its capability vocabulary lacks
`feedback.unsequenced` and `controls.input_declared`. With the supplied 1.2 mapping it currently
rejects assembly as `invalid_mapping_config: Unsupported contract version allowlist`. The consumer
must add contract 1.2 support, both capabilities and the new profile/mapping pins before using this
delivery. No consumer source or validation table is patched by this repository.
The remaining consumer updates include `delivery.py`'s fixed SDK_VERSION (currently 1.1.0),
`chassis_roles.schema.json`'s contract version enum (currently only 1.1), and its reviewed profile
version/mapping pins. These are consumer-owned changes; the supplied SDK itself is 1.2.0.
