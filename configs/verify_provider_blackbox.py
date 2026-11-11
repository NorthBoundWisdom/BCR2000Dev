#!/usr/bin/env python3
"""Black-box provider acceptance: only a published artifact and its public SDK are used."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import sys
import tempfile
import time


def validate_contract(value, schema, root=None):
    """Validate the provider's published JSON Schema vocabulary, independently of Swift DTOs."""
    root = schema if root is None else root
    if "$ref" in schema:
        assert schema["$ref"].startswith("#/$defs/"), "Unexpected external Schema reference"
        return validate_contract(value, root["$defs"][schema["$ref"][8:]], root)
    if "const" in schema:
        assert value == schema["const"] and isinstance(value, bool) == isinstance(schema["const"], bool), (
            "Schema constant mismatch"
        )
    if "enum" in schema:
        assert value in schema["enum"], "Schema enumeration mismatch"
    if "oneOf" in schema:
        matches = 0
        for candidate in schema["oneOf"]:
            try:
                validate_contract(value, candidate, root)
                matches += 1
            except AssertionError:
                pass
        assert matches == 1, "Schema oneOf mismatch"
    kinds = schema.get("type")
    if kinds is not None:
        kinds = kinds if isinstance(kinds, list) else [kinds]
        valid = {
            "object": isinstance(value, dict),
            "array": isinstance(value, list),
            "string": isinstance(value, str),
            "number": type(value) in (int, float),
            "integer": type(value) is int,
            "boolean": type(value) is bool,
            "null": value is None,
        }
        assert any(valid.get(kind, False) for kind in kinds), "Schema type mismatch"
    if isinstance(value, dict):
        assert all(key in value for key in schema.get("required", [])), "Schema required property missing"
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            assert set(value) <= set(properties), "Schema returned undocumented properties"
        for key, item in value.items():
            if key in properties:
                validate_contract(item, properties[key], root)
    if isinstance(value, list):
        assert len(value) >= schema.get("minItems", 0) and len(value) <= schema.get("maxItems", float("inf")), (
            "Schema array size mismatch"
        )
        if "items" in schema:
            for item in value:
                validate_contract(item, schema["items"], root)
    if type(value) in (int, float):
        assert value >= schema.get("minimum", -float("inf")) and value <= schema.get("maximum", float("inf")), (
            "Schema numeric bound mismatch"
        )
        assert value > schema.get("exclusiveMinimum", -float("inf")), "Schema exclusive bound mismatch"
    if isinstance(value, str):
        assert len(value) >= schema.get("minLength", 0) and len(value) <= schema.get("maxLength", float("inf")), (
            "Schema string length mismatch"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    artifact = args.artifact.resolve()
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    sdk = artifact / "bcr-provider-sdk-1.0.0.zip"
    sys.path.insert(0, str(sdk))
    from bcr_provider import Client, ProviderError

    class CheckedClient(Client):
        def bind_schemas(self):
            self.schemas = {tool["name"]: tool["outputSchema"] for tool in self.tools()}

        def call(self, name, arguments=None):
            value = super().call(name, arguments)
            if name in self.schemas:
                validate_contract({"data": value}, self.schemas[name])
            return value

    manifest = json.loads((artifact / "manifest.json").read_text())
    for name, expected in manifest["files_sha256"].items():
        assert hashlib.sha256((artifact / name).read_bytes()).hexdigest() == expected, "Artifact digest mismatch"
    cases = []

    def passed(name, scope="published provider API"):
        cases.append({"name": name, "scope": scope, "passed": True})
        print("PASS", name, flush=True)

    class Host:
        def __init__(self, name, flags):
            self.token = secrets.token_hex(32)
            self.error = (args.output / (name + ".stderr.log")).open("w")
            self.process = subprocess.Popen(
                [str(artifact / "BCRProviderService"), "--port", "0", *flags],
                cwd=tempfile.gettempdir(),
                env={**os.environ, "BCR_PROVIDER_TOKEN": self.token, "BCR_PROVIDER_PACKAGED": "1"},
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=self.error,
                text=True,
                bufsize=1,
            )
            selected = selectors.DefaultSelector()
            selected.register(self.process.stdout, selectors.EVENT_READ)
            assert selected.select(10), "Published provider did not announce readiness"
            line = self.process.stdout.readline()
            assert line, "Published provider exited during startup"
            self.ready = json.loads(line)
            self.client = CheckedClient(self.ready["url"], self.token, expected_provider_id=self.ready["provider_id"])
            self.client.bind_schemas()

        def close(self):
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.error.close()

    def reject(callback, code=None):
        try:
            callback()
        except ProviderError as error:
            if code:
                assert error.code == code, "Unexpected public error classification"
            return
        raise AssertionError("Invalid operation was accepted")

    host = Host(
        "manual",
        [
            "--robot-sim",
            "--chassis-sim",
            "--clock",
            "manual",
            "--allow-configuration",
            "--allow-device-control",
            "--allow-robot-control",
            "--allow-chassis-control",
            "--allow-simulation-control",
            "--write-limit",
            "1000",
        ],
    )
    try:
        c = host.client
        caps = c.call("provider_capabilities")
        assert caps["provider_id"] == host.ready["provider_id"]
        assert caps["resources"] == "embedded" and caps["contract_version"] == "1.0"
        assert caps["robot"]["source"] == caps["chassis"]["source"] == "simulation"
        assert caps["agent"]["enabled"] is False and caps["permissions"]["agentControl"] is False
        assert c.call("provider_contract") == json.loads((artifact / "schemas/provider.schema.json").read_text())
        assert "get_agents" not in {tool["name"] for tool in c.tools()}
        passed("self-contained resources/schema/discovery; no Agent runtime")
        reject(lambda: Client(host.ready["url"], secrets.token_hex(32)).call("provider_capabilities"), "http_401")
        reject(
            lambda: Client(host.ready["url"], host.token, expected_provider_id="wrong-instance").call(
                "provider_capabilities"
            ),
            "http_409",
        )
        reject(lambda: c.call("unsupported_device_command"), "unsupported")
        passed("authentication and unsupported capability rejection")

        stream = c.events("console")
        initial = next(stream)
        assert initial["reset"]
        c.call(
            "console_mock_input",
            {"operation": "turn", "control": {"section": "pushEncoder", "row": 1, "index": 1}, "delta": 10},
        )
        changed = next(stream)
        assert not changed["reset"]
        assert any(
            event["kind"] == "control.input" and event["source"] == "mock" and event["payload"]["origin"] == "agent"
            for event in changed["events"]
        )
        stream.close()
        passed("console SSE actual input source differs from software feedback")
        reject(
            lambda: next(
                Client(host.ready["url"], host.token, expected_provider_id="wrong-instance").events("console")
            ),
            "http_409",
        )
        passed("SSE instance pin rejects the wrong provider before a stream opens")
        old_generation = initial["generation"]
        c.call(
            "assign_control",
            {
                "assignment": {
                    "control": {"section": "pushEncoder", "row": 1, "index": 1},
                    "target": {"parameter": {"_0": "general.2"}},
                    "buttonBehavior": "toggle",
                    "inverted": False,
                }
            },
        )
        reject(
            lambda: c.call("console_events", {"schema_version": 1, "generation": old_generation}), "stale_generation"
        )
        for index in range(caps["console"]["input_event_capacity"] + 5):
            c.call(
                "console_mock_input",
                {
                    "operation": "turn",
                    "control": {"section": "pushEncoder", "row": 1, "index": 1},
                    "delta": 1 if index % 2 else -1,
                },
            )
        inventory = c.call("console_events", {"schema_version": 1})
        assert inventory["reset"] and inventory["dropped"] > 0
        reject(
            lambda: c.call(
                "console_events", {"schema_version": 1, "generation": inventory["generation"], "after_sequence": 0}
            ),
            "event_gap",
        )
        passed("mapping invalidation, bounded event inventory and explicit cursor gap")
        c.call(
            "create_parameter",
            {
                "definition": {
                    "id": "generic.protected",
                    "name": "Protected",
                    "minimum": 0,
                    "maximum": 1,
                    "externallyProtected": True,
                    "agentWritable": True,
                }
            },
        )
        reject(lambda: c.call("set_parameter", {"id": "generic.protected", "value": 1}))
        passed("explicit external-write protection")

        def snapshot(domain):
            return c.call(domain + "_state", {"schema_version": 1, "device_id": domain + ".reference"})

        unknown_robot = snapshot("robot")
        for invalid in (
            {"schema_version": 2, "device_id": "robot.reference"},
            {"schema_version": 1, "device_id": "robot.unknown"},
            {"schema_version": 1, "device_id": "robot.reference", "frame_id": "unknown_frame"},
        ):
            reject(lambda invalid=invalid: c.call("robot_state", invalid), "invalid_argument")
        reject(
            lambda: c.call(
                "robot_command",
                {
                    "schema_version": 1,
                    "device_id": "robot.reference",
                    "generation": unknown_robot["metadata"]["generation"],
                    "operation": "initialize",
                    "initial_joints_deg": [0] * 6,
                },
            ),
            "invalid_argument",
        )
        assert snapshot("robot") == unknown_robot
        passed("incompatible versions, unknown resources/frames and wrong unit fields reject without mutation")

        generations = {}
        grants = {}
        sequences = {}

        def command(domain, operation, controlled=False, **fields):
            body = {
                "schema_version": 1,
                "device_id": domain + ".reference",
                "operation": operation,
                "generation": generations[domain],
                **fields,
            }
            if controlled:
                sequences[domain] += 1
                body.update(control_token=grants[domain]["control_token"], command_sequence=sequences[domain])
            return c.call(domain + "_command", body)

        def advance(domain, count, dt=0.1):
            for _ in range(count):
                c.call("simulation_advance", {"schema_version": 1, "domain": domain, "dt_s": dt})

        for domain in ("robot", "chassis"):
            before = snapshot(domain)
            assert before["actual"] is None and not before["stopped"]
            generations[domain] = before["metadata"]["generation"]
            fields = {"initial_joints_rad": [0] * 6} if domain == "robot" else {"initial_pose_m_rad": [0, 0, 0]}
            initialized = command(domain, "initialize", **fields)["state"]
            generations[domain] = initialized["metadata"]["generation"]
            grants[domain] = command(domain, "acquire", owner="black-box-fixture", ttl_s=5)["control"]
            sequences[domain] = 0
            command(domain, "enable", controlled=True)
        robot_before = snapshot("robot")
        reject(
            lambda: c.call(
                "robot_command",
                {
                    "schema_version": 1,
                    "device_id": "robot.reference",
                    "operation": "enable",
                    "generation": generations["robot"],
                    "control_token": grants["robot"]["control_token"],
                    "command_sequence": 1,
                },
            ),
            "stale_sequence",
        )
        reject(
            lambda: c.call(
                "robot_command",
                {
                    "schema_version": 1,
                    "device_id": "robot.reference",
                    "operation": "enable",
                    "generation": "stale",
                    "control_token": grants["robot"]["control_token"],
                    "command_sequence": 2,
                },
            ),
            "stale_generation",
        )
        reject(
            lambda: command(
                "robot",
                "move_joints",
                controlled=True,
                target_joints_rad=[100, 0, 0, 0, 0, 0],
                duration_s=1,
                valid_for_s=2,
            ),
            "invalid_argument",
        )
        assert snapshot("robot")["metadata"]["last_command_sequence"] == 1
        passed("unknown pose remains unknown; tokens/generations/sequences/limits are enforced")
        command(
            "robot", "move_joints", controlled=True, target_joints_rad=[0.4, 0, 0, 0, 0, 0], duration_s=1, valid_for_s=2
        )
        assert snapshot("robot")["actual"]["joints_rad"] == robot_before["actual"]["joints_rad"]
        advance("robot", 5)
        assert 0 < snapshot("robot")["actual"]["joints_rad"][0] < 0.4
        command("robot", "stop", controlled=True)
        advance("robot", 5)
        stopped_robot = snapshot("robot")
        assert stopped_robot["stopped"] and all(abs(v) < 1e-10 for v in stopped_robot["actual"]["joint_velocity_rad_s"])
        passed("robot accepted target, propagated actual FK/joints and confirmed bounded stop")
        robot_time = stopped_robot["metadata"]["simulated_time_s"]
        command("chassis", "drive", controlled=True, speed_m_s=0.5, steering_angle_rad=0.2, valid_for_s=1)
        advance("chassis", 4)
        moving = snapshot("chassis")
        assert moving["actual"]["pose_m_rad"][0] > 0 and moving["actual"]["pose_m_rad"][1] > 0
        assert snapshot("robot")["metadata"]["simulated_time_s"] == robot_time
        command("chassis", "stop", controlled=True)
        advance("chassis", 6)
        assert snapshot("chassis")["stopped"]
        assert snapshot("chassis")["actual"]["speed_m_s"] == 0
        passed("Ackermann motion/steering/stop and independent device clocks")
        chassis_before = snapshot("chassis")
        console_before = c.call("get_status")["input_generation"]
        command("robot", "reset")
        assert snapshot("chassis") == chassis_before and c.call("get_status")["input_generation"] == console_before
        assert snapshot("robot")["actual"] is None
        reject(
            lambda: c.call(
                "robot_command",
                {
                    "schema_version": 1,
                    "device_id": "robot.reference",
                    "operation": "enable",
                    "generation": generations["robot"],
                    "control_token": grants["robot"]["control_token"],
                    "command_sequence": 999,
                },
            ),
            "stale_generation",
        )
        command("chassis", "fault", fault_code="telemetry_unavailable")
        assert snapshot("chassis")["actual"] is None
        passed("reset/fault isolation and old control invalidation")
        for domain in ("robot", "chassis"):
            encoded = json.dumps(snapshot(domain))
            assert grants[domain]["control_token"] not in encoded and host.token not in encoded
        passed("read-only snapshots never expose control credentials")
        devices = c.events("devices")
        first_devices = next(devices)
        assert first_devices["reset"] and first_devices["source"] == "simulation"
        advance("robot", 1, 0.01)
        delta_devices = next(devices)
        assert not delta_devices["reset"]
        assert any(
            event["kind"] == "devices.changed" and event["payload"]["provider_id"] == host.ready["provider_id"]
            for event in delta_devices["events"]
        )
        devices.close()
        passed("device SSE is explicitly simulation and pinned to the same instance")
    finally:
        host.close()

    realtime = Host(
        "realtime", ["--no-console", "--chassis-sim", "--allow-chassis-control", "--allow-simulation-control"]
    )
    try:
        c = realtime.client
        caps = c.call("provider_capabilities")
        assert caps["provider_id"] != host.ready["provider_id"]
        assert not caps["console"]["enabled"] and not caps["robot"]["enabled"]
        state = c.call("chassis_state", {"schema_version": 1, "device_id": "chassis.reference"})
        generation = state["metadata"]["generation"]

        def drive_command(operation, **fields):
            return c.call(
                "chassis_command",
                {
                    "schema_version": 1,
                    "device_id": "chassis.reference",
                    "operation": operation,
                    "generation": generation,
                    **fields,
                },
            )

        state = drive_command("initialize", initial_pose_m_rad=[0, 0, 0])["state"]
        generation = state["metadata"]["generation"]
        grant = drive_command("acquire", owner="watchdog-fixture", ttl_s=0.3)["control"]
        drive_command("enable", control_token=grant["control_token"], command_sequence=1)
        drive_command(
            "drive",
            control_token=grant["control_token"],
            command_sequence=2,
            speed_m_s=0.5,
            steering_angle_rad=0,
            valid_for_s=0.15,
        )
        time.sleep(0.7)
        stopped = c.call("chassis_state", {"schema_version": 1, "device_id": "chassis.reference"})
        assert stopped["stopped"] and not stopped["metadata"]["enabled"] and stopped["actual"]["pose_m_rad"][0] > 0
        reject(lambda: c.call("get_status"), "unsupported")
        reject(lambda: next(c.events("parameters")), "http_400")
        passed("autonomous realtime expiry/stop without console, GUI, Agent or state polling")
    finally:
        realtime.close()

    summary = {
        "scope": "published-artifact-only loopback API acceptance; no physical input qualification",
        "artifact_source": manifest["source_commit"],
        "dirty": manifest["dirty"],
        "passed": True,
        "cases": cases,
        "case_count": len(cases),
        "sdk_import": "published zip only",
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"passed": True, "cases": len(cases)}))


if __name__ == "__main__":
    main()
