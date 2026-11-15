import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "test_timings", Path(__file__).resolve().parents[2] / "tools/test_timings.py"
)
timings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(timings)


class TestTimingsTests(unittest.TestCase):
    def test_nested_suites_are_counted_once_and_ranked(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "xunit.xml"
            report.write_text(
                '<testsuites><testsuite><testcase classname="A" name="fast" time="0.1"/>'
                '<testcase classname="A" name="slow" time="0.3"><failure/></testcase>'
                '<testsuite><testcase classname="B" name="other" time="0.5"/>'
                "</testsuite></testsuite></testsuites>"
            )
            result = timings.summarize([report])
        self.assertEqual(result["count"], 3)
        self.assertAlmostEqual(result["seconds"], 0.9)
        self.assertEqual(result["median"], 0.3)
        self.assertEqual(result["failures"], 1)
        self.assertEqual([row["class"] for row in result["classes"]], ["B", "A"])
        self.assertEqual([row["name"] for row in result["cases"]], ["other", "slow", "fast"])

    def test_native_xunit_keeps_its_timing_source(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "native.xml"
            report.write_text(
                '<testsuites timing_source="xctest-body"><testsuite>'
                '<testcase classname="A" name="test" time="0.003"/>'
                "</testsuite></testsuites>"
            )
            result = timings.summarize([report])
            self.assertEqual(result["measurement"], "xctest-body")

    def test_empty_suite_has_zero_median(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "empty.xml"
            report.write_text("<testsuite/>")
            self.assertEqual(timings.summarize([report])["median"], 0)


class NativeTimingTests(unittest.TestCase):
    def test_native_durations_are_separate_from_process_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text(
                "Test Case '-[Module.Fast testOK]' passed (0.003 seconds).\n"
                "Test Case '-[Module.Fast testHardware]' skipped (0.001 seconds).\n"
                "Test Case '-[Module.Slow testError]' failed (0.250 seconds).\n"
            )
            result = timings.summarize_log(log)
        self.assertEqual(result["count"], 3)
        self.assertEqual(result["failures"], 1)
        self.assertEqual(result["skipped"], 1)
        self.assertAlmostEqual(result["seconds"], 0.254)
        self.assertEqual(result["median"], 0.003)
