import unittest

from configs.package_provider import candidate_status


class PackageCandidateMetadataTests(unittest.TestCase):
    def test_clean_remote_head_uses_unreleased_candidate_label(self):
        self.assertEqual(candidate_status(dirty=False, source_unpushed=False), "remote-head-unreleased-candidate")

    def test_dirty_or_unpushed_preserves_legacy_local_candidate_label(self):
        for dirty, unpushed in ((True, False), (False, True), (True, True)):
            with self.subTest(dirty=dirty, source_unpushed=unpushed):
                self.assertEqual(candidate_status(dirty=dirty, source_unpushed=unpushed), "local-unpushed-candidate")
