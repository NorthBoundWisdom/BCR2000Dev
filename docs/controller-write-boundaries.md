# Revocable parameter writes and endpoint evidence

`SurfaceSession` owns an optional `ParameterWriteContext`. A host explicitly installs it with
`configureParameterWrites`; changing remote Agent permissions does not silently change local operator rights.
With no context and no authority callback, existing local and Provider 1.0 behavior remains in force.

The same dynamic decision checks trusted caller identity, source, input generation, binding revision and
parameter scope for GUI value edits, software controls, group reset, scenes, macros, remote value writes and
Undo/Redo. Value permission and display permission are independent. Existing Agent-specific protection,
argument validation, rate budgets and device safety checks remain in their existing entry points. Real
physical observations remain input evidence; denying display never fabricates or discards them.

A host may install a trusted local `parameterAuthority` callback. It receives the requested value and its
source/context, and accepts or rejects it with a finite, representable authoritative business value and a
reason. Invalid or stale replies fail closed. Rejection restores the single engine value, discards generated
feedback, clears pending feedback and reports a visible error through the GUI intent owner. It creates no
successful input or Undo entry and supplies no device-observation evidence. This callback is not a remote
tool. A guarded batch validates every value and rechecks all dynamic authorizations after callbacks before
committing any requested value. Device callbacks run after this guarded commit and each send rechecks display
permission. Without these explicit extensions, Provider 1.0 preserves its original per-entry synchronous
result/journal/publication timing.

`MIDIEndpointDescriptor.provenance` is explicit: `unknown`, `physicalUSB`, `localVirtual` or `remoteVirtual`.
A name does not establish transport origin or qualification. CoreMIDI currently reports `unknown` when it
cannot prove transport origin; fake adapters must state their own origin. No hardware-map qualification is
promoted by this metadata.

`SurfaceInputBatch` carries an immutable `MIDIEndpointSource` captured before transport-to-main-actor handoff.
The production CoreMIDI transport captures endpoint identity and its connection generation before connecting
that route; the receive callback passes that route evidence with the decoded batch. The service rejects old
generations. `SurfaceSession` retains that evidence in input monitor events and stops an old batch after a
reentrant route change. Legacy synchronous adapters capture a snapshot at callback entry. An unknown device
identity stays `nil`; endpoint identity and connection generation remain explicit. No frozen remote discovery
or tool schema gains these internal fields.

Feedback queues retain endpoint/generation and binding revision from enqueue time. A send rejects stale
metadata, snapshots the actual outgoing route before calling the device, then records success only after
transport acceptance. A synchronous reconnect inside `send` cannot relabel the attempted send as belonging
to the new endpoint. CoreMIDI additionally validates the expected transport generation on its serial output
queue. GUI and headless Provider use this same session/driver route.

These are software tests with fake devices, not physical qualification. No device connection is needed.
