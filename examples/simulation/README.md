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

Both simulation modes declare hold leases only on buttons accepting input with a momentary binding.
The default `--simulation-profile` contract 1.3 mapping revision (unchanged from corrected 1.2) is `ef0e106767594759`
(former 1.2: `bd169e1fddae247e`; former 1.1: `2813b4891860c6da`).
This example's contract 1.3 mapping revision (unchanged from corrected 1.2) is **`3d93301a62d6f9b6`**.
The example's former 1.1 revision was `2b2ae6638f08af35`. All seven assigned controls declare
`accepts_input: true`; every other unbound control declares false.
Consumer-specific assembly mappings and checks belong under `integrations/<consumer>/`.
They are optional integration examples, outside the public delivery convention; consumer format
changes can make them stale. The simulation configuration above remains a generic host example.
