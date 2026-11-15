"""Checker self-tests deliberately introduce reverse dependencies in isolated trees."""

from pathlib import Path
import tempfile
import unittest

from configs.check_domain_boundaries import check_layers


def target(*dependencies):
    return {"type": "regular", "dependencies": [{"byName": [name, None]} for name in dependencies]}


class LayerBoundaryTests(unittest.TestCase):
    def test_runtime_to_transport_manifest_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = check_layers(
                {"BCRSurfaceDomain": target("BCRHTTPTransport"), "BCRHTTPTransport": target()}, Path(directory)
            )
        self.assertEqual(result, ["Layer violation: BCRSurfaceDomain (runtime) -> BCRHTTPTransport (transport)"])

    def test_nested_bridge_source_cannot_bypass_manifest_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/BCRMCPAdapter/Nested/Bad.swift"
            source.parent.mkdir(parents=True)
            source.write_text("import BCRCoreMIDIDriver\n")
            result = check_layers({"BCRMCPAdapter": target(), "BCRCoreMIDIDriver": target()}, root)
        self.assertEqual(
            result, ["Layer import violation: Sources/BCRMCPAdapter/Nested/Bad.swift -> BCRCoreMIDIDriver"]
        )

    def test_new_production_module_requires_explicit_role(self):
        with tempfile.TemporaryDirectory() as directory:
            result = check_layers({"UnreviewedRuntime": target()}, Path(directory))
        self.assertEqual(result, ["Unclassified production module: UnreviewedRuntime"])

    def test_outer_composition_and_transport_may_consume_bridges(self):
        with tempfile.TemporaryDirectory() as directory:
            result = check_layers(
                {
                    "BCRProviderService": target("BCRHTTPTransport", "BCRCoreMIDIDriver"),
                    "BCRHTTPTransport": target("BCRMCPAdapter"),
                    "BCRMCPAdapter": target("BCRSurfaceDomain"),
                    "BCRSurfaceDomain": target(),
                    "BCRCoreMIDIDriver": target("BCRSurfaceDomain"),
                },
                Path(directory),
            )
        self.assertEqual(result, [])
