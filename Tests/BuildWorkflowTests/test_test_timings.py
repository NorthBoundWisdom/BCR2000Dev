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

    def test_empty_suite_has_zero_median(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "empty.xml"
            report.write_text("<testsuite/>")
            self.assertEqual(timings.summarize([report])["median"], 0)
