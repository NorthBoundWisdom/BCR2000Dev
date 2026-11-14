# Offline hardware role readiness

`BCRProfileTool` already stages configurations. Its additional **read-only** mode checks an
explicit four-role request against a learned map and a configuration without constructing a
MIDI device, dispatching engine effects, writing a map or changing a preset:

```sh
BCRProfileTool --check-hardware-roles hardware-map.json role-readiness-request.json \
  --hardware-output write --allow-surface-feedback
```

Add `--configuration PATH` if the provider will use a configuration other than its neutral default.
The tool evaluates an injected input on a `SurfaceEngine` copy. `engine_accepts_input` means the
host engine would accept this encoding in the supplied configuration; it is not an observation
from a physical device. `accepts_input:false` in contract 1.4 only forbids remote input and must
never be used to infer whether a physical button is functional.

Enable and stop require distinct momentary buttons, declared press/release and engine acceptance.
Linear and steering require distinct absolute axes. Visualization-only buttons, relative/NRPN
encodings, missing IDs and pulse/unknown press behavior fail closed. The tool also checks declared
feedback kinds plus **both** startup `write` policy and display permission. These are declared
flags, not a live permission grant. Set `require_feedback:false` only for an explicitly input-only
request; the output still states which feedback is unavailable.

Exit 0 means the supplied offline request passes; exit 3 is a machine-readable `ready:false`
with `missing` reasons and available IDs; exit 2 is invalid input. All reports state
`hardware_qualified:false`. Recheck the exact current files and startup flags before preparing a
consumer. Never treat a previous report or an ignored event as a held enable or stop.

The delivered `role-readiness-request.json` is an **unqualified request**, not a learned map or
approved consumer binding. The package's report assumes write plus display permission to isolate
missing map capabilities. With the current 108-control learned copy it reports 56 accepted axes,
zero functional momentary buttons and zero indicator endpoints: all 52 buttons are visualization
only. The package therefore remains unavailable for the requested enable/stop roles, and no map
or preset is modified automatically. Physical qualification remains a separate attended action.
