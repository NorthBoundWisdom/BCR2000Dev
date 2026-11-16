# Console ownership after H-5

`ConsoleViewModel` keeps its existing API and synchronously forwards to `ConsoleDeviceWork`. Work composes the existing runtime and the owners below, forwards observations with weak Combine subscriptions, exposes computed projections and synchronous intent delegates, and dispatches each session event once. It has no device transaction state or retained device Task handle.

| Owner | Actual state and work |
| --- | --- |
| Existing `SurfaceSession`, `ProviderApplication`, `BCRPluginRuntime` | The only canonical surface values, provider/plugin state and runtime epoch/clock. |
| `ConsoleConnectionWork` | Endpoint selection/repair; MIDI initialization, offer and connection Tasks; prompts, declined route, startup nonce/route, observed hardware group and starting/connecting flags. |
| `ConsolePresetWork` | Display read Task/nonce, display profile/name/number evidence, pending number confirmation; alignment Task/nonce/route, dump, preview route/map/configuration, options and the one alignment phase. |
| `ConsoleRecoveryWork` | Restore Task/nonce/route and pending confirmation context; read-only preflight, explicit confirmation, write/readback and restore orchestration. Uses `ConsolePresetReadPort` for the existing read/evidence path; it does not implement another one. |
| `ConsoleRecoveryStore` | The existing bounded restore history, durable restore-point file, protected backups, digest/content validation and map archive directory. Preset and recovery share this store. |
| `ConsoleButtonFeedbackWork` | Agent LED semantic/level cache, blink preference and the one blink Task; the original Agent intents and the same Mock host/backend references. |
| `ConsolePresentationState` | Existing UI selection, notices, visible panels, display, press/activity/transient timers and coalesced frame. No device output authorization. |
| `ConsoleSurfaceIntents` | Mechanical surface/configuration/file-panel intents and the pre-existing migration markers, using the same session/files/presentation. No tasks, scheduler or second business value. |

`ConsoleDeviceContext` is immutable references, not a state owner. `ConsolePresetOperationGate` has only the existing BCL exclusivity ID/route: no Task, phase, business value, retry or timeout. Preset holds recovery weakly; recovery holds only the preset read port; connection uses task/read ports. Closures from preset/recovery back to connection and every observation/host callback are weak. No deinit behavior or automatic cancellation/output was added.

Connection takes the **actual** old display, alignment and restore handles. It cancels the old display read and awaits all three before reading or writing. When all three are nil, confirmed write remains synchronous and creates no Task. The facade's background-work list concatenates the actual owner handles and the existing presentation frame; blink, display hold and notice timers remain excluded. Old task completion checks its owning nonce before clearing its handle; the shared gate is cleared only for the same operation ID. Session changes invalidate preset, recovery and connection work synchronously before the same 16 ms frame scheduling. All clocks, sleeps, errors, permissions, transfer animation and send APIs remain the original ones.

## Complete method migration map

Names below refer to the pre-H-5 `ConsoleDeviceWork` methods; public facade methods retain their signatures and only delegate. No existing test was moved, renamed, removed or weakened.

| Destination | Original methods |
| --- | --- |
| `ConsoleConnectionWork` | `startMIDIWithoutBlockingWindow`, `applyEndpointSelection`, `commitEndpointSelection`, `selectSource`, `invalidateDisplayNumber`, `validateConnectionWork`, `offerHardwareConnection`, `requestSource`, `declineHardwareConnection`, `connectHardware` |
| `ConsolePresetWork` | `acceptDisplayNames`, `invalidateDisplayNumber`, `refreshDisplayFromDevice`, `rememberPresetNumber`, `resolveDisplayNumber`, `tryResolveDisplayNumber`, `updateDisplayProfile`, `syncRingModes`, `requestPresetNumberConfirmation`, `selectDisplayPresetNumber`, `confirmDisplayPresetNumber`, `cancelPresetNumberConfirmation`, `beginPresetWork`, `finishPresetWork`, `requirePresetRoute`, `presetNames`, `beginPresetAlignment`, `setAlignmentOptions`, `recomputeAlignment`, `installVerifiedMap`, `applyPresetAlignment`, `dismissPresetAlignment`, `validateConnectionWork`, `setDisplayPreset` |
| `ConsoleRecoveryWork` | `restorePresetBeforeAlignment`, `confirmPresetRestoreReplacingLearning`, `cancelPresetRestore`, `performPresetRestore`, `discardPresetRestore`, `revealPresetBackups`, `skipsFinderWhenOffscreen`, `validateConnectionWork` |
| `ConsoleRecoveryStore` | `restoreDump`, `matchesRestoreContext`, `saveRestorePoint`, `saveBackup` |
| `ConsoleButtonFeedbackWork` | `slot`, `applyAgentSlots`, `setBlinksAgentLEDs`, `showAgentState`, `refreshBlink`, `updateBlinkTimer`, `showSurfaceApprovalNotice`, `performPrimaryAction`, `performSurfaceAgentAction`, `start`, `interrupt`, `approve`, `decline`, `requireMockHost` |
| `ConsoleSurfaceIntents` | `selectGroup`, `turn`, `press`, `release`, `touch`, `setParameter`, `resetGroup`, `createParameter`, `updateParameter`, `removeParameter`, `loadPreset`, `setAssignment`, `setCycleValues`, `bulkAssignmentPlan`, `applyBulkAssignment`, `beginLearning`, `parameterFractionDigits`, `setMockNRPN`, `stopLearning`, `unbind`, `setHardwareButtonFunctions`, `resetHardwareMap`, `clearMonitor`, `clearNotice`, `saveMigration`, `clearPersistenceNotice`, `performNoticeAction`, `selectPage`, `updatePrograms`, `readConfiguration`, `installConfiguration`, `presentConfigurationPanel`, `chooseConfigurationImport`, `exportConfiguration`, `chooseConfigurationExport` |

The original `beginPresetWork`/`finishPresetWork` exclusivity logic is split into the thin shared gate and each owner's actual handle/nonce cleanup. The original `validateConnectionWork` cancellation checks follow each moved Task; the facade calls all three before publishing. Common `withDisplayTransfer`/`report` use the same presentation/session through `ConsoleDeviceOwner` defaults. `handlePresetAlignment` and its status projection move from the old Work extension into `ConsolePresetMCP`; Work has a synchronous delegate. `ConsoleButtonFeedbackWork+Agents` is the original Agent extension under its real owner. The remaining facade read projections (`displayValue`, `slot`, display content) read the same owners; `handleSessionEvent` remains the single event dispatcher. Presentation-only helpers keep forwarding to presentation.

## Tests and original golden recordings

The original seven G-2 methods in `ConsoleOwnerTests.swift` are byte-for-byte unchanged (SHA-256 `c5b8f47bce113f35f0af6556f7f4cbaef78de65343ea9f583d7c6228b46bbe9f`). Every prior test/assertion body and every golden fixture stays unchanged. `ConsoleDeviceComponentTests.swift` adds these eight methods, with no ViewModel, Work, MCP server or Provider construction:

- `testIndependentConnectionRejectsOldPromptAndKeepsWriteSynchronous`
- `testIndependentConnectionDrainsAllThreeActualTransactionHandles`
- `testIndependentConnectionAwaitsActualCancelledDisplayHandle`
- `testIndependentPresetCancelledOldReadCannotClearReplacementHandle`
- `testIndependentAlignmentOwnsTaskAndPersistsVerifiedRecoveryContext`
- `testIndependentRestoreRejectsChangedConfirmationContextWithoutWrites`
- `testIndependentRestoreRouteLossCancelsActualTaskAndRetainsRecoveryPoint`
- `testIndependentLEDClockKeepsActualTimerAndSteadyStateStopsTraffic`

These use a fake MIDI service, real SurfaceSession APIs and injected time. They cover direct owner construction, old prompt rejection, synchronous write, waiting for all three real transaction handles, cancellation/drain identity, old display nonce completion, alignment recovery evidence, changed restore context rejection, route-loss cancellation and exact LED timing/no steady traffic. The connection task ports additionally accept fake transaction handles so their drain behavior can be tested independently of the other owners.

H-5 evidence is under `build/h/h5/`: `before/full.log`, `before/python-full.log`, final native/Python/check logs, component logs and `after/capture.log`. The three `after/{provider,gui,reentrant}.json` raw recordings compare byte-for-byte with `before/original-{provider-before,gui-before,nested-e615}.json`; they also match the original G-6 raw captures. Formatting of checked-in fixture JSON is not substituted for raw-byte comparison. No physical device was used.
