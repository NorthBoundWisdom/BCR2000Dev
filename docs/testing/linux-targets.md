# Linux target audit

Historical B-8 audit before implementation, 2026-11-16, after B-7. macOS baseline: 773 tests, 0 failures, 1 existing attended-hardware skip.

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

Local environment audit: Apple Swift 6.4.2 / arm64 macOS. No Docker, Podman, Colima, Orb, Lima or installed Swift SDK. At that initial audit, Linux had not yet been run. The subsequent authorized hosted verification is recorded below.

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

Linux CI uses the same commands without the override, in `swift:6.2-noble`, in parallel with the unchanged native product checks. It caches the locked seed and SwiftPM outputs by platform/toolchain, preserves discovery/results, and uses a 20-minute hang guard and enforces the same 300-second whole-run budget for cold and warm caches. Actual Linux CI has since passed; see the exact-commit evidence below. There is still no local Linux container or SDK.

## Local native CI budget rehearsal

The full cached local macOS CI command sequence completed in **45.991 seconds** with all 18 commands successful. It included native tests, Python workflow tests, ad-hoc app build, three-language offscreen startup, MCP acceptance, provider packaging, display/catalogue checks, simulation transports, explicit Debug hardware doubles, display budgets, multiple displays and the synthetic status demo. No real MIDI ports or actuators were used. Logs and per-command times are in `build/align-b/ci-budget/summary.json` and numbered logs; stdout is `build/align-b/b8-ci-budget.log`.

This is a cached local measurement, not the prior hosted ~230-second baseline. This paragraph records the initial local rehearsal; the later hosted results below supersede its previously pending remote status.

## ALIGN2 CI bootstrap correction

Compilation (`swift build --build-tests`) is separate from both discovery and test execution in each job. A successful compile is cached immediately, even if subsequent tests fail. A restored build key (including a prefix restore) identifies a warm run; no matching key identifies cold bootstrap. The final, always-run budget step reads this exact run and attempt/jobs from the Actions API. It measures from the run's `created_at`, including queue/setup/cache time across jobs, and fails above 300 seconds for either cold or warm caches. Cache state is diagnostic only, with no performance exemption. The 20-minute deadline is only a hang guard. This is a live check: another job and post-job cleanup may still be running, so the supervisor also verifies the completed exact-SHA run's final `created_at` → `updated_at` wall time is at most 300 seconds. Per-step durations remain in the job summary.

A manual workflow dispatch can set `cold_build=true` solely to skip project-build cache restore for a controlled cold measurement. Compilation, all tests and result reconciliation still run. Successful builds are saved before discovery, so even a test-discovery crash cannot starve subsequent runs of a build cache. A normal dispatch at the same green SHA measures the warm path; failed runs are never rerun to hide defects. Cold measurements remain subject to the same whole-run 300-second limit.

User decision (2026-11-16): **no exemption; the entire CI run must finish within 300 seconds**, including cold-cache runs and queue/setup time. Any older ALIGN2 job-only/warm-only wording is superseded. Job wall time and cache state remain useful diagnostics, but neither may replace the whole-run limit. Both live gates measure from the run's `created_at`; the supervisor independently checks the completed exact-SHA run's `created_at` → `updated_at`, including post-job cleanup.

Independent Python/native suites run concurrently (bounded to three workers); real-clock transport acceptances run serially in the separate delivery job, with every subprocess outcome/log and duration retained. All six transport commands and both test commands remain; no check, test or assertion is removed. The execution-structure improvement is retained without its rejected warm-job/cold-exemption policy.

## Authorized hosted proof

At exact commit `9fc56ae57fe4883af3e0d883d71271cfea9ea0f3`, three consecutive independent warm-cache runs passed: 43827456219, 43827766866 and 43828101980. Their completed whole-run walls were 147, 142 and 135 seconds; macOS checks/delivery walls were 141/107, 137/104 and 130/111 seconds. All three jobs restored compiled caches. The 300-second whole-run rule applies equally to cold and warm runs; 240 seconds remains the macOS optimization target. These are measurements, not exemptions.

Linux actually discovered and reconciled **481 tests, zero failures and zero skips** on that SHA. This supersedes the historical 476-case local rehearsal above: three macro-result cases and two capture-interchange cases were added. Native macOS reconciled 788 tests with zero failures and one existing attended-hardware skip. Later commits can add cases; these counts are pinned evidence, not a fixed expected total.

The first hosted failures were corrected without skipping or relaxing assertions: static asynchronous XCTWaiter avoids transferring a non-Sendable XCTestCase; fixture construction uses a static factory compatible with corelibs; 199 actor-isolated synchronous test entry points in 41 files became async to avoid corelibs discovery casts; the localization waiter and MainActor clock box preserve the original assertions. Successful compilation now saves caches before discovery/tests, avoiding bootstrap starvation after a discovery failure.

The Python workflow suite's remote 45-second time was traced to a loopback HTTP fixture's reverse DNS: one case took 36.028 seconds. Binding that literal-loopback fixture without getfqdn reduced it to 0.618 seconds and all per-case times to 10.595 seconds, retaining every request and credential-redaction assertion.
