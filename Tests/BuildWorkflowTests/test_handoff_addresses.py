import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("handoff_addresses", ROOT / "configs/check_handoff_addresses.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class HandoffAddressTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        rows = [("pushEncoder", n, cc) for n, cc in enumerate((8, 9, 10, 12), 1)]
        rows += [("button", 1, 67), ("button", 2, 68)]
        self.mapping = self.root / "map.json"
        self.mapping.write_text(
            json.dumps(
                {
                    "entries": [
                        {
                            "control": {"section": section, "row": 1, "index": index},
                            "midi": {"kind": "controlChange", "channel": 0, "number": cc},
                        }
                        for section, index, cc in rows
                    ]
                }
            )
        )
        for name in checker.DOCUMENTS:
            (self.root / name).write_bytes((ROOT / "docs" / name).read_bytes())

    def testAllEightDocumentAddressesMatchExactMap(self):
        self.assertEqual(checker.check(self.mapping, self.root)["passed_count"], 8)

    def testOriginalCancelTypoFails(self):
        path = self.root / "F_PIPE_HANDOFF.md"
        path.write_text(path.read_text().replace("CC12", "CC11"))
        with self.assertRaisesRegex(ValueError, "pushEncoder.1.4"):
            checker.check(self.mapping, self.root)

    def testCandidateWrongChannelFails(self):
        path = self.root / "F_CANDIDATE_ATTENDED.md"
        path.write_text(path.read_text().replace("channel 1 CC67", "channel 2 CC67"))
        with self.assertRaisesRegex(ValueError, "button.1.1"):
            checker.check(self.mapping, self.root)

    def testUnboundHandwrittenAddressFails(self):
        path = self.root / "F_CANDIDATE_ATTENDED.md"
        path.write_text(path.read_text() + "Use CC67.\n")
        with self.assertRaisesRegex(ValueError, "outside a control-ID"):
            checker.check(self.mapping, self.root)

    def testMissingDocumentedAddressFails(self):
        path = self.root / "F_PIPE_HANDOFF.md"
        path.write_text(path.read_text().replace("absolute CC12", "absolute mapped address"))
        with self.assertRaisesRegex(ValueError, "all four"):
            checker.check(self.mapping, self.root)
