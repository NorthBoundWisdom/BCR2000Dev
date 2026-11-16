# ControlSurfaceKit adapter field map and shadow boundary

The managed Kit pin is `655f443abb2a3977e6c30deb1fe6d20a97d47191` from
`https://github.com/NorthBoundWisdom/ControlSurfaceKit.git`. Source overrides acquire committed objects only;
compilation always uses the clean manager-owned `build/seed/ControlSurfaceKit`. The companion shared pin is
`12ba0edbc1f2c46eea5311f9b8f982d563c55b75`. Production imports only `SurfaceDeviceContracts`; conformance
format/assertions/comparison are test support and forbidden in production targets.

The primary conformance runner now consumes the Kit ScenarioCatalog/ScenarioAction and AssertionEvaluator;
legacy dictionary driving/assertions remain only as the independent native shadow reference oracle.
J-2 defines and projects values. The native Session, codec, mapping, history, lifecycle, feedback planner,
scheduler, device safety and transport remain the original owners. Shadow comparisons do not establish that
J-3/J-4 runtime behavior has been extracted. The typed ScenarioAction entry is confined to the device test
adapter; it calls existing native APIs and never exposes a new hardware-input RPC. The production neutral
input port is an output-only observer of accepted transport/simulator input. Public neutral values are not
input authorization.

All neutral timestamps come from injected monotonic time. Native wall dates remain audit evidence only.
The parameter/plugin authority stays in the existing host/shared owners, never in Kit.

| Existing type/field | Neutral destination or adapter-only reason |
|---|---|
| MIDIControlKind.controlChange/note/nrpn | adapter-only protocol syntax; mapped logical element determines InputCapability.kind |
| MIDIControlID.kind | adapter-only protocol syntax |
| MIDIControlID.channel | adapter-only MIDI address |
| MIDIControlID.number | adapter-only MIDI address; learned HardwareMap resolves the logical interpretation facet, then the adapter maps stable physical actuation role separately; no numeric MIDI address enters the neutral value shape |
| MIDIControlID.description | adapter-only localized protocol UI text |
| MIDIVoiceMessage.nrpn(channel,number,value) | channel/number stay adapter; decoded value → DeviceValue.number(Double(value)) on neutral input/effect (not business quantization) |
| MIDIVoiceMessage.controlChange(channel,number,value) | channel/number stay adapter; value → number, kind absolute/relative/press/release determined by learned control policy |
| MIDIVoiceMessage.noteOn(channel,number,velocity) | channel/number/raw velocity stay adapter; only declared momentary maps to press/release; pulse/unknown maps to absolute Boolean signal state |
| MIDIVoiceMessage.noteOff(channel,number,velocity) | wire fields stay adapter; release is asserted only for declared momentary, otherwise report signal state without physical release/hold evidence |
| MIDIVoiceMessage.controlID | adapter resolver input; output targetID is logical display target |
| MIDIVoiceMessage.value | seven-bit UI projection remains adapter; avoid turning it into a second authoritative value |
| MIDIVoiceMessage.dataValue | exact decoded raw value feeds number; no normalization/quantization in Kit |
| MIDIVoiceMessage.maximumDataValue | protocol capacity stays adapter; ElementCapability only states number/flag kind |
| MIDIVoiceMessage.isPositiveActivation | learned protocol/press semantics stay adapter, resolved neutral press/release emitted after decoding |
| MIDIVoiceMessage.diagnosticDescription | localized device diagnostics stays adapter |
| MIDIVoiceMessage.midi1Bytes | wire encoding stays adapter; never enters neutral effect |
| MIDI1UMPCodec | every function adapter-only: packet word count, decode/encode, group nibble, feedback/feedback14 are MIDI protocol knowledge |
| MIDIEncodingError.invalidMessage/requiresMultipleWords | adapter failure; trace rejection reason is semantic string, not Kit MIDI enum |
| NRPNAssembler.channels | adapter-only fragment state; Kit consumes complete logical events |
| NRPNAssembler.Selection.msb | adapter MIDI selector fragment |
| NRPNAssembler.Selection.lsb | adapter MIDI selector fragment |
| NRPNAssembler.Selection.dataMSB | adapter MIDI data fragment |
| NRPNAssembler.Selection.date | adapter fragment expiry clock (existing Date injection), no neutral system-clock read |
| DeviceSource.mock | SurfaceDeviceContracts.DeviceSource.simulation |
| DeviceSource.hardware | SurfaceDeviceContracts.DeviceSource.hardware |
| DeviceSource.id | adapter UI identity, same raw source projection above |
| HardwareOutputPolicy.observe/write | adapter direction authorization; cannot become optional device-safety switch in Kit |
| MIDIConnectionSnapshot.sourceEndpoints | adapter inventory; selected endpoint gives EndpointProvenance, full native inventory stays adapter |
| MIDIConnectionSnapshot.destinationEndpoints | same as sourceEndpoints, output direction distinct |
| MIDIConnectionSnapshot.transportGeneration | EndpointProvenance.connectionGeneration (UInt64 exact conversion) |
| MIDIConnectionSnapshot.connectedSourceID | EndpointProvenance.endpointID for input, String(Int32) if known |
| MIDIConnectionSnapshot.connectedDestinationID | EndpointProvenance.endpointID for output, String(Int32) if known |
| MIDIConnectionSnapshot.sourceNames/destinationNames | UI labels stay adapter; never infer transport origin |
| MIDIConnectionSnapshot.connectedSource/connectedDestination | UI labels/readiness stay adapter; neutral context identifies opaque route, not name |
| SurfaceSession.mappingContextRevision / inputEvents.generation | belong to opaque DeviceContext.generation, not a content hash; DeviceContext.mappingRevision stays nil unless content revision is independently proved |
| MIDIConnectionSnapshot.lastError | adapter diagnostic; failing trace may use reason, no global mutable Kit error owner |
| MIDIConnectionSnapshot.isConnected | adapter determines lifecycle fact; J2 does not introduce connection reducer |
| MIDIConnectionSnapshot.hasSameRoute | adapter route comparison; J3 separately audits old-generation invalidation |
| SurfaceDevice.connection | adapter port state; native object lifetime never in Kit |
| SurfaceDevice.onMessages | adapter callback only; decode → immutable DeviceInputEvent at host boundary |
| SurfaceDevice.onConnection | adapter callback only; J3 value reducer later, not J2 |
| SurfaceDevice.send | adapter IO only; EffectDescriptor + TransmissionEvidence describe before/after without doing IO |
| MockSurfaceDevice.model | simulation device model stays adapter, not business authority in Kit |
| MockSurfaceDevice.connection | neutral source simulation; missing native endpoint ID stays nil while separately known localVirtual origin is retained; no synthetic ID is invented |
| MockSurfaceDevice.onMessages/onConnection | same adapter callback mapping as SurfaceDevice |
| MockSurfaceDevice.model.encoderModes (configureModes) | learned/Mock protocol behavior stays adapter |
| MockSurfaceDevice.model.activeGroup (selectGroup) | group stays adapter; opaque context id/revision projects into DeviceContext |
| MockSurfaceDevice methods send/setNRPN/resetInputState/turn/move/applyCapturedInput/emit/press/release | pure simulator/device protocol code stays adapter; complete input/observed/send facts cross neutral boundary only |
| SurfaceInputBatch.messages | each resolved native message → DeviceInputEvent; packet decoding/NRPN assembly stays adapter |
| SurfaceInputBatch.endpoint | EndpointProvenance exactly; never reconstruct from current route |
| SurfaceInputObserving.onInputBatch | adapter callback; neutral API remains synchronous Sendable values |
| MIDIEndpointDescriptor.id | EndpointProvenance.endpointID |
| MIDIEndpointDescriptor.name | adapter presentation only |
| MIDIEndpointDescriptor.availabilityKnown | native enumeration evidence stays adapter, never become permission/qualification |
| MIDIEndpointDescriptor.provenance | EndpointProvenance.transportOrigin exact enum mapping |
| MIDIEndpointSource.endpointID | EndpointProvenance.endpointID; existing unknown sentinel requires explicit nil/unknown mapping (must not silently invent identity) |
| MIDIEndpointSource.deviceID | EndpointProvenance.deviceID, nil preserved |
| MIDIEndpointSource.connectionGeneration | exact same UInt64 |
| MIDIEndpointSource.provenance | transportOrigin exact mapping |
| MonitorEvent.id | trace step/effect correlation identifier; native ordering retained |
| MonitorEvent.time | audit/UI wall-clock stays adapter |
| MonitorEvent.monotonicTime | neutral input/observation/transmission at |
| MonitorEvent.direction | input→DeviceInputEvent; output→EffectDescriptor/TransmissionEvidence distinct |
| MonitorEvent.source | .mock→simulation; .hardware→hardware |
| MonitorEvent.message | decoded logical payload maps, raw MIDI stays adapter |
| MonitorEvent.control | original group-qualified logical facet stays binding/display target; neutral input elementID and Effect.affectedElements use the separately mapped stable physical actuation role |
| MonitorEvent.inputPressMode | receipt-time learned mode, momentary versus pulse/unknown; only the former establishes press/release edges |
| MonitorEvent.ignored | trace accepted/rejected metric; ignored raw packet must not become accepted DeviceObservation |
| MonitorEvent.origin | trusted caller identity remains adapter authorization; not a transport source override |
| MonitorEvent.delivery | actual .sent→TransmissionOutcome.accepted; actual attempted .failed→rejected reason. Pre-IO disconnected/suppressed remain ShadowDecision.rejected/ignored, with no invented TransmissionEvidence; never observation evidence |
| MonitorEvent.endpoint | neutral provenance captured at original receipt/send |
| MonitorEvent.context.generation | original input/session generation captured before callbacks/IO; opaque DeviceContext.generation |
| MonitorEvent.context.mappingGeneration | binding counter captured at the same cause; composed into opaque generation, never a content revision |
| MonitorEvent.context.knownDeviceContextID | explicit in-process simulation context only when captured from the actual model; hardware group remains unknown without trustworthy protocol evidence |

Mapping caveats: existing unknown sentinel is mapped explicitly to nil; it must never become a fabricated ID. Current Kit EndpointProvenance permits separately known localVirtual origin with nil endpoint identity, as supervisor decided. Native deviceID proof is absent and stays nil. DeviceContext.mappingRevision means proved content revision, not the host's incrementing mappingContextRevision; those generation counters belong in the opaque context generation. Neutral capabilities union structural input/display kinds by physical actuation role; logical targets remain in the adapter; CC/NRPN ranges, group counts, LED modes, BCL transactions, Quick Learn and hardware qualification remain adapter-owned. Native wire fields remain available for codec/capture/GUI, not silently omitted to pass shadow comparison. A suppressed/disconnected plan without an actual IO call is a decision trace, not a transmission result.

## Additional state/effect mapping

| Existing field/case | Neutral destination or adapter-only reason |
|---|---|
| SurfaceControlState.rawValue | raw codec/UI state stays adapter; not an observation when default0 or lastDirection output |
| SurfaceControlState.value | projected seven-bit display state stays adapter; cannot become authoritative DeviceObservation |
| SurfaceControlState.lastInput | no independent position claim from this cache; genuine absolute input projects to <element>.input.position, genuine relative input only to <element>.input.relative-delta. Missing position stays unknown |
| SurfaceControlState.lastOutput | sent/display cache stays adapter; transport accepted fact separately TransmissionEvidence, never observation |
| SurfaceControlState.lastDirection | identifies input-vs-output evidence provenance, not permission |
| SurfaceControlState.eventCount | adapter acceptance evidence mapped to ShadowSample accepted count; no invented observation sequence |
| LEDFeedbackSource.target/actual | adapter chooses projection source from existing authority, no second Kit parameter store |
| MIDIObservationDirection.input/output | neutral input/effect/transmission fact classes remain distinct |
| SurfaceEffect.send(message) | adapter decode→EffectDescriptor(display), raw bytes remain adapter; actual side effects union must be preserved |
| SurfaceEffect.triggerAgent(slot)/triggerAction(ref) | business action dispatch stays host; neutral shadow records result/direction, never owns business actions |
| SurfaceEffect.pageChanged | adapter context event, opaque DeviceContext generation changes; no Kit page vocabulary |
| SurfaceEffect.programsChanged | adapter configuration owner remains authority, opaque context refresh |
| SurfaceEffect.learned(control,midi) / learnRejected(control,error) | Quick Learn device policy remains adapter; shadow decision observes accepted/rejected and context |
| SurfaceEffect.unmappedInput(midi) | adapter raw decode result retained; neutral ignored decision cannot invent an element identity |
| ScheduledFeedback.message | wire payload stays adapter until J4; immutable semantic description is projection, not scheduler replacement in J2 |
| ScheduledFeedback.origin | trusted cause stays adapter, no remote source forgery |
| ScheduledFeedback.endpoint | EndpointProvenance same enqueue evidence; nil remains unknown |
| ScheduledFeedback.mappingRevision | queued-context counter belongs generation; not DeviceContext.mappingRevision content claim |
| ScheduledFeedback.source/context | immutable enqueue-time source and original generation/binding context; consumption requires the complete identity, not equal bytes alone |
| FeedbackPolicy.enabled/messagesPerSecond/burst/errorCooldown | scheduler-specific policy stays adapter for J2; J4 requires separate shadow analysis before any shared behavior |


## Evidence semantics and content identity

An observed relative delta has target ID `<element>.input.relative-delta`; it cannot be mistaken for
`<element>.input.position`. Button/contact observations likewise carry explicit `.input.pressed` or
`.input.contact` roles. Stable element IDs are unchanged. Positions that were never received are not
manufactured from defaults, relative deltas, feedback, transmitted values or cache silence.

The capability profile is a deterministic content identity over the learned map and each device input-mode
interpretation that can change the declared capability. It excludes business parameter values, definitions,
bindings and generation counters. The same map with absolute versus relative decoding has different content
IDs and declarations; changing only a business default value does not change the capability ID.

Only an actual `send` attempt produces transmission evidence. A suppressed or disconnected plan is retained
as a native decision/feedback fact with no TransmissionEvidence. Send acceptance never becomes device
observation. Native MIDI records, per-message origin, full queue order, raw values/relative encoding and
preset frames remain available to the device adapter and shadow trace.

## Shadow procedure

`ControllerRegressionExecutorTests` creates two separate Session/device/clock/identity owners for every
applicable scenario. One drives the original dictionary/native entry, the other drives Kit ScenarioAction
through the device test adapter. It compares complete before/after native metrics, original assertions
against Kit AssertionEvaluator, actual legacy accepted-input facts against every projected neutral field,
and all ShadowSample fields. The latter include decisions, original generations, queue/revocation identities,
observations, feedback, transmissions and complete opaque native monitor/API/transport/preset records.

Each owner receives its own deterministic generation/epoch sequence, changing on every actual reset/route
transition. No token normalization, epsilon, missing-field default, field ignore list or ideal reducer is
used. Host principal records use the existing trusted 0600 loader with fixed non-credential fixture IDs;
credentials, ephemeral HTTP ports and OS process IDs stay transport-test diagnostics, not fake comparable
business evidence. Live product defaults still generate fresh UUID epochs and host-owned random principals.

To collect the paired raw trace, run the normal full test workflow with `BCR_J2_SHADOW_ROOT` pointing at a
fresh evidence directory. The original regression report is independently validated by the Kit's migrated
validator. The fixture SHA and three G-6 output files remain byte comparisons, separately from conformance.

## What a new adapter supplies

Supply protocol decoding/encoding, stable physical actuation-role IDs and separate logical target IDs, actual endpoint/generation evidence,
capabilities, explicit device-side effects and immutable facts. Keep device-specific safety at this boundary.
Do not implement business quantization or parameter storage in the adapter/Kit. A future device can consume
the same neutral format and conformance data now; shared lifecycle/binding/scheduling behavior still requires
the later separately verified extraction blocks.


## Physical roles, logical facets and unknown device context

The legacy `BCRControlID(section,row,index)` and published control IDs are logical binding facets. For the top
encoders and their push actions, `row` is an encoder group; these are aliases of the same physical role in
different interpretations. The layout's 108 logical roles must never be described as 108 physical elements.
Old published IDs, learned maps and business bindings are unchanged.

The neutral adapter separates these dimensions:

| Meaning | Example | Evidence |
|---|---|---|
| Physical rotary actuation role | `pushEncoder.rotate.1` | Stable layout identity, shared across top-row groups |
| Physical push actuation role | `pushEncoder.press.1` | Same shaft's distinct push role, independent of rotation/group |
| Logical display/binding target | `pushEncoder.1.1` versus `pushEncoder.2.1` | Existing learned interpretation facet, unchanged published shape |
| Input context | Opaque instance + binding facet + device-context identity | Interpretation facet is known from decoding; actual hardware group remains `unknown` without independent protocol evidence |

No hardware group is inferred from the GUI's selected group or the simulator's active group. An actual
in-process simulation model may supply its captured simulation context; this cannot upgrade a hardware
source. Context generation remains the original Session/journal/binding scope, without a new group reducer.

Capability elements are grouped by physical actuation role and union their supported input/display kinds
across known logical facets. Encoder groups are not protocol modes: the adapter retains one genuine MIDI-1
mode. Effects retain the group-qualified logical target and list the stable physical role in
`affectedElements`; that is potential device impact, never a claim that an inactive group's cached display
was visibly observed on the panel. Confirmation still requires independent device/readback evidence.

## Old-IO evidence correction accompanying J-2

A send captures source, logical control, origin, endpoint and generation before calling the adapter. A
synchronous callback may change source, route or binding; the result still belongs to the captured IO.
Only a still-current scope can update echo/reference evidence or current connection error/cooldown. A failed
old flush cannot requeue its old batch after route/source/queue invalidation. The original failure remains
visible in its captured monitor fact.

A hardware route transition clears recent-feedback and transport-dependent absolute/increment/trigger
references without sending anything, replacing a learned map, cancelling learning, or changing parameter,
plugin or actual-feedback authority. Legacy control `lastInput`/`lastOutput`/direction remain historical
records to preserve their existing byte trace; the neutral producer never promotes that history to fresh
observation in a new context. These are correctness repairs to old IO attribution/expiry, separately reported
from contract-format shadow equivalence.


## Declared press mode and signal-only buttons

The receipt-time learned map supplies `HardwarePressMode`. Only declared `momentary` produces physical
press/release kinds and the `.input.pressed` observation role. `pulse` and unknown/nil mode produce
`InputKind.absolute` with the decoded Boolean signal classification and `.input.signal-state`; even raw zero
is not claimed as physical release or hold evidence. Raw magnitudes/encoding remain native protocol facts
in the adapter/opaque trace. Capabilities advertise only those kinds that the mapped facets actually support;
mode is captured from the input map, never guessed from current UI state. Published native actions/bindings
are unchanged by this value projection.


## Native learned-map fields

| Field | Placement |
|---|---|
| HardwareMap.version / entries | Adapter-owned persistence/learned device interpretation; never a second parameter store |
| HardwareMapEntry.control | Legacy logical facet, projected to distinct physical role / logical target / opaque binding-facet context |
| HardwareMapEntry.midi | Adapter-only wire identity/codec; opaque native trace keeps the complete bytes |
| HardwareMapEntry.ringMode | Device display encoding/style, adapter-only; never a core device branch |
| HardwareMapEntry.visualizationOnly | Device policy/qualification remains enforced in the native route; capability union is potential support, not permission for every facet |
| HardwareMapEntry.pressMode | Captured learned declaration controls whether an edge is proved; nil/pulse never becomes physical release/hold |

The seven migrated fixture/schema/validator files retain their original byte hashes. Shared runtime contracts,
quantization, plugins and control-session semantics remain in SurfacePlugins. Three G-6 output sequences and
all old behavior-trace fixtures retain exact bytes; the accompanying old-IO source/expiry fixes are reported
separately with failing-before/passing-after evidence.
