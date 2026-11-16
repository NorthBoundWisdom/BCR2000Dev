# H status-panel attended preparation (not executed)

No physical commands in this plan are run by H. No preset, learning map or qualification is changed.
Use only the existing explicitly selected profile/map; stop on any identity, mapping, source or gate mismatch.
A later operator must be beside the device and give fresh confirmation before every sending stage.

## USB MIDI display delivery limit — needs physical measurement

The H throughput figures stop at a Debug fake `SurfaceDevice.send`; they do not establish a USB MIDI
or firmware delivery limit. The reliable physical upper bound is **needs physical measurement**.

Prepare a separate capture directory and record the binary/manifest/map hashes and the current preset
number. Do not switch presets in software, send BCL or install a new map. First start in observe mode
and verify zero lifecycle output. Ask the operator to verify the chosen physical display targets against
the learned map, then stop that process. Start write + explicit display permission only after new
confirmation; startup/reconnect/stop must still send zero.

For a future explicitly confirmed sending trial, use a display credential and an agreed visible pattern
on the already declared rings. Begin with eight targets at 1 Hz, then request a new confirmation before
5 Hz, 10 Hz or a higher proposed rate. Keep the explicit software quota above the proposed request rate
so that quota refusal is not confused with device loss. No input/renew/reset is sent. Keep hands clear,
observe only, and stop immediately at a missed pattern, order discrepancy, flicker or identity change.

Record per-request send/transport timing, an independent USB capture where available, and the operator's
observed sequence separately. Transport acceptance and USB endpoint delivery are not firmware/light
acknowledgments. Without an independent per-message device observation/readback, report only the
observed rate and the unresolved loss/order limit; do not label a fake-device maximum as reliable USB
capacity. Do not increase device qualification automatically. Clear only the explicitly used targets to
their declared resting styles under a separately authorized display action; stop/reconnect itself sends zero.

## State-panel demo stage

This is a prepared stage only. H rehearses it with simulation and a Debug fake device, never a physical endpoint.

1. Verify this exact package/candidate manifest using `BCRProfileTool --verify-hardware-candidate <candidate-directory>`;
   keep `hardware_qualified=false`. Confirm the current device preset and learned map manually without changing them.
   The default map has visualization-only buttons and is refused by the demo before any write. Its 1dot/12dot
   rings still have a lit dot at zero, so they cannot substitute for an extinguishable freshness lamp.
2. Ask the operator to select encoder group 1 **locally** and verify the visible controls: six joints on the first
   six top rings, chassis speed and steering on the remaining two, synthetic phase on fixed lower `encoder.1.1`,
   freshness on the candidate `button.1.1`. The program never sends a group/preset/mode change.
3. With fresh confirmation for this sending stage, start an owned headless host using the existing explicit
   candidate map/configuration, `--source hardware --hardware-profile --hardware-output write --allow-surface-feedback
   --display-write-limit 300 --surface-client-tokens-stdin`. Supply roles through a private anonymous JSON pipe;
   retain owner/operator separately and give only a display credential to the demo's separate anonymous FD.
   Start/reconnect/stop of this host must send zero. No real chassis or actuator is connected.
4. The person must be beside the device and answer: “Group 1 is selected; may this synthetic 15-second display
   demo run and return to rest?” After that confirmation run the packaged CLI (FD is a descriptor number):

   ```sh
   PYTHONPATH=<delivery>/surface-control-sdk-1.4.0.zip python3 -B -m surface_panel_demo \
     --url <owned-ready-url> --instance-id <owned-instance> --token-fd <DISPLAY_FD> \
     --mapping bcr --source hardware --hz 1 --duration 15
   ```

5. Ask what the person actually sees: eight top rings follow synthetic arm/chassis actuals; the fixed phase ring
   changes; freshness is on while publication is current. On duration expiry or one explicit SIGINT, freshness
   goes dark first and attempted numeric targets return to their mapped resting positions. A resting numeric
   dot is not an off lamp. Record the person's observation separately from transport acceptance.
6. With another fresh confirmation, rehearse source loss using `--source-stops-after 2 --max-age 1 --hz 5 --duration 10`.
   After the publication age expires, freshness must go dark and the other attempted targets return to rest;
   report `source_stale`/exit 1 with `cleanup_failed=0` as the expected stale outcome. No input, renew or reset
   is called, input_sequence stays unchanged, and no automatic reconnect/rediscovery/replay occurs.

A failed or unknown cleanup is reported as nonzero; USB removal/SIGKILL cannot guarantee physical darkness.
Stop on any discrepancy, record raw evidence and do not retry or promote the candidate. The source is synthetic,
not Pipe or live hardware telemetry. `status-panel-demo.md` is the shared tool reference.

The default GUI does not register the optional control-contract tools, so this CLI connects to the headless host.
The actual GUI VM/panel render path is tested separately on the same unique session; this does not claim a direct
CLI endpoint in the default GUI. Do not add GUI tools or bypass its local hardware synchronization confirmation.
