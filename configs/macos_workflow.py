#!/usr/bin/env python3
"""Build, sign, package and verify the native macOS application."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings  # noqa: E402
from configs.build_environment import use_build_environment  # noqa: E402
from configs.surface_plugins_dependency import ensure_dependency  # noqa: E402
from configs.xctest_worker_results import validate_workers  # noqa: E402

BUILD_ROOT = REPO_ROOT / "build"
SWIFTPM_BUILD_ROOT = BUILD_ROOT / "swiftpm"
APP_BUNDLE = BUILD_ROOT / "app/BCRAgentConsole.app"
PACKAGE_ROOT = BUILD_ROOT / "package"
PRODUCT = "BCRAgentConsole"
BUNDLE_ID = "dev.bcragentconsole.app"
SMOKE_MARKER = '"type":"bcr.native_startup"'


def _run(command: list[str | Path], *, capture: bool = False, cwd: Path = REPO_ROOT, timeout: int | None = None) -> str:
    command = [str(part) for part in command]
    print(">>", " ".join(command), flush=True)
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=capture, timeout=timeout)
    if completed.returncode:
        if capture:
            print(completed.stdout, file=sys.stderr)
            print(completed.stderr, file=sys.stderr)
        raise RuntimeError(f"Command failed ({completed.returncode}): {command[0]}")
    return completed.stdout.strip() if capture else ""


def _case_identifier(name: str) -> str | None:
    """Normalize XCTest's display name to SwiftPM's list/filter selector."""
    objc = re.fullmatch(r"-\[([^ ]+) ([^ ]+)\]", name)
    if objc:
        return objc[1] + "/" + objc[2]
    if "/" in name:
        return name
    owner, dot, method = name.rpartition(".")
    return owner + "/" + method if dot and "." in owner else None


def _selected_suite_summary(output: str) -> dict | None:
    """A filtered old XCTest may have only one complete Selected tests root."""
    starts = list(re.finditer(r"Test Suite 'Selected tests' started\b", output))
    terminals = list(re.finditer(r"Test Suite 'Selected tests' (?:passed|failed)\b", output))
    summaries = list(
        re.finditer(
            r"Test Suite 'Selected tests' (passed|failed)\b[^\n]*\n[ \t]*"
            r"Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?",
            output,
        )
    )
    if len(starts) != 1 or len(terminals) != 1 or len(summaries) != 1:
        return None
    start, summary = starts[0], summaries[0]
    cases = list(re.finditer(r"Test Case '[^']+' (?:started|passed|failed)\b", output))
    if start.end() >= summary.start() or not cases:
        return None
    if any(case.start() < start.end() or case.end() > summary.start() for case in cases):
        return None
    return {
        "status": summary[1],
        "tests": int(summary[2]),
        "failures": int(summary[3]),
        "unexpected": int(summary[4]) if summary[4] is not None else None,
    }


def summarize_tests(
    output: str,
    expected: list[str],
    returncode: int,
    *,
    aggregate_name: str | None = None,
    case_inventory: set[str] | None = None,
    empty_bundles: set[str] | None = None,
    statistics: dict | None = None,
) -> bool:
    """Verify either SwiftPM's per-target bundles or its single package XCTest bundle."""
    bundles = {}
    bundle_starts = set()
    pending = None
    failed_cases = []
    case_starts, case_ends = {}, {}
    case_errors = []
    for line in output.splitlines():
        started = re.search(r"Test Suite '([^']+\.xctest)' started\b", line)
        if started:
            if started[1] in bundle_starts:
                case_errors.append(f"duplicate bundle start: {started[1]}")
            bundle_starts.add(started[1])
        match = re.search(r"Test Suite '([^']+\.xctest)' (passed|failed)\b", line)
        if match:
            pending = match[1]
            if pending in bundles:
                case_errors.append(f"duplicate bundle terminal: {pending}")
            bundles[pending] = {"status": match[2], "tests": None, "failures": None, "unexpected": None}
        elif pending and (
            match := re.search(r"Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?", line)
        ):
            bundles[pending].update(
                tests=int(match[1]),
                failures=int(match[2]),
                unexpected=int(match[3]) if match[3] is not None else None,
            )
            pending = None
        case = re.search(r"Test Case '([^']+)' (started|passed|failed)\b", line)
        if case:
            name, status = case[1], case[2]
            module = re.match(r"-\[([^. ]+)\.", name) or re.match(r"([^. ]+)\.", name)
            module = module[1] if module else None
            if status == "started":
                if name in case_starts:
                    case_errors.append(f"duplicate case start: {name}")
                case_starts[name] = module
            else:
                if name not in case_starts or name in case_ends:
                    case_errors.append(f"missing start or duplicate case terminal: {name}")
                case_ends[name] = status
        if re.search(r"Test Case .* failed\b", line):
            failed_cases.append(line.strip())
    # This compatibility path is forbidden for unfiltered runs: only a discovered exact
    # single-module inventory can authorize a root without a physical bundle name.
    if case_inventory is not None and len(expected) == 1 and not bundles:
        selected = _selected_suite_summary(output)
        if selected is not None:
            aggregate_name = "Selected tests"
            bundles[aggregate_name] = selected
            bundle_starts.add(aggregate_name)
    print("\nSwift test bundle summary:", flush=True)
    success = returncode == 0 and bool(expected) and not failed_cases
    total = failures = 0
    if case_inventory is not None:
        started_ids = {_case_identifier(name) for name in case_starts}
        terminal_ids = {_case_identifier(name) for name in case_ends}
        if (
            not case_inventory
            or started_ids != case_inventory
            or terminal_ids != case_inventory
            or len(started_ids) != len(case_starts)
            or len(terminal_ids) != len(case_ends)
        ):
            print("  FAIL selected module cases do not exactly match the discovered inventory", flush=True)
            success = False
    if aggregate_name and set(bundles) == {aggregate_name}:
        result = bundles[aggregate_name]
        expected_modules = {name.removesuffix(".xctest") for name in expected}
        complete = set(case_starts) == set(case_ends) and bool(case_starts)
        known_modules = set(case_starts.values()) == expected_modules
        counts_match = result["tests"] == len(case_starts) == len(case_ends)
        passed = (
            aggregate_name in bundle_starts
            and complete
            and known_modules
            and counts_match
            and not case_errors
            and all(status == "passed" for status in case_ends.values())
            and result["status"] == "passed"
            and result["failures"] == 0
            and result["unexpected"] == 0
        )
        for module in sorted(expected_modules):
            names = {name for name, owner in case_starts.items() if owner == module}
            terminals = names.intersection(case_ends)
            valid = bool(names) and names == terminals and all(case_ends[name] == "passed" for name in names)
            print(
                f"  {'PASS' if valid else 'FAIL'} {module}: {len(names)} started, {len(terminals)} complete", flush=True
            )
        if not complete or not known_modules or not counts_match:
            print("  FAIL aggregate case coverage/counts are incomplete or inconsistent", flush=True)
        print(
            f"  {'PASS' if passed else 'FAIL'} {aggregate_name}: {result['tests']} tests, "
            f"{result['failures']} failures, {result['unexpected']} unexpected",
            flush=True,
        )
        for error in case_errors:
            print(f"  FAIL {error}", flush=True)
        success = success and passed
        total, failures = result["tests"] or 0, result["failures"] or 0
    else:
        permitted_empty = empty_bundles or set()
        if not set(expected).issubset(bundles) or not set(bundles).issubset(set(expected) | permitted_empty):
            success = False
        if case_starts or case_ends:
            complete = set(case_starts) == set(case_ends)
            counts_match = all(
                sum(owner == name.removesuffix(".xctest") for owner in case_starts.values())
                == (bundles.get(name) or {}).get("tests")
                for name in expected
            )
            if not complete or not counts_match or case_errors:
                print("  FAIL split-bundle case coverage/counts are incomplete or inconsistent", flush=True)
                success = False
        for name in dict.fromkeys([*expected, *bundles]):
            result = bundles.get(name)
            if name in permitted_empty and name not in expected:
                empty = (
                    result is not None
                    and result["status"] == "passed"
                    and result["tests"] == 0
                    and result["failures"] == 0
                    and result["unexpected"] in (None, 0)
                    and not any(owner == name.removesuffix(".xctest") for owner in case_starts.values())
                )
                print(
                    f"  {'PASS' if empty else 'FAIL'} {name}: filtered-out bundle must contain zero cases", flush=True
                )
                success = success and empty
                total += (result or {}).get("tests") or 0
                failures += (result or {}).get("failures") or 0
                continue
            if result is None or result["tests"] is None or result["tests"] == 0:
                print(f"  FAIL {name}: missing complete test results", flush=True)
                success = False
                continue
            passed = result["status"] == "passed" and result["failures"] == 0 and result["unexpected"] in (None, 0)
            print(
                f"  {'PASS' if passed else 'FAIL'} {name}: {result['tests']} tests, {result['failures']} failures",
                flush=True,
            )
            success = success and passed
            total += result["tests"]
            failures += result["failures"]
    for failure in failed_cases:
        print(f"  FAIL {failure}", flush=True)
    print(
        f"Total: {total} tests, {failures} failures; {'PASS' if success else 'FAIL'} (swift exit {returncode})",
        flush=True,
    )
    if statistics is not None:
        statistics.update(
            tests=total,
            failures=failures,
            started=len(case_starts),
            completed=len(case_ends),
            identifiers={_case_identifier(name) for name in case_starts},
        )
    return success


REQUIRED_TEST_MODULES = frozenset(
    {
        "BCRPluginHostTests",
        "BCRAgentCoreTests",
        "BCRAgentConsoleTests",
        "BCRProviderDomainTests",
        "BCRProviderAdapterTests",
    }
)


def _run_tests(command: list[str | Path]) -> None:
    # SwiftPM's single worker launches a fresh XCTest process for every discovered case.
    # Both its synthesized XML and each child's real verbose output must agree with discovery.
    manifest = (REPO_ROOT / "Package.swift").read_text()
    modules = re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', manifest)
    package = re.search(r'\bPackage\(\s*name:\s*"([^"]+)"', manifest)
    aggregate_name = package[1] + "PackageTests.xctest" if package else None
    if not REQUIRED_TEST_MODULES <= set(modules):
        raise RuntimeError("Swift test bundle verification failed: required test module is missing")
    command = [str(part) for part in command]
    runs = REPO_ROOT / "build/test-runs"
    runs.mkdir(parents=True, exist_ok=True)
    artifacts = Path(tempfile.mkdtemp(prefix="run-", dir=runs))
    primary, sidecar = artifacts / "xctest.xml", artifacts / "xctest-swift-testing.xml"
    if any(path.exists() or path.is_symlink() for path in (primary, sidecar)):
        raise RuntimeError("Swift test bundle verification failed: test reports already exist")
    print(f"Test artifacts: {artifacts}", flush=True)
    print(">>", " ".join([*command, "list"]), flush=True)
    discovery = subprocess.run([*command, "list"], cwd=REPO_ROOT, capture_output=True, text=True)
    (artifacts / "inventory.stdout.log").write_text(discovery.stdout)
    (artifacts / "inventory.stderr.log").write_text(discovery.stderr)
    if discovery.stderr:
        print(discovery.stderr, end="", file=sys.stderr, flush=True)
    inventory = {module: set() for module in modules}
    valid = discovery.returncode == 0 and bool(modules) and len(modules) == len(inventory)
    for line in discovery.stdout.splitlines():
        selector = line.strip()
        if not selector:
            continue
        match = re.fullmatch(r"([^.\s/]+)\.[^\s/]+/[^\s]+", selector)
        if not match or match[1] not in inventory or selector in inventory[match[1]]:
            valid = False
        else:
            inventory[match[1]].add(selector)
    if not valid or any(not cases for cases in inventory.values()):
        raise RuntimeError("Swift test bundle verification failed: invalid or incomplete test inventory")
    (artifacts / "inventory.json").write_text(
        json.dumps({name: sorted(cases) for name, cases in inventory.items()}, indent=2) + "\n"
    )
    execution = [
        *command,
        "--skip-build",
        "--parallel",
        "--num-workers",
        "1",
        "--verbose",
        "--xunit-output",
        str(primary),
    ]
    print(">>", " ".join(execution), flush=True)
    output, returncode = [], -1
    started = time.monotonic()
    with (artifacts / "swift-test.log").open("w") as log:
        try:
            with subprocess.Popen(
                execution, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
            ) as process:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                    log.flush()
                    output.append(line)
                returncode = process.wait()
        except Exception as error:
            print(f"FAIL SwiftPM worker driver: {type(error).__name__}", flush=True)
    elapsed = time.monotonic() - started
    (artifacts / "execution.json").write_text(
        json.dumps({"command": execution, "returncode": returncode, "elapsed_s": elapsed}, indent=2) + "\n"
    )
    try:
        result = validate_workers("".join(output), primary, sidecar, inventory, aggregate_name, summarize_tests)
        if returncode != 0:
            raise ValueError(f"SwiftPM worker driver exited {returncode}")
    except (OSError, ValueError) as error:
        print(f"FAIL worker verification: {error}; artifacts: {artifacts}", flush=True)
        raise RuntimeError("Swift test bundle verification failed; inspect worker logs and XML") from error
    result["elapsed_s"] = elapsed
    (artifacts / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print("\nSingle-worker XCTest summary:", flush=True)
    for module in modules:
        print(
            f"  PASS {module}: {len(inventory[module])} complete / {len(inventory[module])} discovered tests",
            flush=True,
        )
    print(
        f"Total: {result['tests']} tests, 0 failures; PASS "
        f"({len(modules)}/{len(modules)} modules, {result['tests']} fresh XCTest processes; {elapsed:.3f}s)",
        flush=True,
    )


def _architectures(architecture: str) -> tuple[str, ...]:
    if architecture == "universal":
        return ("arm64", "x86_64")
    return (platform.machine() if architecture == "native" else architecture,)


def _swift_build(configuration: str, architecture: str) -> Path:
    ensure_dependency(REPO_ROOT)
    binaries = []
    for arch in _architectures(architecture):
        if arch not in {"arm64", "x86_64"}:
            raise ValueError(f"Unsupported macOS architecture: {arch}")
        options = [
            "swift",
            "build",
            "--build-path",
            str(SWIFTPM_BUILD_ROOT / arch),
            "--configuration",
            configuration,
            "--triple",
            f"{arch}-apple-macosx14.0",
        ]
        _run([*options, "--product", PRODUCT])
        binary = Path(_run([*options, "--show-bin-path"], capture=True)) / PRODUCT
        if not binary.is_file():
            raise RuntimeError(f"Built executable not found: {binary}")
        binaries.append(binary)
    if len(binaries) == 1:
        return binaries[0]
    output = SWIFTPM_BUILD_ROOT / "universal" / configuration / PRODUCT
    output.parent.mkdir(parents=True, exist_ok=True)
    _run(["lipo", "-create", *binaries, "-output", output])
    # Resource bundles are architecture-independent, but must also accompany the lipo output.
    localization = binaries[0].parent / "BCRAgentConsole_BCRFoundation.bundle"
    shutil.copytree(localization, output.parent / localization.name, dirs_exist_ok=True)
    return output


def _build_icon() -> Path:
    source = REPO_ROOT / "assets/AppIcon.png"
    if not source.is_file():
        raise ValueError("Missing assets/AppIcon.png")
    iconset = BUILD_ROOT / "icons/AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            suffix = "@2x" if scale == 2 else ""
            _run(
                ["sips", "-z", str(pixels), str(pixels), source, "--out", iconset / f"icon_{size}x{size}{suffix}.png"],
                capture=True,
            )
    output = iconset.parent / "AppIcon.icns"
    _run(["iconutil", "-c", "icns", iconset, "-o", output])
    return output


DISTRIBUTIONS = ("ad-hoc", "development", "developer-id")


def _sign(bundle: Path, distribution: str, identity: str | None, *, hardened: bool = True) -> None:
    if distribution == "ad-hoc":
        command = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    else:
        identity = identity or os.environ.get("BCR_SIGNING_IDENTITY", "")
        prefix = "Developer ID Application:" if distribution == "developer-id" else "Apple Development:"
        identities = _run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
        matches = []
        for line in identities.splitlines():
            parts = line.strip().split('"')
            if len(parts) >= 3 and parts[1].startswith(prefix):
                sha = parts[0].split()[-1]
                if not identity or identity in (sha, parts[1]):
                    matches.append(sha)
        if len(matches) != 1:
            raise ValueError(f"Select exactly one {prefix} identity with --identity or BCR_SIGNING_IDENTITY.")
        command = [
            "codesign",
            "--force",
            "--sign",
            matches[0],
            *(["--options", "runtime"] if hardened else []),
            "--timestamp" if distribution == "developer-id" else "--timestamp=none",
        ]
    # The companion builder signs its nested driver first. Sign this payload/container explicitly.
    _run([*command, bundle])
    _run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle])


def build(
    configuration: str, architecture: str = "native", distribution: str = "ad-hoc", identity: str | None = None
) -> Path:
    settings = load_app_build_settings()
    executable = _swift_build(configuration, architecture)
    icon = _build_icon()
    if APP_BUNDLE.exists():
        shutil.rmtree(APP_BUNDLE)
    macos = APP_BUNDLE / "Contents/MacOS"
    resources = APP_BUNDLE / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(executable, macos / PRODUCT)
    (macos / PRODUCT).chmod(0o755)
    shutil.copy2(icon, resources / "AppIcon.icns")
    localization = executable.parent / "BCRAgentConsole_BCRFoundation.bundle"
    if not localization.is_dir():
        raise ValueError("SwiftPM localization resource bundle is missing.")
    shutil.copytree(localization, resources / localization.name)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["en", "zh-Hans"],
        "CFBundleDisplayName": "BCR Agent Console",
        "CFBundleExecutable": PRODUCT,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "BCR Agent Console",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": settings["MARKETING_VERSION"],
        "CFBundleVersion": settings["ARCHIVE_ID"],
        "CFBundleIconFile": "AppIcon.icns",
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        "BCRDistribution": distribution,
    }
    (APP_BUNDLE / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    (APP_BUNDLE / "Contents/PkgInfo").write_text("APPL????", encoding="ascii")
    _sign(APP_BUNDLE, distribution, identity)
    verify_bundle(APP_BUNDLE)
    print(f"Built {APP_BUNDLE.relative_to(REPO_ROOT)}")
    return APP_BUNDLE


def verify_bundle(bundle: Path) -> dict:
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if (
        info.get("CFBundleIdentifier") != BUNDLE_ID
        or info.get("CFBundleExecutable") != PRODUCT
        or info.get("CFBundleIconFile") != "AppIcon.icns"
        or info.get("LSMinimumSystemVersion") != "14.0"
    ):
        raise ValueError("Unexpected app bundle metadata.")
    if not (bundle / "Contents/Resources/AppIcon.icns").is_file():
        raise ValueError("Packaged application icon is missing.")
    if info.get("CFBundleLocalizations") != ["en", "zh-Hans"]:
        raise ValueError("Application language metadata is missing.")
    localization = bundle / "Contents/Resources/BCRAgentConsole_BCRFoundation.bundle"
    for language in ("en", "zh-Hans"):
        candidates = [localization / "Contents/Resources", localization]
        if not any(
            catalog.parent.name.casefold() == f"{language}.lproj".casefold()
            for root in candidates
            for catalog in root.glob("*.lproj/Localizable.strings")
            if catalog.is_file()
        ):
            raise ValueError(f"Bundled {language} translations are missing.")
    executable = bundle / "Contents/MacOS" / PRODUCT
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Packaged executable is missing or not executable.")
    _run(["codesign", "--verify", "--deep", "--strict", bundle])
    # Reject dependencies that would work only on the build machine.
    dependencies = _run(["otool", "-L", executable], capture=True)
    for line in dependencies.splitlines():
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/System/Library/", "/usr/lib/")):
            raise ValueError(f"Non-system runtime dependency requires deployment: {dependency}")
    return info


def smoke_runs_in_foreground() -> bool:
    """Hosted CI keeps the launch it has always used; local runs stay off the desktop by default."""
    return bool(os.environ.get("CI")) or os.environ.get("BCR_FOREGROUND_TESTS") == "1"


def smoke(bundle: Path, foreground: bool | None = None) -> None:
    info = verify_bundle(bundle)
    bundle = bundle.resolve()
    foreground = smoke_runs_in_foreground() if foreground is None else foreground
    for language, settings_title in (("en", "Settings"), ("zh-Hans", "设置")):
        with tempfile.TemporaryDirectory(prefix="bcr-startup-") as temporary:
            # Launch Services supplies normal GUI activation on hosted macOS runners.
            # -n isolates each language probe; -W waits for its startup check to exit.
            # Offscreen (the local default): -g keeps the app in the background and --offscreen makes it
            # an accessory app whose window is transparent and parked outside every screen.
            # Argument-domain language overrides never modify user preferences.
            stdout = Path(temporary) / "stdout.log"
            stderr = Path(temporary) / "stderr.log"
            result = subprocess.run(
                [
                    "open",
                    "-n",
                    "-W",
                    *([] if foreground else ["-g"]),
                    "--stdout",
                    str(stdout),
                    "--stderr",
                    str(stderr),
                    str(bundle),
                    "--args",
                    "--startup-smoke",
                    *([] if foreground else ["--offscreen"]),
                    "-AppleLanguages",
                    f"({language})",
                ],
                cwd=temporary,
                text=True,
                capture_output=True,
                timeout=40,
            )
            output = stdout.read_text() if stdout.exists() else ""
            errors = stderr.read_text() if stderr.exists() else ""
        # open can succeed even when the app exits with an error; require its success marker.
        if result.returncode or SMOKE_MARKER not in output:
            raise RuntimeError(
                f"Native window startup failed ({result.returncode}):\n{output}\n{errors}\n{result.stderr}"
            )
        marker = next(json.loads(line) for line in output.splitlines() if SMOKE_MARKER in line)
        if marker.get("clientVersion") != info["CFBundleShortVersionString"]:
            raise RuntimeError("Native client version does not match the packaged app metadata.")
        if marker.get("language") != language or marker.get("settings") != settings_title:
            raise RuntimeError(f"Bundled {language} localization did not resolve correctly: {marker}")
    mode = "foreground" if foreground else "offscreen"
    print(f"Verified English and Chinese native startup at 1200 × 760 ({mode}) with bundled icon and translations.")


def _zip(bundle: Path, destination: Path, companion: Path | None = None) -> None:
    if destination.exists():
        destination.unlink()
    if companion:
        with tempfile.TemporaryDirectory(dir=BUILD_ROOT, prefix="zip-layout-") as temporary:
            layout = Path(temporary)
            shutil.copytree(bundle, layout / bundle.name, symlinks=True)
            shutil.copytree(companion, layout / companion.name, symlinks=True)
            _run(["ditto", "-c", "-k", "--sequesterRsrc", layout, destination])
        return
    _run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, destination])


def _dmg(bundle: Path, destination: Path, companion: Path | None = None) -> None:
    stage = BUILD_ROOT / "package-staging"
    stage.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=stage, prefix="dmg-") as temporary:
        layout = Path(temporary)
        shutil.copytree(bundle, layout / bundle.name, symlinks=True)
        if companion:
            shutil.copytree(companion, layout / companion.name, symlinks=True)
        (layout / "Applications").symlink_to("/Applications")
        _run(
            [
                "hdiutil",
                "create",
                "-volname",
                "BCR Agent Console",
                "-srcfolder",
                layout,
                "-ov",
                "-format",
                "UDZO",
                destination,
            ]
        )


def _notarize(archive: Path, profile: str) -> None:
    keychain = os.environ.get("BCR_NOTARY_KEYCHAIN")
    result = json.loads(
        _run(
            [
                "xcrun",
                "notarytool",
                "submit",
                archive,
                "--keychain-profile",
                profile,
                *(["--keychain", keychain] if keychain else []),
                "--wait",
                "--output-format",
                "json",
            ],
            capture=True,
        )
    )
    if result.get("status") != "Accepted":
        raise RuntimeError(f"Notarization failed: {result}")


def _staple(target: Path) -> None:
    _run(["xcrun", "stapler", "staple", target])
    _run(["xcrun", "stapler", "validate", target])


def _sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _write_records(assets: list[Path], architecture: str, distribution: str, driverkit: dict | None = None) -> None:
    settings = load_app_build_settings()
    commit = _run(["git", "rev-parse", "HEAD"], capture=True)
    dirty = bool(_run(["git", "status", "--porcelain"], capture=True))
    swift = _run(["swift", "--version"], capture=True)
    checksums = []
    for asset in assets:
        checksum = _sha(asset)
        record = {
            "schema_version": 1,
            "asset": asset.name,
            "sha256": checksum,
            "version": settings["MARKETING_VERSION"],
            "build": settings["ARCHIVE_ID"],
            "commit": commit,
            "dirty": dirty,
            "architecture": architecture,
            "signature": distribution,
            "notarized": distribution == "developer-id",
            "minimum_macos": "14.0",
            "swift": swift,
        }
        if driverkit:
            record["driverkit"] = {**driverkit, "notarized": True}
        asset.with_suffix(asset.suffix + ".build.json").write_text(json.dumps(record, indent=2) + "\n")
        checksums.append(f"{checksum}  {asset.name}")
    # Per-build checksums avoid accidentally publishing artifacts left by a previous version.
    checksum_name = assets[0].name.rsplit(".", 1)[0] + ".SHA256SUMS"
    (PACKAGE_ROOT / checksum_name).write_text("\n".join(checksums) + "\n")


def package(
    architecture: str = "native",
    distribution: str = "ad-hoc",
    identity: str | None = None,
    notary_profile: str | None = None,
    package_format: str = "both",
    driverkit_host: Path | None = None,
) -> list[Path]:
    profile = notary_profile or os.environ.get("BCR_NOTARY_KEYCHAIN_PROFILE", "")
    if distribution == "developer-id" and (not profile or any(c in profile for c in "\r\n\0")):
        raise ValueError("Developer ID packaging requires --notary-profile or BCR_NOTARY_KEYCHAIN_PROFILE.")
    settings = load_app_build_settings()
    companion = None
    driverkit = None
    if driverkit_host:
        if distribution != "developer-id" or architecture != "universal":
            raise ValueError("A DriverKit release requires universal Developer ID packaging")
        from configs.driverkit_release import HOST_PRODUCT, verify_companion

        driverkit = verify_companion(driverkit_host, settings["MARKETING_VERSION"], settings["ARCHIVE_ID"])
    bundle = build("release", architecture, distribution, identity)
    if driverkit_host:
        companion = bundle.parent / (HOST_PRODUCT + ".app")
        if companion.resolve() == driverkit_host.resolve():
            raise ValueError("Compatibility input must be outside the packaging staging directory")
        if companion.exists():
            shutil.rmtree(companion)
        shutil.copytree(driverkit_host, companion, symlinks=True)
    if platform.machine() in _architectures(architecture):
        smoke(bundle)
    PACKAGE_ROOT.mkdir(parents=True, exist_ok=True)
    arch = "universal" if architecture == "universal" else _architectures(architecture)[0]
    stem = f"{PRODUCT}_v{settings['MARKETING_VERSION']}_{settings['ARCHIVE_ID']}_macOS_{arch}_{distribution}"
    if distribution == "developer-id":
        # Notarize/staple the app first so both ZIP and DMG contain an offline-verifiable app.
        with tempfile.TemporaryDirectory(dir=BUILD_ROOT, prefix="notary-") as temporary:
            submission = Path(temporary) / "submission.zip"
            _zip(bundle, submission, companion)
            _notarize(submission, profile)
        _staple(bundle)
        _run(["spctl", "--assess", "--type", "execute", "--verbose=2", bundle])
        if companion:
            _staple(companion)
            _run(["spctl", "--assess", "--type", "execute", "--verbose=2", companion])
    assets = []
    if package_format in {"zip", "both"}:
        archive = PACKAGE_ROOT / f"{stem}.zip"
        _zip(bundle, archive, companion)
        assets.append(archive)
    if package_format in {"dmg", "both"}:
        archive = PACKAGE_ROOT / f"{stem}.dmg"
        _dmg(bundle, archive, companion)
        if distribution == "developer-id":
            _sign(archive, distribution, identity, hardened=False)
            _notarize(archive, profile)
            _staple(archive)
            _run(
                [
                    "spctl",
                    "--assess",
                    "--type",
                    "open",
                    "--context",
                    "context:primary-signature",
                    "--verbose=2",
                    archive,
                ]
            )
        assets.append(archive)
    _write_records(assets, arch, distribution, driverkit)
    for asset in assets:
        print(f"Packaged {asset.relative_to(REPO_ROOT)}")
    return assets


def check_package(archive: Path) -> None:
    archive = archive.resolve()
    proof = json.loads(archive.with_suffix(archive.suffix + ".build.json").read_text())
    if proof.get("asset") != archive.name or proof.get("sha256") != _sha(archive):
        raise ValueError("Release artifact hash/provenance mismatch.")
    with tempfile.TemporaryDirectory(prefix="bcr-package-") as temporary:
        root = Path(temporary)
        if archive.suffix == ".zip":
            _run(["ditto", "-x", "-k", archive, root])
            bundle = root / f"{PRODUCT}.app"
            _check_payload(bundle, proof)
            _check_companion(root, proof)
        elif archive.suffix == ".dmg":
            if proof.get("notarized"):
                _run(["codesign", "--verify", "--strict", archive])
                _run(["xcrun", "stapler", "validate", archive])
                _run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", archive])
            mount = root / "mounted"
            _run(["hdiutil", "attach", archive, "-readonly", "-nobrowse", "-mountpoint", mount])
            try:
                if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
                    raise ValueError("Installer is missing the Applications shortcut.")
                bundle = root / f"{PRODUCT}.app"
                _run(["ditto", mount / f"{PRODUCT}.app", bundle])
                _check_payload(bundle, proof)
                _check_companion(mount, proof)
            finally:
                _run(["hdiutil", "detach", mount])
        else:
            raise ValueError("Expected a ZIP or DMG package.")
    print(f"Verified package: {archive.name}")


def _check_companion(root: Path, proof: dict) -> None:
    from configs.driverkit_release import HOST_PRODUCT, verify_companion

    companion = root / (HOST_PRODUCT + ".app")
    if proof.get("driverkit"):
        metadata = verify_companion(companion, proof["version"], proof["build"])
        if proof["driverkit"] != {**metadata, "notarized": True}:
            raise ValueError("Compatibility companion differs from release record")
        _run(["xcrun", "stapler", "validate", companion])
        _run(["spctl", "--assess", "--type", "execute", companion])
        result = _run([companion / "Contents/MacOS/BCRDriverKitProbe", "--startup-smoke"], capture=True, timeout=40)
        if (
            '"type":"bcr.usb_compatibility_startup"' not in result
            or '"hardwareAccessed":false' not in result
            or '"labMode":false' not in result
        ):
            raise RuntimeError("Compatibility companion native startup failed")
    elif companion.exists():
        raise ValueError("Unexpected compatibility companion without a release record")


def _check_payload(bundle: Path, proof: dict) -> None:
    info = verify_bundle(bundle)
    if (
        info["CFBundleShortVersionString"] != proof["version"]
        or info["CFBundleVersion"] != proof["build"]
        or info["BCRDistribution"] != proof["signature"]
    ):
        raise ValueError("Package metadata differs from build record.")
    archs = _run(["lipo", "-archs", bundle / "Contents/MacOS" / PRODUCT], capture=True).split()
    if set(archs) != set(_architectures(proof["architecture"])):
        raise ValueError("Packaged executable architectures differ from build record.")
    if proof.get("notarized"):
        from configs.driverkit_release import verify_developer_id

        verify_developer_id(bundle)
        _run(["xcrun", "stapler", "validate", bundle])
        _run(["spctl", "--assess", "--type", "execute", bundle])
    if platform.machine() in archs:
        smoke(bundle)
    else:
        print(f"Startup requires a {', '.join(archs)} host; structural verification passed.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "test", "run", "package", "smoke", "check-package"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--architecture", choices=("native", "arm64", "x86_64", "universal"), default="native")
    parser.add_argument(
        "--distribution",
        choices=DISTRIBUTIONS,
        help="Signing mode; otherwise BCR_DISTRIBUTION from build.local.json, else ad-hoc.",
    )
    parser.add_argument("--identity", help="Signing certificate name or SHA-1; otherwise BCR_SIGNING_IDENTITY.")
    parser.add_argument("--notary-profile", help="notarytool Keychain profile; otherwise BCR_NOTARY_KEYCHAIN_PROFILE.")
    parser.add_argument("--format", choices=("zip", "dmg", "both"), default="both")
    parser.add_argument("--bundle", type=Path, default=APP_BUNDLE, help="Bundle for the smoke action.")
    parser.add_argument(
        "--foreground",
        action="store_true",
        help="smoke: show and activate the window (default locally is offscreen; CI is always foreground).",
    )
    parser.add_argument("--archive", type=Path, help="ZIP/DMG for check-package (with .build.json sidecar).")
    parser.add_argument("--driverkit-host", type=Path, help="Approved Developer ID compatibility companion to include.")
    args = parser.parse_args(argv)
    with use_build_environment(REPO_ROOT):
        if args.distribution is None:
            # A stable local identity keeps Keychain grants valid across rebuilds; CI passes ad-hoc explicitly.
            args.distribution = os.environ.get("BCR_DISTRIBUTION") or "ad-hoc"
            if args.distribution not in DISTRIBUTIONS:
                parser.error(f"BCR_DISTRIBUTION must be one of {', '.join(DISTRIBUTIONS)}")
        if sys.platform != "darwin":
            parser.error("This workflow requires macOS and Xcode's Swift 6 toolchain.")
        if args.action == "test":
            ensure_dependency(REPO_ROOT)
            _run_tests(["swift", "test", "--build-path", SWIFTPM_BUILD_ROOT])
        elif args.action == "package":
            package(
                args.architecture,
                args.distribution,
                args.identity,
                args.notary_profile,
                args.format,
                args.driverkit_host,
            )
        elif args.action == "smoke":
            smoke(args.bundle, True if args.foreground else None)
        elif args.action == "check-package":
            if args.archive is None:
                parser.error("check-package requires --archive")
            check_package(args.archive)
        else:
            bundle = build(args.configuration, args.architecture, args.distribution, args.identity)
            if args.action == "run":
                _run([bundle / "Contents/MacOS" / PRODUCT])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
