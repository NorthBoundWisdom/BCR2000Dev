import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[2] / "tools"))
import macos_test_session as runner


class SessionGateTests(unittest.TestCase):
    def execute(self, physical=True, response=True, max_cases=24, transient=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root=Path(temporary.name); helper=root/"helper"; helper.touch()
        args=SimpleNamespace(reports=str(root), mode="matrix", usb_helper=str(helper), baseline=None,
                             test_cc=74, channel=1, input=None, output=None, max_cases=max_cases, wait=.2,
                             expected_identity="BCR2000 1.10", hold_max=False, deadline=240)
        seen=[]
        def command(name, arguments, directory, timeout):
            seen.append(name)
            stderr=Path(directory)/(name+".stderr.txt");stderr.write_text("")
            stage={"name":name,"status":"ok","exitCode":0,"stderr":stderr.name,"data":{}}
            if name=="usb-descriptors":
                stage["data"]={"targets":[{"cachedConfiguration":{"status":"unavailable"}}] if physical else []}
            elif name.startswith("midi-inventory"):
                stage["data"]={"inputs":[{"id":0,"name":"BCR2000 Port 1"}],"outputs":[{"id":0,"name":"BCR2000 Port 1"}]}
            elif name.startswith("virtual-"):
                if transient and name=="virtual-ump1":
                    stage.update(status="error",exitCode=1)
                    stderr.write_text("ERROR: Create virtual client: OSStatus -304")
                else:stage["data"]={"status":"passed"}
            elif name.startswith("read-") or name=="write-roundtrip":
                data={"identity":{"identity":"BCR2000 1.10"} if response else None,"snapshotCCCount":56 if response else 0}
                if name=="write-roundtrip":data.update(valueRoundtripPassed=True,finalRequested=13,finalObserved=13)
                Path(arguments[arguments.index("--report")+1]).write_text(json.dumps(data))
            return stage
        with patch.object(runner,"command_stage",side_effect=command), patch.object(runner.time,"sleep"):
            directory, report, status=runner.session(args)
        self.assertTrue((directory/"session.json").exists())
        return report,status,seen

    def test_stale_midi_endpoints_without_physical_usb_never_start_matrix(self):
        report,status,seen=self.execute(physical=False)
        self.assertEqual(status,2)
        self.assertEqual(report["hardwareStatus"],"blocked_physical_usb_absent_or_ambiguous")
        self.assertNotIn("read-1",seen)
        self.assertNotIn("write-roundtrip",seen)

    def test_no_identity_response_never_allows_write(self):
        report,status,seen=self.execute(response=False)
        self.assertEqual(status,2)
        self.assertEqual(report["hardwareStatus"],"no_verified_usb_roundtrip")
        self.assertNotIn("write-roundtrip",seen)

    def test_verified_route_allows_one_guarded_write_stage(self):
        report,status,seen=self.execute()
        self.assertEqual(status,0)
        self.assertEqual(report["hardwareStatus"],"value_roundtrip_verified")
        self.assertEqual(seen.count("write-roundtrip"),1)

    def test_matrix_limit_is_not_silently_truncated(self):
        report,status,seen=self.execute(max_cases=1)
        self.assertEqual(status,2)
        self.assertEqual(report["hardwareStatus"],"blocked_endpoint_matrix_too_large")
        self.assertNotIn("read-1",seen)

    def test_virtual_retry_preserves_the_failed_attempt(self):
        report,status,seen=self.execute(transient=True)
        self.assertEqual(status,0)
        self.assertIn("virtual-ump1",seen)
        self.assertIn("virtual-ump1-retry",seen)
        self.assertTrue(any(s["name"]=="virtual-ump1" and s["status"]=="error" for s in report["stages"]))


if __name__=="__main__":unittest.main()
