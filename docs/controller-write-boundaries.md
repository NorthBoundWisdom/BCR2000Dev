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

## Synchronous display transaction receipts and reentrancy

An explicit hardware display request uses an invocation-local receipt, passed only along that request's
planned sends. Nested requests own different receipts; ordinary nested feedback cannot fill the caller's
receipt. The bounded monitor ring remains diagnostic and never decides whether a request completed.

`device.send` returning successfully establishes transport acceptance. The canonical contract completion
hook runs at that point, before monitor, legacy journal or presentation callbacks. A hardware input committed
during `send` is already canonical and remains intact; a nested feedback completed from a later monitor
callback appends after the outer receipt. No whole contract candidate is kept across IO and assigned back.
CAS and writer budget checks remain at admission, once. Completion appends to the current same-epoch core
with the already-consumed CAS removed and a current trusted monotonic timestamp.

A later successful same-control/kind feedback invoked from inside an earlier `send` supersedes the older
completion. A per-property operation ordinal tracks ordering only, not values or a second authority. The
older transport acceptance remains visible, but the older transaction returns `delivery_failed` rather than
appending an accepted value over the newer one. An unsuccessful newer request does not suppress an older
successful completion. For monitor-triggered nesting, the outer receipt commits first, both accepted events
remain ordered, and the newer projection wins.

Failed display planning reverts only its still-owned display overlay and, when untouched, its own generated
control projection. Each overlay mutation has an ownership revision, including repeated equal values.
Rollback never restores an engine snapshot, parameter/configuration state, echo cache or input references.
Across source/route/binding changes, an old request can only revoke its own still-owned overlay; it cannot
restore an old-context overlay or overwrite a newer operation's projection. No compensating packet is sent.

If IO was accepted but the epoch changed or the transaction could not be canonically completed, the existing
`delivery_failed` code reports incomplete transaction completion. Output may already have happened. This is
not `stale`, does not promise non-execution, adds no remote field/tool/schema and causes no automatic resend.
