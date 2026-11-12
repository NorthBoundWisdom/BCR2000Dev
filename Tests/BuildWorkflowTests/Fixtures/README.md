# SwiftPM test-output fixtures

- swift6_aggregate_failure.txt: redacted structural output from GitHub run 43245190832
  at commit 0ffdcae. Actual 531 tests, two failed cases / three assertions; one package bundle.
- swift6_aggregate_success.txt: a positive structural derivative of that same real output.
  It keeps all 529 genuinely passing case start/terminal lines, omits the two failed cases, and
  recomputes the enclosing aggregate as 529 / zero failures. The wrapper status/time/count are
  synthetic. This fixture is not evidence that the original CI run passed.
- swift62_split_success.txt: redacted local successful 531-test run after rebase onto 0e6ab6c,
  with five distinct test bundles (build/r6-02-rebase-ci-test.log).

Only XCTest case/suite/count lines are retained; Actions prefixes, source paths, arbitrary diagnostic
text and the workflow's own derived summary are omitted. Names and real case terminal results
remain intact. These are parser fixtures, never replacements for live CI acceptance.

The isolated-run fixtures added for R6 process isolation are:

- swift62_filtered_adapter_success.txt: real unmodified Adapter-only run at 27d71d3,
  66 positive cases plus four complete zero-case filtered-out bundle summaries.
- swift_test_inventory_532.txt: real output from swift test list at that same source,
  all 532 canonical selectors across the five declared modules. It allows exact selected-case
  coverage checks rather than accepting a merely nonempty filtered run.

- selected_root_adapter_success.txt and selected_root_adapter_truncated.txt: explicit structural
  derivatives of the same genuine 66-case filtered output, keeping the real complete case lines
  and replacing physical-bundle wrappers with one Selected tests root. The truncated variant
  removes the terminal/count. They cover the older no-physical-bundle filtered layout defensively;
  they are not represented as a captured old-Mac filtered run.
