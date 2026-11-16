# Linux target audit

B-8 audit before implementation, 2026-11-16, after B-7. macOS baseline: 773 tests, 0 failures, 1 existing attended-hardware skip.

| Target | Platform dependency found | Real dependency or convenience | Plan |
| --- | --- | --- | --- |
| BCRFoundation | Foundation, Observation | Portable value/localization contracts | Linux + macOS |
| BCRSurfaceDomain | Foundation | Portable state/MIDI values, history/scenes/coverage/replay | Linux + macOS |
| BCRPluginRuntime | Foundation + shared contracts | Portable registry/clock | Linux + macOS |
| BCRPluginHost | Foundation + shared Agent adapter | Portable adapter | Linux + macOS |
| BCRExamples | Foundation + ExampleParameterSets | Portable data | Linux + macOS |
| BCRConfigurationAdapter | CryptoKit in HardwareRoleCandidate | SHA-256 convenience | Use BCRFoundation.ContentDigest |
| BCRPersistenceAdapter | CryptoKit in ProtectedJSONFile; Darwin/Glibc guarded evidence files | SHA-256 convenience; portable POSIX file protection | Use ContentDigest, preserve file protections |
| BCRMCPAdapter | Foundation + shared contracts | Portable routing/schema logic | Linux + macOS |
| BCRProviderApplication | Foundation + shared plugins | Portable explicit composition | Linux + macOS |
| BCRProviderMCPAdapter | CoreFoundation; Darwin POSIX file calls in principals | Portable Foundation/owned-file semantics | Guard Darwin/Glibc imports; preserve wire contracts |
| BCRCodexAdapter | Foundation Process/Pipe; Darwin kill/SIGKILL | Portable POSIX process operation, no Apple framework | Guard Darwin/Glibc imports; retain mock-process tests |
| BCRProfileTool | Foundation + configuration adapter | Portable offline CLI | Linux + macOS |
| BCRCoreMIDIDriver | CoreMIDI, OSStatus and native endpoints | True Apple driver dependency; pure byte values already in SurfaceDomain | macOS only |
| BCRHTTPTransport | Network.framework | True current Apple networking implementation | macOS only |
| BCRAgentConsole | SwiftUI/AppKit/Combine/Security/Network/CoreMIDI | True GUI/native adapter composition | macOS only |
| BCRProviderService | CoreMIDI/Network/Darwin host composition | True current native host composition | macOS only |
| BCRTestSupport | RecordingMIDIService imports CoreMIDI driver | Only one native helper; other three files portable | Omit that helper only in portable slice |

No new target is needed. Keep original test-target names and macOS coverage; only the GUI test target and one real CoreMIDI qualification method are native-only. Core tests contain unused imports of HTTP/CoreMIDI that can be removed without deleting test bodies.

Local environment audit: Apple Swift 6.4.2 / arm64 macOS. No Docker, Podman, Colima, Orb, Lima or installed Swift SDK. **未在 Linux 上验证**. CI will run the actual Linux slice in swift:6.2-noble; it cannot be checked remotely before an authorized push.

## Implemented slices and local proof

`Package.swift` removes only the native hosts/driver/Network transport/GUI tests for Linux. `BCR_PORTABLE_BUILD=1` selects that same graph on macOS for a local portability rehearsal; it does not claim Linux execution. Native test-target names are retained. Only the existing real CoreMIDI qualification method is guarded to macOS; its body and opt-in/skip policy are unchanged there. RecordingMIDIService is the sole excluded helper. All other test IDs remain available on both slices.

CryptoKit hashing in the two portable adapters now uses the already tested portable ContentDigest. POSIX imports use Darwin/Glibc guards; Python fixtures resolve python3 through `/usr/bin/env`, so CI's configured interpreter is used. The offline profile CLI explicitly imports the appropriate POSIX module. Apple-only compositions stay Apple-only.

| Test target | B-8 start | Final native macOS | Portable slice on macOS |
| --- | ---: | ---: | ---: |
| BCRAgentConsoleTests | 296 | 297 | 0 |
| BCRAgentCoreTests | 347 | 347 | 347 |
| BCRPluginHostTests | 12 | 12 | 12 |
| BCRProviderAdapterTests | 80 | 80 | 79 |
| BCRProviderDomainTests | 38 | 38 | 38 |
| Total | 773 | 774 | 476 |

The one added macOS case checks active-output metadata neutrality (B-3/B-4 follow-up); no original case ID was removed. The native-only remainder is 297 GUI cases plus one attended CoreMIDI case. The portable rehearsal ran all 476 cases with 0 failures/0 skipped; native macOS ran all 774 with 0 failures/1 existing skip. These numbers come from actual discovery and result reconciliation, saved in `build/align-b/b8-inventory-proof.json`.

`check_portable_targets.py` verifies the complete 17-target graph and absence of native dependencies. `verify_portable_tests.py` matches every discovered XCTest to exactly one start and completion on both Darwin and corelibs log formats; missing, duplicate, extra, failed or skipped portable cases fail. This avoids treating Swift Testing's separate zero-test trailer as the XCTest result.

Trace audit: BCR's byte-for-byte BehaviorTrace assertion uses JSONEncoder, while the cited X-Touch issue used JSONSerialization. Existing byte assertions and fixture bytes remain unchanged; other JSONSerialization-based fixture checks already compare parsed values. No whitespace-specific assertion was weakened.

## Commands and CI

```bash
python3 configs/surface_plugins_dependency.py ensure
python3 configs/check_portable_targets.py
BCR_PORTABLE_BUILD=1 python3 configs/check_domain_boundaries.py
BCR_PORTABLE_BUILD=1 swift test --build-path build/swiftpm-portable list > build/portable-inventory.txt
BCR_PORTABLE_BUILD=1 swift test --build-path build/swiftpm-portable --skip-build > build/portable-tests.log 2>&1
python3 configs/verify_portable_tests.py --inventory build/portable-inventory.txt --log build/portable-tests.log
```

Linux CI uses the same commands without the override, in `swift:6.2-noble`, in parallel with the unchanged native product checks. It caches the locked seed and SwiftPM outputs by platform/toolchain, preserves discovery/results, and sets a five-minute budget for each parallel job. Actual hosted wall time and Linux Foundation/runtime behavior remain to be verified after an authorized push. **未在 Linux 上验证**; there is no local container or Linux SDK.

## Local native CI budget rehearsal

The full cached local macOS CI command sequence completed in **45.991 seconds** with all 18 commands successful. It included native tests, Python workflow tests, ad-hoc app build, three-language offscreen startup, MCP acceptance, provider packaging, display/catalogue checks, simulation transports, explicit Debug hardware doubles, display budgets, multiple displays and the synthetic status demo. No real MIDI ports or actuators were used. Logs and per-command times are in `build/align-b/ci-budget/summary.json` and numbered logs; stdout is `build/align-b/b8-ci-budget.log`.

This is a cached local measurement, not the prior hosted ~230-second baseline. Hosted cold/cache-restored timing and the actual Linux job remain pending an authorized push; no remote success is claimed.
