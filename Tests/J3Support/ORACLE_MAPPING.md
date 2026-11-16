# J3 legacy oracle mapping

The reference is the committed BCR native implementation
`36692f1422b0c3952f9048847a0bafd65421bc72`, after the separately reviewed connection-publication safety fix.
The production implementation now uses Kit `545ba46c3cb5298663c3dd12e53604a5a68da7a0`.

| Original reference method | Production replacement | Tests-only original algorithm |
| --- | --- | --- |
| `SurfaceConfiguration.swift:464 assignment(for:)` | Cached `BindingContext.targetForControl`, resolving the sole native assignment payload by offset | `verify_runtime_shadow.py` `binding.lookup` branch: first equal control in the actual ordered input; `SurfaceKernelBindingCacheTests.check` independently uses the original firstIndex |
| `SurfaceSession.swift:1306 handleConnection` route/status/generation facts | `BCRConnectionRuntime.begin` delegates to Kit `ConnectionState.apply`; its generation is the public getter's sole owner | `connection.init/transition/publish` branches: original IDs, transport generation, selected names and optional selected provenance, status and generation rule; independently retained published snapshot and generation |
| `SurfaceSession.swift:86 authorizeParameterWrite`, `:661 checkParameterAuthority`, `:822 setHardwareDisplayFeedback`, `:1230 transmitNow`, `:462 flushFeedback` shared scope predicates | `ContextScope.matches` on actual source/input epoch/binding revision/optional endpoint; the scheduler generation condition stays at its original host boundary | `scope.*` branch: original exact source/epoch/mapping/endpoint and optional queue-generation rule |
| `FeedbackScheduler.swift:121 enqueue`, `:136 cancel`, `:141 drain`, `:157 clear` ordered resource identity | Kit `ContextResourceIndex` is the only order/scope owner and drives count, pendingItems and removal; the native `order` array is deleted | `index.*` branches: independently maintained original ordered IDs/scope from initialization and actual operations; no result IDs seed the oracle |

The original BCR payload dictionary, token bucket/refill/cooldown, MIDI encoding, input interpretation, final native
endpoint/mapping send gates, display receipts/canonical completion, echo policy and management transactions stay native.
The full adapter connection snapshot remains for device metadata; the public connection generation comes from Kit.
Temporary reduction preserves early generation and later snapshot publication, with the 366 notification/semantic
revision guards. Neither a previous whole session nor a previous reducer candidate is assigned across callbacks.

Production Debug contains only the default-off `SurfaceKernelTrace` input/actual-result tap. It emits no pretend
native/candidate comparison and contains no original lookup/route/scope/order algorithm. The strict generic mismatch
self-check moved to `Tests/BCRAgentCoreTests/SurfaceKernelAudit.swift`; actual production results are compared by the
independent Python oracle after the complete native suite. `macos_workflow.py test` makes that proof mandatory for the
real Kit manifest, including CI. Missing tap/oracle, reused or empty evidence, missing core operation families, unknown
operations, incomplete sequence or any actual-result difference fails the command. The original suite deadline is
not increased. Generic native-runner fixtures without this runtime retain their original behavior.

`test_j3_legacy_verification.py` uses actual-only records and corrupts route facts/generation, lookup result, scope,
ordered IDs and an optional identity. Inputs remain unchanged during negative mutation; each corruption must fail the
real Tests-only oracle. It also verifies the mandatory workflow gate and default-off environment restoration. The
original Swift self-check children separately prove strict mismatch termination; they are deliberately failing records
under `expected-negative/`, excluded from the ordinary actual-result inventory.
