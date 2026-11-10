#!/usr/bin/env python3
"""Import explicitly supplied release secrets into an ephemeral CI keychain.

Never exports a local identity, creates API keys, or uploads secrets. Commands
containing credentials are intentionally not logged. Cleanup restores only the
search list changed by this script and removes only its own temporary files.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import hashlib
import uuid


REQUIRED = (
    "BCR_SIGNING_P12_BASE64",
    "BCR_SIGNING_P12_PASSWORD",
    "BCR_DRIVERKIT_HOST_PROFILE_BASE64",
    "BCR_DRIVERKIT_PROFILE_BASE64",
    "BCR_NOTARY_KEY_P8_BASE64",
    "BCR_NOTARY_KEY_ID",
    "BCR_NOTARY_ISSUER_ID",
)


def require_secrets(environment):
    missing = [key for key in REQUIRED if not environment.get(key)]
    if missing:
        raise ValueError("Missing release secrets: " + ", ".join(missing))


def silent(argv):
    result = subprocess.run([str(v) for v in argv], capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"Release credential operation failed: {Path(str(argv[0])).name} ({result.returncode})")
    return result.stdout.decode().strip()


def private_file(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)


def decode_secret(value):
    return base64.b64decode("".join(value.split()), validate=True)


def setup():
    require_secrets(os.environ)
    if not os.environ.get("RUNNER_TEMP") or not os.environ.get("GITHUB_ENV"):
        raise ValueError("Signing setup requires an explicit CI runner context")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve()
    state_path = runner / "bcr-signing-state.json"
    if state_path.exists():
        raise ValueError("Existing signing session; cleanup before starting another")
    directory = Path(tempfile.mkdtemp(prefix="bcr-signing-", dir=runner))
    keychain = directory / "release.keychain-db"
    state = {
        "directory": str(directory),
        "keychain": str(keychain),
        "searchList": shlex.split(silent(["security", "list-keychains", "-d", "user"])),
    }
    private_file(state_path, (json.dumps(state) + "\n").encode())
    try:
        files = {}
        for name, variable in (
            ("identity.p12", "BCR_SIGNING_P12_BASE64"),
            ("host.provisionprofile", "BCR_DRIVERKIT_HOST_PROFILE_BASE64"),
            ("driver.provisionprofile", "BCR_DRIVERKIT_PROFILE_BASE64"),
            ("notary.p8", "BCR_NOTARY_KEY_P8_BASE64"),
        ):
            path = directory / name
            private_file(path, decode_secret(os.environ[variable]))
            files[name] = path
        password = secrets.token_urlsafe(32)
        silent(["security", "create-keychain", "-p", password, keychain])
        silent(["security", "set-keychain-settings", "-lut", "21600", keychain])
        silent(["security", "unlock-keychain", "-p", password, keychain])
        silent(
            [
                "security",
                "import",
                files["identity.p12"],
                "-k",
                keychain,
                "-P",
                os.environ["BCR_SIGNING_P12_PASSWORD"],
                "-T",
                "/usr/bin/codesign",
            ]
        )
        silent(
            ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain]
        )
        silent(["security", "list-keychains", "-d", "user", "-s", keychain, *state["searchList"]])
        identities = silent(["security", "find-identity", "-v", "-p", "codesigning", keychain])
        matches = [
            line.strip().split('"')[0].split()[-1]
            for line in identities.splitlines()
            if '"Developer ID Application:' in line
        ]
        if len(matches) != 1:
            raise ValueError("The imported keychain must contain exactly one Developer ID Application identity")
        profile = "bcr-ci-" + secrets.token_hex(8)
        silent(
            [
                "xcrun",
                "notarytool",
                "store-credentials",
                profile,
                "--keychain",
                keychain,
                "--key",
                files["notary.p8"],
                "--key-id",
                os.environ["BCR_NOTARY_KEY_ID"],
                "--issuer",
                os.environ["BCR_NOTARY_ISSUER_ID"],
            ]
        )
        values = {
            "BCR_SIGNING_IDENTITY": matches[0],
            "BCR_NOTARY_KEYCHAIN_PROFILE": profile,
            "BCR_NOTARY_KEYCHAIN": str(keychain),
            "BCR_DRIVERKIT_HOST_PROFILE": str(files["host.provisionprofile"]),
            "BCR_DRIVERKIT_PROFILE": str(files["driver.provisionprofile"]),
        }
        with Path(os.environ["GITHUB_ENV"]).open("a") as stream:
            for key, value in values.items():
                if any(c in value for c in "\n\r\0"):
                    raise ValueError("Invalid CI environment value")
                stream.write(f"{key}={value}\n")
        print("Ephemeral signing identity and notarization credentials configured.")
    except BaseException:
        cleanup()
        raise


def cleanup():
    runner = Path(os.environ["RUNNER_TEMP"]).resolve()
    path = runner / "bcr-signing-state.json"
    if not path.exists():
        return
    state = json.loads(path.read_text())
    directory = Path(state["directory"])
    if directory.is_symlink() or directory.parent != runner or not directory.name.startswith("bcr-signing-"):
        raise ValueError("Refusing cleanup outside this signing session")
    silent(["security", "list-keychains", "-d", "user", "-s", *state["searchList"]])
    if Path(state["keychain"]) != directory / "release.keychain-db":
        raise ValueError("Unexpected keychain path")
    if Path(state["keychain"]).exists():
        silent(["security", "delete-keychain", state["keychain"]])
    profile_root = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    for item in state.get("installedProfiles", []):
        profile = Path(item["path"])
        if profile.parent != profile_root or profile.is_symlink() or profile.suffix != ".provisionprofile":
            raise ValueError("Unexpected installed profile path")
        uuid.UUID(profile.stem)
        if profile.exists():
            if hashlib.sha256(profile.read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError("Installed profile changed; refusing removal")
            profile.unlink()
    shutil.rmtree(directory)
    path.unlink()
    print("Ephemeral release credentials removed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "setup", "cleanup"])
    args = parser.parse_args()
    try:
        if args.action == "check":
            require_secrets(os.environ)
            print("All required release secret names are populated.")
        elif args.action == "setup":
            setup()
        else:
            cleanup()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
