# G-8 one native execution path

The production workflow now has one implementation: `configs.xctest_runner.run`.
The former `_run_case_tests` function and its per-case SwiftPM execution are removed.
`BCR_TEST_EXECUTION=batch` and the unset default retain the same behavior. The retired
`case` selector and unknown selectors fail explicitly rather than silently selecting a fallback.
Remote tools, schemas, errors, protocols and output timing are unaffected.

## Coverage before deleting the old path

All currently discovered BCR cases are native XCTest cases. The batch path already handles
both per-module bundles and the older aggregate package bundle; discovers the complete native
inventory; requires exactly one started and completed record per case; preserves native failures
even if the host exits zero; rejects missing, duplicate, extra or crashed results; preserves skips;
and kills its owned process groups (including fixture descendants) at suite timeout and cleanup.
The original 15-minute suite watchdog, worker setting and module-summary verification remain.
The existing independent xUnit summarizer still checks additional report files, including its
Swift Testing sidecar fixture. BCR currently has no such native discovery entries; a future
unsupported inventory format fails explicitly instead of dropping cases.

## Exact migrated test purposes

The four `XunitSummaryTests` are unchanged. The five former per-case workflow tests now execute
the same real native-process fixture as the batch path. No functional purpose was removed:

| Old test | Current test / retained evidence |
| --- | --- |
| `ParallelRunnerTests.test_runner_invokes_one_parallel_swift_test_with_an_xunit_report` | `test_runner_uses_one_discovery_and_bounded_native_batches_with_xunit`: exactly one discovery, requested workers=3, complete case inventory, bounded batch count, one actual native invocation per planned batch, original total summary and persisted log |
| `test_failure_nonzero_exit_missing_report_and_missing_module_fail_the_run` | `test_failure_nonzero_exit_missing_native_results_and_missing_module_fail_the_run`: native assertion failure, exit7, missing native completion (instead of an absent SwiftPM-generated xUnit), and missing module each fatal; independent missing/unreadable xUnit tests unchanged |
| `test_required_module_missing_from_the_manifest_is_fatal` | Same name and required-module assertion unchanged |
| `test_a_hung_test_is_killed_and_named_among_the_last_started` | `test_a_hung_native_batch_is_killed_and_missing_case_is_named`: same 1-second fixture deadline, run fails, missing case is named in xUnit integrity error and batch log; owned-group/descendant cleanup also remains covered by NativeExecutionTests |
| `test_invalid_worker_override_is_rejected` | Same name and positive-worker constraint unchanged |

`NativeInventoryTests.test_default_backend_uses_native_batches_and_preserves_module_summary`
still verifies the actual native invocation arguments, manifest modules, requested worker count
and summary. Its old assertion that the legacy function was not called is now the stronger
assertion that the removed function does not exist. The old explicit-case-selection test becomes
`test_removed_case_backend_and_invalid_modes_fail`, preserving the invalid-selector rejection
and checking the intentional G8 retirement. Native process/accounting tests are otherwise unchanged.

The private `fake_test_runner.py` is now only a discovery/build-location fixture; it does not run
cases or generate reports. Case execution always uses `fake_native_xctest.py` and the production
native batch runner. The fixture can hang a selected case to retain the original diagnostic test;
this is deliberate timeout evidence, not a normal test delay.

SurfacePlugins and XTouch are assessment-only in G8. Their suites contain Swift Testing cases,
so this XCTest-only batch parser cannot replace their runners without additional support and
coverage. No forced migration was made.
