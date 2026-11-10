import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from configs import ci_release, macos_workflow


class CredentialFreeCITests(unittest.TestCase):
    def test_metadata_defaults_to_ad_hoc_without_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.txt"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}, clear=True):
                self.assertEqual(ci_release.main(["metadata", "--version", "1.2.3"]), 0)
            self.assertIn("distribution=ad-hoc\n", output.read_text())

    def test_invalid_distribution_does_not_silently_select_another_mode(self):
        with patch.dict(os.environ, {"BCR_RELEASE_DISTRIBUTION": "misspelled"}, clear=True):
            with self.assertRaisesRegex(ValueError, "Unknown release distribution"):
                ci_release.main(["metadata", "--version", "1.2.3"])

    def test_ad_hoc_signing_never_queries_keychain_or_notary_service(self):
        with patch.object(macos_workflow, "_run") as run:
            macos_workflow._sign(Path("app.app"), "ad-hoc", None)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(all(command[0] == "codesign" for command in commands))
        self.assertEqual(commands[0][commands[0].index("--sign") + 1], "-")

    def test_both_workflows_have_no_configured_credential_access(self):
        root = Path(__file__).resolve().parents[2]
        for filename in ("ci.yml", "release.yml"):
            workflow = (root / ".github/workflows" / filename).read_text()
            with self.subTest(workflow=filename):
                self.assertNotIn("secrets.", workflow)
                self.assertNotIn("ci_signing.py", workflow)
                self.assertNotIn("driverkit_release.py", workflow)
                self.assertNotIn("vars.BCR_RELEASE_DISTRIBUTION", workflow)

    def test_ad_hoc_release_notes_do_not_claim_signed_driver_is_included(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for extension in ("zip", "dmg"):
                asset = root / f"BCRAgentConsole_v1.2.3_1_macOS_universal_ad-hoc.{extension}"
                asset.write_bytes(b"fixture")
                proof = {
                    "schema_version": 1,
                    "asset": asset.name,
                    "version": "1.2.3",
                    "build": "1",
                    "commit": "commit-a",
                    "dirty": False,
                    "architecture": "universal",
                    "signature": "ad-hoc",
                    "notarized": False,
                    "sha256": macos_workflow._sha(asset),
                }
                asset.with_suffix(asset.suffix + ".build.json").write_text(json.dumps(proof))
            ci_release.validate_assets(root, "1.2.3", "commit-a")
            notes = (root / "release-notes.md").read_text()
            self.assertIn("ad-hoc signed, unnotarized", notes)
            self.assertIn("does not install", notes)
            self.assertNotIn("This release is published only after Developer ID", notes)


if __name__ == "__main__":
    unittest.main()
