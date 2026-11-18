#!/usr/bin/env python3
"""Run all native regressions and a fixed small proof; the default full proof stays unchanged."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs import j4_shadow_verification, macos_workflow, xctest_runner  # noqa: E402
from configs.build_environment import use_build_environment  # noqa: E402

# Explicit native identifiers: never a random sample or a prefix-based omission of regression cases.
REPRESENTATIVE_CASES = (
    "BCRAgentConsoleTests.ControllerRegressionExecutorTests/"
    "testExecutesThirtySharedScenariosAndValidatesReportSeparatelyFromConformance",
    "BCRAgentConsoleTests.ControllerRegressionExecutorTests/"
    "testIndependentNativeAndTypedOwnersMatchEveryApplicableScenarioStep",
    "BCRAgentConsoleTests.GUIFeedbackPathGoldenTests/testRecordedGUIConfirmedConnectAndReconnectSequence",
    "BCRProviderAdapterTests.FeedbackPathGoldenTests/testRecordedProviderAndHardwareDisplaySequences",
    "BCRProviderAdapterTests.FeedbackReentrancyGoldenTests/"
    "testSynchronousReentrancyPreservesPendingAndCompleteOldOutputOrder",
    "BCRAgentCoreTests.SurfaceKernelShadowTests/testIndexRetainsFullOptionalScopeWhenSameIDIsReplacedWithoutReordering",
    "BCRAgentCoreTests.FeedbackSchedulerTests/testErrorCooldownClockRollbackAndClearPreventReplay",
)


@dataclass(frozen=True)
class CapturedProof:
    directory: Path
    started: float
    feedback: Path | None

    def verify(self):
        def remaining():
            return macos_workflow.TEST_TIMEOUT_S - (time.monotonic() - self.started)

        j4_shadow_verification.verify(ROOT, self.directory, self.feedback, remaining())
        write_evidence(self.directory, self.started, representative=True)


def execute(representative: bool) -> CapturedProof | None:
    modules = re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', (ROOT / "Package.swift").read_text())
    if not modules or not macos_workflow.REQUIRED_TEST_MODULES <= set(modules):
        raise RuntimeError("Native layer requires all original test modules")
    runs = ROOT / "build/test-runs"
    runs.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="representative-" if representative else "regression-", dir=runs))
    started = time.monotonic()
    with ExitStack() as contexts:
        feedback = None
        if representative:
            feedback = contexts.enter_context(j4_shadow_verification.capture(ROOT, directory))
        elif any(key in os.environ for key in ("BCR_J3_SHADOW_ROOT", j4_shadow_verification.TRACE_ENV)):
            raise RuntimeError("All-regression CI layer refuses inherited global proof capture")
        options = {"precompiled": True}
        if representative:
            options["selected_cases"] = REPRESENTATIVE_CASES
        report, code = xctest_runner.run(
            ["swift", "test", "--build-path", str(macos_workflow.SWIFTPM_BUILD_ROOT)],
            modules,
            ROOT,
            directory,
            macos_workflow.test_workers(),
            macos_workflow.TEST_TIMEOUT_S,
            **options,
        )
        expected = sorted({case.split(".", 1)[0] for case in REPRESENTATIVE_CASES}) if representative else modules
        if not macos_workflow.summarize_xunit([report], expected, code):
            raise RuntimeError("Native layer failed: " + str(directory))
    if representative:
        return CapturedProof(directory, started, feedback)
    write_evidence(directory, started, representative=False)
    return None


def write_evidence(directory: Path, started: float, *, representative: bool):
    (directory / "ci-layer.json").write_text(
        json.dumps(
            {
                "layer": "representative-proof" if representative else "all-regressions",
                "selected_cases": REPRESENTATIVE_CASES if representative else "all discovered cases",
                "seconds": time.monotonic() - started,
            },
            indent=2,
        )
        + "\n"
    )
    print("Native CI layer evidence: " + str(directory), flush=True)


def main():
    with use_build_environment(ROOT):
        macos_workflow.ensure_dependency(ROOT)
        macos_workflow.ensure_kit_dependency(ROOT)
        proof = execute(True)
        if proof is None:
            raise RuntimeError("Representative capture did not produce a proof to verify")
        # The capture context has exited. Replay reads only its own evidence and launches
        # independent diagnostic processes, while the uninstrumented suite runs normally.
        failures = []
        with ThreadPoolExecutor(max_workers=2) as pool:
            regressions = pool.submit(execute, False)
            comparison = pool.submit(proof.verify)
            for future in (regressions, comparison):
                try:
                    future.result()
                except Exception as error:
                    failures.append(error)
        if failures:
            raise ExceptionGroup("Native CI layers failed", failures)


if __name__ == "__main__":
    main()
