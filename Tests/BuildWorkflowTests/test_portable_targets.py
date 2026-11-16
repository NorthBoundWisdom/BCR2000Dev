import unittest

from configs.check_portable_targets import REQUIRED, inspect
from configs.verify_portable_tests import verify


class PortableTargetTests(unittest.TestCase):
    def graph(self):
        return {
            "targets": [
                {
                    "name": name,
                    "dependencies": [],
                    "exclude": ["RecordingMIDIService.swift"] if name == "BCRTestSupport" else [],
                }
                for name in sorted(REQUIRED)
            ]
        }

    def test_portable_graph_has_all_required_modules(self):
        package = self.graph()
        self.assertEqual(inspect(package), [])
        package["targets"] = [t for t in package["targets"] if t["name"] != "BCRSurfaceDomain"]
        self.assertTrue(any("missing" in error for error in inspect(package)))

    def test_native_dependency_is_rejected(self):
        package = self.graph()
        package["targets"][0]["dependencies"] = [{"byName": ["BCRCoreMIDIDriver", None]}]
        self.assertTrue(any("Native dependency" in error for error in inspect(package)))

    def test_native_helper_must_be_excluded(self):
        package = self.graph()
        for target in package["targets"]:
            target["exclude"] = []
        self.assertTrue(any("Native test helper" in error for error in inspect(package)))


class PortableInventoryTests(unittest.TestCase):
    cases = ["Core.Case/testValue"]

    def test_darwin_and_corelibs_results_both_match_discovery(self):
        for output in (
            "Test Case '-[Core.Case testValue]' started.\nTest Case '-[Core.Case testValue]' passed (0.001 seconds).",
            "Test Case 'Case.testValue' started at 2026-11-16 00:00:00.000\nTest Case 'Case.testValue' passed (0.001 seconds)",
        ):
            self.assertEqual(verify(self.cases, output), {"tests": 1, "failures": 0, "skipped": 0})

    def test_missing_duplicate_and_extra_results_fail(self):
        output = "Test Case 'Case.testValue' started at time\nTest Case 'Case.testValue' passed (0.001 seconds)"
        for bad in ("", output + "\n" + output, output.replace("testValue", "testUnknown")):
            with self.assertRaises(RuntimeError):
                verify(self.cases, bad)

    def test_failure_or_skip_cannot_pass_as_completion(self):
        for status in ("failed", "skipped"):
            output = f"Test Case 'Case.testValue' started at time\nTest Case 'Case.testValue' {status} (0.001 seconds)"
            with self.assertRaises(RuntimeError):
                verify(self.cases, output)
