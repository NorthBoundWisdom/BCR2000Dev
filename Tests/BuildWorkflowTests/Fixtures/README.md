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
