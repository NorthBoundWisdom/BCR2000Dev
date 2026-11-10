#!/usr/bin/env python3
"""Remote-ready macOS diagnostics. Default preflight is hardware-read-only.

Matrix mode adds whitelisted BCR identity/snapshot requests. CC writes require
an explicit previously learned target and a verified identity/snapshot pair.
No reset, seize, driver/service/configuration change or preset/firmware writes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import subprocess
import sys
import time

from diagnostic_io import command_stage, write_json
from midi_feedback_probe import CC, MacMIDI
from windows_usb_descriptor import parse, full_speed_bulk_warnings

ROOT = Path(__file__).resolve().parent


def classify_probe(data, writing=False):
    if not isinstance(data, dict):
        return "invalid_report"
    if data.get("error") or data.get("cleanupError") or data.get("finalError") or data.get("inputDropped", 0):
        return "error"
    if not data.get("identity"):
        return "no_identity_response"
    if data.get("snapshotCCCount", 0) < 2:
        return "identity_only"
    if writing:
        if data.get("valueRoundtripPassed") is not True:
            return "value_roundtrip_failed"
        if data.get("finalRequested") is None or data.get("finalObserved") != data.get("finalRequested"):
            return "final_state_unverified"
        return "value_roundtrip_verified"
    return "readback_verified"


def compare_usb(native, baseline):
    targets = native.get("targets", []) if isinstance(native, dict) else []
    reference = baseline.get("targets", []) if isinstance(baseline, dict) else []
    if len(targets) != 1:
        return {"status": "unavailable", "reason": "Need exactly one physical BCR USB device"}
    cached = targets[0].get("cachedConfiguration", {})
    if cached.get("status") != "ok":
        return {"status": "unavailable", "reason": "Cached configuration could not be read"}
    try:
        raw = bytes.fromhex(cached["configurationHex"])
        descriptors = parse(raw)
    except (KeyError, ValueError, TypeError) as error:
        return {"status": "error", "reason": str(error)}
    result = {"status": "no_baseline", "configurationBytes": len(raw), "descriptors": descriptors,
              "fullSpeedBulkSizeWarnings": full_speed_bulk_warnings(descriptors, targets[0].get("USBSpeed"))}
    if len(reference) == 1:
        differences = []
        if len(raw) != reference[0].get("configurationBytes"):
            differences.append("configurationBytes")
        if descriptors != reference[0].get("descriptors"):
            differences.append("descriptors")
        result.update(status="matched" if not differences else "different", differences=differences)
    return result


def inventory():
    backend = MacMIDI()
    try:
        return {"inputs": [p.__dict__ for p in backend.ports(True) if "bcr2000" in p.name.casefold()],
                "outputs": [p.__dict__ for p in backend.ports(False) if "bcr2000" in p.name.casefold()],
                "availabilityNotes": backend.availability_notes}
    finally:
        backend.close()


def verify_manifest(root):
    path = root / "manifest.json"
    if not path.exists():
        return {"status": "source_checkout", "reason": "No distribution manifest"}
    data = json.loads(path.read_text())
    for name, expected in data["files"].items():
        candidate = root / name
        if candidate.is_symlink() or not candidate.resolve().is_relative_to(root.resolve()) or not candidate.is_file():
            raise ValueError("Unsafe or missing bundle member")
        if hashlib.sha256(candidate.read_bytes()).hexdigest() != expected:
            raise ValueError("Bundle member checksum mismatch: " + name)
    return {"status": "verified", "revision": data.get("revision"), "dirty": data.get("dirty", False)}


def load_target_profile(path):
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict) or set(value) - {"version", "channel", "controller", "expectedIdentity"} or type(value.get("version")) is not int or value.get("version") != 1:
        raise ValueError("Unsupported target profile")
    channel, controller = value.get("channel"), value.get("controller")
    if type(channel) is not int or type(controller) is not int:
        raise ValueError("Target channel/controller must be integers")
    CC(channel, controller, 0).packed()
    if controller in {0, 6, 32, 38, 96, 97, 98, 99, 100, 101} or controller >= 120:
        raise ValueError("Target is not an ordinary CC encoder")
    if not isinstance(value.get("expectedIdentity"), str) or not value["expectedIdentity"].startswith("BCR2000 "):
        raise ValueError("Target profile requires a previously verified BCR identity")
    return value


def session(args):
    root = Path(args.reports).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    directory = root / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(4))
    directory.mkdir(mode=0o700)
    report = {"schemaVersion": 1, "mode": args.mode, "stages": [], "hardwareStatus": "not_tested",
              "visualLED": "not observed automatically", "writesRequested": args.test_cc is not None,
              "system": {"macOS": platform.mac_ver()[0], "architecture": platform.machine(), "python": platform.python_version(),
                         "ssh": bool(os.environ.get("SSH_CONNECTION")), "guiAgent": os.environ.get("BCR_DIAGNOSTIC_GUI") == "1"}}
    exit_code = 0
    deadline = time.monotonic() + args.deadline
    def stage_command(name, command, timeout):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Session deadline exceeded; no further test stages started")
        return command_stage(name, command, directory, min(timeout, remaining))
    try:
        report["bundle"] = verify_manifest(ROOT)
        native = Path(args.usb_helper).resolve() if args.usb_helper else ROOT / "bin/macos-usb-descriptor"
        if not native.exists() and not (ROOT / "manifest.json").exists() and not args.usb_helper:
            native = ROOT.parent / "build/hardware-tools/macos-usb-descriptor"
        if native.exists():
            stage = stage_command("usb-descriptors", [str(native)], 20)
            report["stages"].append(stage)
            usb = stage.get("data") or {}
        else:
            usb = {}
            report["stages"].append({"name": "usb-descriptors", "status": "unavailable", "error": "Use packaged helper or build tools/macos_usb_descriptor.swift"})
        baseline_path = Path(args.baseline) if args.baseline else ROOT / "baselines/windows-usb.json"
        if args.baseline and not baseline_path.is_file():
            raise ValueError("Explicit Windows baseline does not exist")
        baseline = json.loads(baseline_path.read_text()) if baseline_path.exists() else None
        report["usbComparison"] = compare_usb(usb, baseline)
        stage = stage_command("midi-inventory", [sys.executable, str(ROOT / "macos_test_session.py"), "--inventory-worker"], 20)
        report["stages"].append(stage)
        ports = stage.get("data") or {}
        tests_ok = True
        for api in ["legacy", "ump1", "ump2"]:
            command = [sys.executable, str(ROOT / "macos_bcr_selftest.py"), "--mac-api", api]
            stage = stage_command("virtual-" + api, command, 30)
            report["stages"].append(stage)
            # Only the known client-creation failure is retried, only in an entirely
            # virtual test. Preserve the failed attempt; never retry physical writes.
            error_text = (directory / stage["stderr"]).read_text()
            if stage["status"] == "error" and "Create virtual client: OSStatus -304" in error_text:
                time.sleep(1)
                stage = stage_command("virtual-" + api + "-retry", command, 30)
                stage["retryReason"] = "Explicit retry of transient -304 before any physical I/O"
                report["stages"].append(stage)
            tests_ok = tests_ok and stage["status"] == "ok" and (stage.get("data") or {}).get("status") == "passed"
            time.sleep(0.5)
        report["nativeSelfTestsPassed"] = tests_ok
        # Virtual endpoints were created and removed. Refresh physical indices
        # instead of relying on enumeration order from before the self-tests.
        if tests_ok and args.mode == "matrix":
            refreshed = stage_command("midi-inventory-after-selftest", [sys.executable, str(ROOT / "macos_test_session.py"), "--inventory-worker"], 20)
            report["stages"].append(refreshed)
            ports = refreshed.get("data") or {}
        if not tests_ok:
            report["hardwareStatus"] = "blocked_by_native_self_test"
            return directory, report, 1
        if args.mode == "preflight":
            report["hardwareStatus"] = "not_tested_preflight_only"
            return directory, report, 0
        if len(usb.get("targets", [])) != 1:
            report["hardwareStatus"] = "blocked_physical_usb_absent_or_ambiguous"
            return directory, report, 2
        inputs, outputs = ports.get("inputs", []), ports.get("outputs", [])
        if args.input is not None:
            inputs = [p for p in inputs if p["id"] == args.input]
        if args.output is not None:
            outputs = [p for p in outputs if p["id"] == args.output]
        if len(inputs) * len(outputs) * 3 > args.max_cases:
            report["hardwareStatus"] = "blocked_endpoint_matrix_too_large"
            return directory, report, 2
        if not inputs or not outputs:
            report["hardwareStatus"] = "blocked_midi_endpoints_absent"
            return directory, report, 2
        verified = []
        case = 0
        for api in ["legacy", "ump1", "ump2"]:
            for source in inputs:
                for destination in outputs:
                    case += 1
                    filename = directory / f"read-{case}.json"
                    command = [sys.executable, str(ROOT / "macos_bcr_roundtrip.py"), "--mac-api", api,
                               "--input", str(source["id"]), "--output", str(destination["id"]), "--wait", str(args.wait), "--report", str(filename)]
                    stage = stage_command(f"read-{case}", command, 20)
                    data = json.loads(filename.read_text()) if filename.exists() else None
                    stage["verification"] = classify_probe(data) if stage["status"] == "ok" else stage["status"]
                    stage["route"] = {"input": source["name"], "output": destination["name"], "inputIndex": source["id"], "outputIndex": destination["id"], "api": api}
                    report["stages"].append(stage)
                    if stage["verification"] == "readback_verified":
                        verified.append((source, destination, api))
        report["verifiedRoutes"] = len(verified)
        if not verified:
            report["hardwareStatus"] = "no_verified_usb_roundtrip"
            return directory, report, 2
        if args.test_cc is None:
            report["hardwareStatus"] = "read_only_roundtrip_verified"
            return directory, report, 0
        if deadline - time.monotonic() < 30:
            report["hardwareStatus"] = "blocked_insufficient_write_deadline"
            return directory, report, 2
        source, destination, api = verified[0]
        filename = directory / "write-roundtrip.json"
        command = [sys.executable, str(ROOT / "macos_bcr_roundtrip.py"), "--mac-api", api,
                   "--input", str(source["id"]), "--output", str(destination["id"]), "--wait", str(args.wait),
                   "--test-cc", str(args.test_cc), "--channel", str(args.channel), "--report", str(filename)]
        if args.expected_identity:
            command += ["--expected-identity", args.expected_identity]
        if args.hold_max:
            command.append("--hold-max")
        stage = stage_command("write-roundtrip", command, 30)
        data = json.loads(filename.read_text()) if filename.exists() else None
        stage["verification"] = classify_probe(data, True) if stage["status"] == "ok" else stage["status"]
        report["stages"].append(stage)
        report["hardwareStatus"] = stage["verification"]
        exit_code = 0 if stage["verification"] == "value_roundtrip_verified" else 2
        return directory, report, exit_code
    except Exception as error:
        report["error"] = {"type": type(error).__name__, "message": str(error)}
        return directory, report, 1
    finally:
        if args.mode == "matrix":
            predicate = '(process == "MIDIServer" OR process == "kernel" OR subsystem CONTAINS[c] "usb") AND (eventMessage CONTAINS[c] "BCR2000" OR eventMessage CONTAINS[c] "MaxPacket" OR eventMessage CONTAINS[c] "packet size" OR eventMessage CONTAINS[c] "CreatePipe")'
            report["stages"].append(command_stage("filtered-usb-log", ["/usr/bin/log", "show", "--last", "5m", "--style", "json", "--predicate", predicate], directory, 15))
        write_json(directory / "session.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["preflight", "matrix"], default="preflight")
    parser.add_argument("--reports", default=str(Path.home() / "Library/Application Support/BCRAgentConsole/Diagnostics"))
    parser.add_argument("--baseline")
    parser.add_argument("--usb-helper")
    parser.add_argument("--input", type=int)
    parser.add_argument("--output", type=int)
    parser.add_argument("--max-cases", type=int, default=24)
    parser.add_argument("--test-cc", type=int)
    parser.add_argument("--channel", type=int)
    parser.add_argument("--target-profile", help="private previously learned target; enables writes only with matrix mode")
    parser.add_argument("--expected-identity")
    parser.add_argument("--hold-max", action="store_true")
    parser.add_argument("--wait", type=float, default=0.75)
    parser.add_argument("--deadline", type=int, default=240)
    parser.add_argument("--completion-file", help=argparse.SUPPRESS)
    parser.add_argument("--inventory-worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Remote test session requires macOS")
    if args.inventory_worker:
        print(json.dumps(inventory()))
        return 0
    if args.target_profile:
        target = load_target_profile(args.target_profile)
        if args.test_cc is not None and args.test_cc != target["controller"]:
            parser.error("Conflicting explicit target/profile")
        if args.channel is not None and args.channel != target["channel"]:
            parser.error("Conflicting explicit channel/profile")
        args.test_cc, args.channel = target["controller"], target["channel"]
        if args.expected_identity is not None and args.expected_identity != target["expectedIdentity"]:
            parser.error("Conflicting expected identity/profile")
        args.expected_identity = target["expectedIdentity"]
    args.channel = args.channel if args.channel is not None else 1
    if not 0.2 <= args.wait <= 2 or not 1 <= args.channel <= 16 or not 1 <= args.max_cases <= 48 or not 30 <= args.deadline <= 600:
        parser.error("Invalid response deadline or channel")
    if args.test_cc is not None:
        CC(args.channel, args.test_cc, 0).packed()
        if args.mode != "matrix" or args.test_cc in {0, 6, 32, 38, 96, 97, 98, 99, 100, 101} or args.test_cc >= 120:
            parser.error("Writes require matrix mode and a known ordinary absolute CC encoder")
    elif args.hold_max:
        parser.error("--hold-max requires an explicit --test-cc")
    directory, report, exit_code = session(args)
    summary = {"reportDirectory": str(directory), "hardwareStatus": report["hardwareStatus"], "exitCode": exit_code}
    if args.completion_file:
        write_json(args.completion_file, summary)
    print(json.dumps(summary))
    return exit_code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
