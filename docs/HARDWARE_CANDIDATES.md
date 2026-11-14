# Independent, unverified hardware candidates

`visualizationOnly` is the host's safety policy for newly imported button identities. It prevents
newly discovered buttons from inheriting old Agent/macro/parameter actions and functional LED
writes. It is not evidence that the physical buttons are incapable. The existing learned map and
hardware-validation documents remain unchanged.

The supplied original map has 52 visualization-only buttons. `BCRProfileTool` can stage a separate
candidate using **only existing IDs and MIDI identities**:

```sh
./BCRProfileTool --stage-hardware-candidate hardware-map.json role-readiness-request.json /private/new-candidate
./BCRProfileTool --verify-hardware-candidate /private/new-candidate
```

Use a fresh destination; existing files/directories are never replaced. Optional `--configuration
PATH` supplies a read-only source configuration; otherwise the source basis is the host's neutral
default. The output contains original source bytes, SHA-256 hashes, a change plan, candidate map
and configuration, and a software-readiness report. Duplicate keys/IDs/routes, repeated roles,
unknown encodings and pulse/unknown button modes fail closed. Only the selected two existing
momentary buttons change their candidate visualization policy. MIDI addresses, press mode,
all other mappings, original files and device presets remain unchanged.

The candidate configuration has exactly four neutral parameters (`candidate.button_a`,
`candidate.axis_a`, `candidate.axis_b`, `candidate.button_b`) and no Agent/macro/output actions.
The candidate uses existing host display routes. No BCL/preset/mode command is generated or sent,
no map is installed, and staging never starts a provider.

`software-readiness.json` can say `ready:true`: that describes only deterministic host-engine
acceptance under declared startup permissions. **The enclosing candidate-manifest.json and
candidate verifier retain ready:false, software_ready:true, hardware_qualified:false and
unverified/test-only identity.** Fresh physical button edges, current preset identity and per-button
LED output evidence have not been acquired for this exact candidate. A hash or fake-device test
cannot supply those facts. The bundled candidate is never the default hardware profile.

After separate attended authorization, an isolated observation command would be:

```sh
./BCRProviderService --source hardware --hardware-profile \
  --hardware-map /private/new-candidate/candidate-hardware-map.json \
  --configuration /private/new-candidate/candidate-configuration.json \
  --surface-instance-id candidate-review --port 0 --token-stdin
```

This command is documentation, not an auto-apply action. It retains default `observe`; do not run
it during offline development. Display testing additionally needs BOTH `--hardware-output write`
and `--allow-surface-feedback` and fresh attended approval. Existing Provider write-mode startup
resynchronization is unchanged; count startup sends separately from each requested display.
Use the separate candidate evidence checklist. The default attended checklist is not changed to
load or apply these files.

For a read-only diagnostic record use the independently bundled `surface_control_diagnostics`
package. Captures are bounded and write no surface tool; offline verification establishes only
recorded protocol invariants, not physical qualification or a missing LED observation.
