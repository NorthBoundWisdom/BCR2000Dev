# Console ownership after G-2

The window observes `ConsoleViewModel` and sends intents through its stable methods. The model composes a `ConsoleDeviceWork`, forwards its observations synchronously with a weak Combine subscription, and exposes computed projections. It stores no second parameter value, plugin, connection phase, or preset transaction.

| Owner | State and work |
| --- | --- |
| Existing `SurfaceSession`, `ProviderApplication` and `BCRPluginRuntime` | Canonical surface values, provider/plugin state and runtime epoch/clock. These existing owners remain authoritative; no new runtime bag duplicates them. |
| `ConsoleDeviceWork` | MIDI endpoint selection, connection offers/nonces/routes, startup and snapshot tasks, display/preset reads and evidence, alignment/restore/backup transactions, controller composition and MCP intent closures. Agent LED blinking stays here because it can produce device effects. |
| `ConsolePresentationState` | Selected control and follow-touch/group, notices and notice dismissal, workspace visibility preferences, display/transfers/transient timers, press/activity presentation and the coalesced frame task. It cannot authorize or send a device effect. |
| `ConsoleViewModel` | Composition, computed observations and intent forwarding for existing views/callers. |

`ConsoleDeviceWork+Agents` and `ConsoleDeviceWork+PresetAlignmentMCP` retain the old method bodies under the actual work owner. This is an initial separation of responsibilities, not a claim that all device work is already subdivided into smaller services. Preset/display reads stay with the same transaction owner to preserve cancellation and drain ordering.

Connection confirmation keeps its synchronous fast path when there is no previous task. When old BCL work exists, cancellation does not pretend it has drained: the writer still awaits it. Existing route, startup ID and operation ID checks prevent old callbacks from committing or clearing newer work. Session change callbacks invalidate connection work synchronously before scheduling the same 16 ms presentation frame. The background-work helper observes the actual owned task handles, including that frame; it does not create replacement handles.

Presentation forwards changes through Work and then ViewModel using weak synchronous subscriptions. The split adds no scheduling boundary or deinitialization cancellation. Presentation sleeps still use the original injected presentation clock; device work retains its original work clock. Notice duration, minimum press duration, activity duration and display token rules are unchanged.

## Verification and test mapping

All pre-existing tests and assertion bodies are unchanged in G-2. Existing connection confirmation, preset transaction, display/number evidence, LED, provider/MCP and feedback suites run through the ViewModel delegates into the new owners. The native suite grows from 709 to 716 methods solely through `ConsoleOwnerTests.swift`:

- `ConsoleDeviceWorkOwnerTests.testDirectOwnerRejectsOldRoutePromptAndPreservesSynchronousWriteFastPath`: directly constructs Work, rejects an obsolete route nonce with zero output, and checks confirmed write synchronously sends the one original CC.
- `testDirectOwnerPreservesUserEditWhileSnapshotIsHeld`: directly constructs Work, holds a fake snapshot reply, changes the canonical value, and proves the stale read does not overwrite it or send feedback.
- `testDirectOwnerDrainsCancelledDisplayAndOldTaskCannotClearNewConnection`: holds a fake BCL read, replaces a cancelled connection task, compares actual task identities, proves zero premature sends, then releases the drain and checks the newer connection completes.
- `ConsolePresentationOwnerTests.testIndependentStateCoalescesOneFrameAndKeepsActualTaskIdentity`: directly constructs presentation state, coalesces a burst into the same handle, checks the exact frame boundary and follows the latest control/group.
- `testIndependentNoticeExactBoundaryStickyErrorsAndAction`: checks the six-second boundary and sticky error/action notices using injected time.
- `testIndependentPressAndActivityUseOriginalDurationBoundaries`: checks the original 80 ms minimum press and 120 ms activity boundaries using injected time.
- `testIndependentTransferTokensCanFinishInReverseOrder`: checks the real display transfer tokens without ViewModel/device construction.

G-6's Provider 1.0, hardware 1.4, GUI connection/reconnection and six synchronous reentrancy recordings remain fixed. G-2 captures compare byte-for-byte against the original raw G-6 recordings (including journal order and writer origin), while checked-in fixture hashes remain unchanged. The fixture JSON has repository formatting, so raw captures are compared to raw captures rather than to the formatted fixture file.

Local evidence is under `build/g/g2/`: `owner-tests.log`, `final-swift.log`, `golden-capture.log`, `golden-proof.json`, `workflow.log`, `clients-corrected.log`, `boundaries.log` and `commands.log`. No physical device is used. CI results and exact commits are recorded in the workspace handoff.
