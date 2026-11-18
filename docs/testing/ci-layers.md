# CI coverage after O-2 retirement

Baseline `acf86040f61665f3446e0f226ac9d88fcbcdbc93`: normal run `44218823842` succeeded in **281 seconds**. Retirement commit `a2558a121b797f05c74ea91958198bb106c114ef`: normal run `44223143648` took **340 seconds**, failing the whole-run budget after all functional steps succeeded. Its independent complete-proof run `44223143693` succeeded in **385 seconds**. These times run from creation to completion and include queue time.

On that retirement commit, the native checks job spent 129.988 seconds compiling, 94.619 seconds on regressions and fixed representative verification, and 30.194 seconds on concurrent Python workflows. The complete proof on arm64 compiled the native targets and tests in 87 seconds as measured by the workflow step. The regular `checks` job now uses `macos-26` (arm64), with matching arm64 SwiftPM and audit-helper cache keys. `delivery` stays on `macos-26-intel` and the complete proof stays on `macos-26`. Commands, test scope, acceptance thresholds, and time budgets are unchanged.

## Removal and unique-coverage review

Only completed J2/J3/J4 migration machinery is retired. All J-before product tests, scenario executors, three G-6 golden samples, product regressions and safety tests remain. The six removed wrong-result children (capture, dispatch, authorization, preflight, receipt, summary) mutated a Tests-only comparator result copy. They checked that comparator detects a mismatch, not that a production safety gate rejects an unsafe operation; existing production tests in FeedbackCorePrimaryTests, DisplayTransactionReentrancyTests, FeedbackScopeTests, FeedbackSchedulerTests and the unchanged golden paths remain.

Rows count physical lines removed/added (including comments and whitespace), not algorithmic savings. Mixed files retain the behavior tests listed below.

| File / test group | Removed / added lines | What it proved; coverage disposition |
| --- | ---: | --- |
| `.github/workflows/full-proof.yml` | 1 / 1 | Rename step to accurately describe remaining scheduler proof; triggers, deadline, command and artifacts unchanged. |
| `Sources/BCRSurfaceDomain/FeedbackScheduler.swift` | 23 / 0 | Remove already accepted J3 FIFO-index observation only; keep complete scheduler candidate input/output for O4. |
| `Sources/BCRSurfaceDomain/SurfaceConfiguration.swift` | 78 / 0 | Remove J3 diagnostic memo and tap; keep actual binding lookup, cache invalidation and value semantics. |
| `Sources/BCRSurfaceDomain/SurfaceKernelTrace.swift` | 99 / 0 | J3 input/result recorder only; no decision or product gate. |
| `Sources/BCRSurfaceDomain/SurfaceSession.swift` | 89 / 0 | Remove J3 scope/connection observation only; keep actual Core calls and every transport safety branch. |
| `Tests/BCRAgentCoreTests/SurfaceKernelAudit.swift` | 88 / 0 | Tests-only new/old mismatch recorder and trap, not a product safety test. |
| `Tests/BCRAgentCoreTests/SurfaceKernelBindingCacheTests.swift` | 48 / 0 | Remove two tests only for retired diagnostic memo/Observation side effects; keep all six other tests, including product cache/value isolation and empty lookup observation. |
| `Tests/BCRAgentCoreTests/SurfaceKernelShadowTests.swift` | 51 / 0 | Remove one comparator corruption self-test; keep both unique first-match and FIFO/optional-scope product tests unchanged. |
| `Tests/BuildWorkflowTests/test_feedback_native_oracle.py` | 141 / 0 | J4 retired feedback leaf oracle self-tests only; native product feedback tests remain. |
| `Tests/BuildWorkflowTests/test_j3_legacy_verification.py` | 258 / 0 | J3 archive integrity/oracle corruption self-tests only; no product execution. |
| `Tests/BuildWorkflowTests/test_j4_shadow_verification.py` | 55 / 1 | Remove two retired plan-comparator self-tests and comparator-only assertions; retain mixed JSON corruption admission checks and scheduler fixture paths; keep all scheduler schema, causal and fail-closed tests. |
| `Tests/J3Support/ORACLE_MAPPING.md` | 32 / 0 | Provenance map for removed J3 comparator, not a product specification. |
| `Tests/J3Support/verify_runtime_shadow.py` | 211 / 0 | Frozen J3 ordered-first-match/scope/connection/index oracle; product behavior covered directly by native binding, scope, connection, FIFO tests. |
| `Tests/J4Support/MigrationTools/J4ASTMigrationVerificationTests.swift.txt` | 138 / 0 | Offline whole-codec bytes migration export/probe, completed and signed; no product regression or safety coverage. |
| `Tests/J4Support/MigrationTools/J4AnyMigrationExportTests.swift.txt` | 88 / 0 | Offline whole-codec bytes migration export/probe, completed and signed; no product regression or safety coverage. |
| `Tests/J4Support/MigrationTools/J4FoundationPayloadProbeTests.swift.txt` | 266 / 0 | Offline whole-codec bytes migration export/probe, completed and signed; no product regression or safety coverage. |
| `Tests/J4Support/MigrationTools/J4OldCodecMigrationExportTests.swift.txt` | 88 / 0 | Offline whole-codec bytes migration export/probe, completed and signed; no product regression or safety coverage. |
| `Tests/J4Support/MigrationTools/README.md` | 19 / 0 | Offline whole-codec bytes migration export/probe, completed and signed; no product regression or safety coverage. |
| `Tests/J4Support/ORACLE_MAPPING.md` | 39 / 9 | Replace completed feedback-leaf map with remaining temporary scheduler baseline rationale. |
| `Tests/J4Support/verify_feedback_runtime.py` | 392 / 0 | J4 old feedback leaf oracle only; runtime feedback product and safety tests remain. |
| `configs/ci_native_layers.py` | 7 / 4 | Remove J3 capture/verify; all-regression discovery and exact seven-case scheduler representative capture remain. |
| `configs/freecm.commands.jsonc` | 2 / 0 | Remove deleted J3 proof inputs from Config manifest; product commands unchanged. |
| `configs/j3_legacy_verification.py` | 80 / 0 | Capture/verify orchestration only for removed J3 oracle. |
| `configs/j4_shadow_verification.py` | 232 / 3 | Remove only feedback leaf comparison, validate_plans and six wrong-result children; retain full scheduler current/cold plus strict source/causal/output checks. |
| `configs/macos_workflow.py` | 6 / 2 | Remove J3 post-suite capture/verify; full native suites and temporary scheduler proof remain mandatory. |

| `Sources/BCRSurfaceDomain/SurfaceKernelProjection.swift` | 52 / 2 | Remove six unused J3 JSON-only projections. Keep controlValue because the temporary O4 scheduler I/O archive still calls it; production typed projections remain. |
| `Sources/BCRFoundation/Localization.swift` | 21 / 0 | Remove only DEBUG diagnostic language revision/snapshot used by the retired J3 memo; keep language locking, observation and localization product behavior unchanged. |

Native XCTest declarations decrease by **3** (one mismatch-comparator self-test and two retired diagnostic-memo self-tests). Python test declarations decrease by **13**, entirely retired proof/oracle self-tests; no product test is converted into a skip or weakened. Two direct product methods remain unchanged in `SurfaceKernelShadowTests` despite the historical class name.

## Remaining temporary scheduler proof

`J4SchedulerArchiveReplayTests`, `J4SessionSchedulerArchiveReplayTests`, `J4ExactJSON`, `J4PayloadCodec`, `J4LosslessCatalog`, their corruption tests, `expand_catalog.py`, native3b text provenance, `FeedbackJ4Trace` and the associated Session inputs remain because the **scheduler has not switched**. They supply complete input-only current/cold runs, strict source/namespace/causal checks and separate output comparisons required by O4. They must retire in the same round after both schedulers are accepted. Feedback projections retained by this archive preserve its exact input/output format; they are not a second production owner.

`.github/workflows/full-proof.yml` therefore remains (manual, nightly, relevant paths; 30-minute limit). Its original full native suite and scheduler archive execution are mandatory on the exact source SHA. Normal CI retains all native regressions and the same seven fixed representatives, including all applicable scenarios, original G6 methods, FIFO replacement and failure cooldown. Capture and offline scheduler verification remain separate from the uninstrumented full suite; errors from either fail the job.

## Historical CI classification

The pre-retirement F-1 classification and all older measurements remain below as historical evidence. Its references to removed J3/J4 leaf proof are superseded by the removal map above.

# CI 分层（F-1，监督已批准分类）

基线：`297dbc1f3c0085ad508a145f5f1f39622e764f53`，失败 run `44116922210`，created→updated **658 秒**。只改执行入口、过滤和缓存配置；所有产品源码、诊断源码、锁、断言与阈值保留。

## 分类与去向

| 原检查或组 | 原 run 实际耗时（秒） | 分类及新去向 |
| --- | ---: | --- |
| Linux 全部 574 XCTest，含 J 轮产品行为回归 | 77.001（case suite）；步骤 79 | 回归；每次推送原入口与精确发现核对不变 |
| macOS 全部 912 XCTest（911 通过、1 个原实机 skip） | 86.632503（body wall）；191.728（case 时间之和） | 回归；每次推送全部跑，不启用整套 DEBUG trace 采集；全部模块与逐 case 核对保留 |
| Python 全部 246 workflow tests | 38.494（独立进程 wall） | 回归；每次推送完整保留；J3/J4 证明工具自身的损坏输入/负控 tests 也保留 |
| J3 每次操作独立 366 oracle（原 run 276870 次，零差） | 原 run 没有独立 stage 计时；包含于 native-suites 447.359 | 完整证明；full-proof 原 capture/verify，不改 oracle |
| J4 全套 native3b feedback 61796 算法行、17501 观测行 | 原 run 没有独立 stage 计时；包含于 native-suites 447.359 | 完整证明；full-proof 原 capture/verify 与全部 strict 比较、6 负控原样保留 |
| J4 bucket 输入独立 replay（727 操作） | 原 run 没有独立 stage 计时；包含于 native-suites 447.359 | 完整证明；full-proof 原样保留 |
| J4 全部 Session current+cold 独立 replay（10 进程、27050 步、2609 既有策略差） | 最大 worker 294.142732；pool 无单独 wall 计时，不把它冒充总阶段时间 | 完整证明；full-proof 原样保留，不改变已裁定差异 |
| 原生套件外层（以上 body/J3/J4 合计） | 447.359 | 每次推送改为全部回归＋固定代表证明；full-proof 保留原全量入口 |
| 旧档案/旧 codec 全 bytes 迁移证明 | 不在该 CI run 的默认入口；此前离线证明已签收 | 工具/断言完整保留；不得假称本 run 曾执行。不恢复已删大档案或重做旧签收 |
| 场景库全部适用场景（30 场景的原判定） | 包含于原 912 body；个别原 case 时间见下面的原日志表 | 每次推送既在完整回归中跑，又进入固定代表 trace 采集 |
| G-6 原三黄金样本（GUI、Provider、重入） | 包含于原 912 body；原 case 时间见下面 | 每次推送保持原黄金断言，固定代表采集再次执行原三样本 |

## 原 workflow 每一执行步骤的实际耗时

以下为 GitHub 原 job 日志/API 的 started→completed，精度一秒；不拿它估计子阶段。所有未单列“完整证明”的检查均归回归，保留在每次推送。checkout/cache/upload 等是基础设施。

| Job | 原步骤 | 秒 |
| --- | --- | ---: |
| delivery | Run actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 | 5 |
| delivery | Run actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 | 1 |
| delivery | Run python3 configs/restore_git_mtimes.py | 0 |
| delivery | Identify the Swift toolchain for the build cache | 4 |
| delivery | Cache the locked SurfacePlugins checkout | 1 |
| delivery | Restore the latest SwiftPM build | 4 |
| delivery | Run python3 configs/surface_plugins_dependency.py ensure | 1 |
| delivery | Run python3 configs/control_surface_kit_dependency.py ensure | 0 |
| delivery | Compile provider and offline profile products | 41 |
| delivery | Save compiled delivery products before acceptance | 7 |
| delivery | Validate delivery boundaries before running products | 2 |
| delivery | Package the independently compiled provider products | 1 |
| delivery | Run python3 build/ci-surface-provider/diagnostics/display_targets.py --directory build/ci-surface-provider --check | 0 |
| delivery | Confirm delivery preparation products exited | 0 |
| delivery | Serial real-clock transport acceptance | 19 |
| delivery | Isolated display budget latency and cadence acceptance | 1 |
| delivery | Isolated real-time synthetic status demo acceptance | 53 |
| delivery | Preserve delivery acceptance and timing evidence | 2 |
| delivery | Report whole-run wall time and enforce 300s budget | 1 |
| core-linux | Initialize containers | 41 |
| core-linux | Run actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 | 2 |
| core-linux | Run git config --global --add safe.directory "$GITHUB_WORKSPACE" | 0 |
| core-linux | Run actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 | 0 |
| core-linux | Run swift --version | 0 |
| core-linux | Run python3 configs/restore_git_mtimes.py | 1 |
| core-linux | Identify the Swift toolchain for the build cache | 0 |
| core-linux | Cache the locked dependency | 1 |
| core-linux | Restore the latest portable SwiftPM build | 3 |
| core-linux | Run python3 configs/surface_plugins_dependency.py ensure | 0 |
| core-linux | Run python3 configs/control_surface_kit_dependency.py ensure | 0 |
| core-linux | Run python3 configs/check_portable_targets.py | 1 |
| core-linux | Run python3 configs/check_domain_boundaries.py | 1 |
| core-linux | Compile portable targets and tests | 25 |
| core-linux | Save compiled portable cache even if later tests fail | 8 |
| core-linux | Run and reconcile every portable XCTest once | 79 |
| core-linux | Preserve portable discovery and results | 2 |
| core-linux | Report whole-run wall time and enforce 300s budget | 1 |
| checks | Run actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 | 3 |
| checks | Run actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 | 1 |
| checks | Run python3 configs/restore_git_mtimes.py | 0 |
| checks | Identify the Swift toolchain for the build cache | 5 |
| checks | Cache the locked SurfacePlugins checkout | 1 |
| checks | Restore the latest SwiftPM build | 4 |
| checks | Run python3 configs/surface_plugins_dependency.py ensure | 1 |
| checks | Run python3 configs/control_surface_kit_dependency.py ensure | 0 |
| checks | Restore the matching audit helper binaries | 1 |
| checks | Compile native targets, tests and original audit helpers concurrently | 116 |
| checks | Save compiled native cache even if later tests fail | 6 |
| checks | Save original audit helpers before any GUI runs | 1 |
| checks | Validate boundaries using the same compiled manifest scratch | 8 |
| checks | Run python3 configs/validate_repo_commands.py . | 0 |
| checks | Run python3 configs/display_budget_report.py --evidence docs/status-panel-budget-evidence.json --output docs/STATUS_PANEL_BUDGET.md --check | 0 |
| checks | Run python3 configs/check_accessibility.py | 1 |
| checks | Run python3 -m compileall -q configs | 0 |
| checks | Run all Python workflows and precompiled native suites independently | 448 |
| checks | Run python3 configs/macos_workflow.py build --distribution ad-hoc | 10 |
| checks | Run python3 configs/macos_workflow.py smoke | 8 |
| checks | Run python3 tools/mcp_integration.py | 5 |
| checks | Run git diff --check | 1 |
| checks | Confirm native and isolated MCP products exited | 0 |
| checks | Preserve test and MCP acceptance logs | 22 |
| checks | Report whole-run wall time and enforce 300s budget | 2 |

## 固定代表证明（每次推送）

不从全量回归中排除任何测试。单独的固定 proof 进程只选：全部适用场景的执行器两条原方法、原三 G6 方法、两条已有的调度取消与失败冷却方法（重入正控与六负控仍由原 J4 verify 自动执行）。每次都从这些固定测试实际采集 trace，调用原 J3/J4 证明入口，对整段已录制会话跑 current+cold；不从全套 trace 动态抽样、不截断操作、不改变断言。固定 7 方法分别是：`ControllerRegressionExecutorTests` 的两条场景执行方法，`GUIFeedbackPathGoldenTests`、`FeedbackPathGoldenTests`、`FeedbackReentrancyGoldenTests` 各一条原黄金方法，`SurfaceKernelShadowTests.testIndexRetainsFullOptionalScopeWhenSameIDIsReplacedWithoutReordering`，`FeedbackSchedulerTests.testErrorCooldownClockRollbackAndClearPreventReplay`。后两条补齐原 bucket replay 强制核验的 cancel/failure，不放宽缺操作门。固定集合逐方法列于 `configs/ci_native_layers.py:REPRESENTATIVE_CASES`（共 7 条）；路径变化触发 full-proof。完整原生回归也会再次执行这 7 条，它们没有被从回归清单移走。

## 完整证明 workflow

新增 `.github/workflows/full-proof.yml`：workflow_dispatch、每日 schedule、锁/内核适配/反馈/调度及证明代码与入口相关路径 push/PR 触发。macOS 原完整 `configs/macos_workflow.py test --precompiled-tests`，30 分钟 job 时限，测试原 900 秒期限不变。它在同一 SHA 成功才可切换或交付。所有原 full-proof capture、oracle、current+cold、negative control 保持原代码和断言。workflow 为每个原始 JSONL 留路径、记录数、字节数和 SHA-256 索引；成功后删除大于 100 MB 的单个 raw trace，上传日志/summary/hash 而不上传 raw JSONL。失败时也留索引，不删除原文件。

## 缓存重复编译

原 run 恢复 f6b 的 native SwiftPM cache，但 compile/native.log 再编译 SP、Kit 和大量未改宿主文件；command wall 116.070 秒，Swift 自报 99.30 秒。与 f6b 的 48.890 秒差 67.180 秒；不伪造逐文件 CPU。当前 seed key 只有两锁且跨 Linux/macOS 共用；seed 由多 job 首个保存者决定，其 checkout mtime 不与某一 SwiftPM 缓存绑定，只有宿主文件运行了 git mtime 恢复。在原两 ensure/身份检查后，对已验证 full-pin 的浅受管依赖，仅在 CI 将全部干净 tracked files 设为该 HEAD 的提交时间，避免重新采源造成时间漂移；seed key 加 OS/arch 隔离，三个 SwiftPM cache 命名空间也加两锁 hash，避免不同 pin 同提交时间误用；保留 full SHA/dirty/origin 验证。只在配置入口实现，不改依赖管理产品语义或源码。新 run 记录 cache 命中、编译日志与实际耗时；未获云端证据前不宣称已解决。

## 原 case 时间（原 run 日志）

| 原 case | 秒 |
| --- | ---: |
| `BCRAgentConsoleTests.GUIFeedbackPathGoldenTests/testRecordedGUIConfirmedConnectAndReconnectSequence` | 0.066 |
| `BCRAgentConsoleTests.ControllerRegressionExecutorTests/testExecutesThirtySharedScenariosAndValidatesReportSeparatelyFromConformance` | 2.509 |
| `BCRAgentConsoleTests.ControllerRegressionExecutorTests/testIndependentNativeAndTypedOwnersMatchEveryApplicableScenarioStep` | 7.152 |
| `BCRAgentConsoleTests.ControllerRegressionExecutorTests/testRouteReplacementRevokesOldHardwareItemsDespiteSameBytesFromMock` | 0.119 |
| `BCRAgentConsoleTests.ControllerRegressionExecutorTests/testSuccessfulWriteDecisionSurvivesFullBoundedJournal` | 13.397 |
| `BCRProviderAdapterTests.FeedbackReentrancyGoldenTests/testSynchronousReentrancyPreservesPendingAndCompleteOldOutputOrder` | 0.078 |
| `BCRProviderAdapterTests.FeedbackPathGoldenTests/testRecordedProviderAndHardwareDisplaySequences` | 0.070 |

原件索引：工作区 `build/j-finish/b/f1/failed-run.json`、`failed-run.log`；此前同 run 选取且校 CRC 的原 artifact 小日志在 `build/j-main-cont/b/j4-ci-isolation/ci-297-selected/`，只读引用，不重跑。

## F-1 首次分层提交的实际结果

`d0c67195f95d86775e51b24e4bbdba6045cffcce` 的正常 run `44136715224` 为 failure，
created `2026-11-17T17:24:54Z` → updated `17:39:55Z`，整套 **901 秒**。
Linux 成功；macOS checks 的全部功能步骤成功，只有整套 300 秒预算失败。
delivery 没取得 hosted runner，steps 为空而被取消；GitHub 原注释是
“The job was not acquired by Runner of type hosted even after multiple attempts”，并提示 macOS arm64 容量限制。
它没有执行交付验收，不能称该 job 功能通过。

新命名空间首次 seed/SwiftPM 都明确 cache miss；native 编译命令 135.953 秒、
全部回归加固定代表证明 84.450 秒、Python 38.782 秒（与原生并行）。
这次是冷编译，不能据它证明后续 incremental cache 的实际收益。
独立自动 proof run `44136715097` 也因未取得 hosted runner 被取消，未执行原完整证明。
按本轮规则，不继续性能优化循环；F-2 切换和 F-5 交付不放行。
同 SHA 另行手动触发的证明及后续提交的精确终态记录在工作区 `reports/B.md`，不以新 run 回填上述失败。

## 逐推送 macOS runner

常规 `checks` 和 `delivery` 使用 `macos-26-intel` 的独立虚拟机。上轮 `2e9693b` 的两项逐推送作业均未取得 arm64 runner，GitHub 容量注释见 run `44143231642`。Intel 的编译缓存、桌面辅助程序缓存与 arm64 分开。独立完整证明继续使用 arm64，发布 workflow 沿用现有架构矩阵。普通 CI 以实际完成的整套运行核对 300 秒，包含排队与冷编译。

Intel 冷构建 run `44215075337` 的原生编译用时 199 秒，未启用全量 trace 的回归用时 53 秒，七项固定比对的采集和验证合计 88 秒。固定样本先独立完成采集，之后离线验证与原生回归并行。两个阶段各自保留测试清单、退出状态与证据，检查任一失败会使常规 CI 失败。完整证明仍按原入口运行。
