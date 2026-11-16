# G-1 direct shared values and host boundaries

The retired `BCRAgentCore` export target/product and the Agent/Robot/Chassis/Output domain
wrapper targets are removed. The now-unused `BCRSimulationKernel` compatibility wrapper is
removed too. The existing XCTest target name `BCRAgentCoreTests` is retained for stable inventory;
its source files import the actual modules directly. There is no replacement export target,
model typealias layer, second parameter dictionary or second plugin authority.

## Production responsibility map

| Before | Current actual owner |
| --- | --- |
| RobotSimulator/ChassisSimulator wrapper containing a plugin | ProviderApplication reads the actual RobotPlugin/ChassisPlugin from the canonical runtime binding and stores that value back atomically; commands use `.simulator` directly |
| Wrapper-created instance and control UUIDs/start state | ProviderApplication private factories and acquire boundary retain `UUID().uuidString` and the same `.start` input at time0 |
| withLegacySimulationErrors in the legacy kernel | BCRFoundation/SimulationErrorPresentation.swift, same code/message mapping; permission and stopped checks retain their original per-operation priority |
| MotionLimit/RobotModel/AckermannModel host copies | Actual shared Codable types; same required fields, defaults/unknown-key behavior and public wire values |
| MotionSafetyGate containing ParameterOutputPlugin | OutputController directly owns/retrieves the shared ParameterOutputPlugin; private construction preserves start/error behavior |
| Date ParameterSample | Explicit ParameterObservation transport observation projection; monotonic channels use shared ParameterSample directly; conversions remain at actual Controller/IO boundaries |
| Localized decision/error/status | ConfigurationAdapter OutputDecisionPresentation/legacyOutputReason; no safety evaluation or fabricated command is implemented there |
| OSCCodec default BCR namespace wrapper | Shared codec called with explicit `/bcr/param/` and `/bcr/state/` at IO sites; outer error presentation retained |
| SharedJSONParameterLink alias and unused Date link wrapper | WebSocket adapter uses actual shared JSONParameterLink, including its existing host UUID session and monotonic receipt clock |
| Legacy Date AgentStateMachine | Removed; actual shared machine remains authoritative. UI slots are AgentSlotPresentation values, not another machine |
| AgentSlot Codable projection mixed into domain | AgentSlotArchive in PersistenceAdapter preserves the six required keys/id/date representation; actual MCP read-agents uses this archive encoder |
| Implicit shared-time-to-Date projection | Actual MockHost passes its existing Unix-anchor-converted Date to the production projection initializer explicitly |

The selected old wrappers did not normalize incoming UUID strings: they created host UUIDs and
forwarded generation/token strings to the shared contracts. That behavior is retained, including
opaque case-sensitive token matching. Initialization rotates the generation; the new boundary test
must read that new generation before acquiring. An initially stale test expectation and initially
wrong invalid-control code/message are preserved as failed test-authoring evidence, not fixed by
loosening the product's generation or token checks. Actual old e615 and new process RPC results
match for generation rotation, stale-generation priority and different-case invalid-control errors;
old e615 backend/error/adapter source is also byte-identical to the G baseline 7a.

No remote tool name/schema/error contract, contract1.0–1.4 semantics, frozen fixture, device
map/preset, hardware qualification document, package layout or manifest field was changed.

## Test migration, without reduced assertions

Most changed tests only replace a facade import with imports of the real modules. In particular
SSE, hardware output policies, connection/preset logic and G6 goldens retain their bodies/assertions.
The exact changed-method list is in `build/g/g1/test-method-migration.json`.

| Original purpose | Current real tested path |
| --- | --- |
| AgentStateMachineTests three lifecycle/invalid-transition/interruption cases | Shared AgentStateMachine with explicit integer slot/time/statusKey; same transitions/state/progress assertions, invalid transition checks the actual shared code and index/from/to fields |
| AgentCompatibilityFacadeTests state identity/all transition pairs | Shared enum plus frozen host policy truth table over every pair; avoids comparing the same helper to itself |
| AgentCompatibilityFacadeTests Date/name/text/Codable/update | Actual AgentSlotArchive and production `AgentSlotPresentation(core:..., lastUpdated: Date)` initializer; actual shared transition policy; every old archive key/name/text/date and invalid-transition purpose retained |
| SimulationTests typed robot/chassis motion/barriers/limits | Actual shared simulators with explicit host-style UUID instance/control tokens; original time/trajectory/pose/stop assertions unchanged; shared busy error code checked at the shared layer |
| SharedSimulationCompatibilityTests canonical state/isolation/UUIDs/exact errors/lifecycle | Actual ProviderApplication command/runtime boundaries, actual shared plugin binding snapshot, old error messages and stopping/advance behavior; custom old-model JSON decodes directly to the actual shared model |
| MotionSafetyTests and SharedOutputCompatibilityTests | Actual shared output plugin; tiny test fixture only starts it and invokes real setEnabled/evaluate with Date seconds. No copied gate algorithm/catch/frame fabrication. Localized diagnostics use actual production OutputDecisionPresentation |
| JSONParameterLinkTests | Actual shared link with explicit Double timestamps; original heartbeat/freshness/replay/session/stop-frame assertions retained |
| OSCCodecTests | Actual shared codec with explicit old BCR prefix; original byte/roundtrip/malformed-input assertions retained |

Six new methods add independent boundary coverage: two old Agent archive required/unknown/id/date
cases, two old OutputSettings/shared-limit required/unknown/default/structural-read cases, and two
actual Application UUID/permission/stopped/generation/error-priority cases. No existing method was
removed; method renames preserve their purposes and are listed in the migration JSON.

## Results and independent build path

G baseline before G1: 703 total, 0 failures, 1 explicit opt-in hardware skip. Final production native
batch: 709 total, 0 failures, 1 same skip; Python workflows138 and client6 pass. The new independent
build path `build/g/g1-clean` compiled every module from scratch, with no retired module available.
The canonical batch runner then used its actual `.../g1-clean/out/Products/Debug` bundles and passed
all709 cases (binary-path.log and xUnit retained).

An auxiliary stock serial `swift test --build-path build/g/g1-clean --jobs 2` run earlier compiled
successfully but produced703 pass/1 fail/1 skip of705 methods, with SSE backpressure timing out.
This result is retained and **not attributed** without a baseline reproduction. The SSE method,
HTTP server logic and manual-clock fixture are byte-equivalent to7a after imports; the canonical
fresh/default batches passed. No SSE timeout/assertion was changed and the stock command was not
rerun to conceal its failure. The four later new boundary/archive methods explain the705→709 count.

Private non-delivery package checks: raw simulation description SHA remains the original f1045e...
value; 19 real-process surface cases and all14 startup/catalogue CLI cases pass. No delivery was
published or old F package/INDEX changed. Exact command paths, raw failure logs and counts are in
the appended G-B handoff and `build/g/g1/` evidence.
