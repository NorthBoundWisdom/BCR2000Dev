"""Private SwiftPM discovery/build-location fixture; execution always uses native batches."""

import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent
arguments = sys.argv[1:]
with (root / "fake-calls.jsonl").open("a") as calls:
    calls.write(json.dumps([Path(__file__).name, *arguments]) + "\n")
if Path(__file__).name == "xcrun" and arguments == ["--find", "xctest"]:
    print(root / "native-xctest")
elif arguments[0] == "test" and arguments[-1] == "list":
    print("\n".join(json.loads((root / "fixture.json").read_text())["cases"]))
elif arguments[0] == "build" and arguments[-1] == "--show-bin-path":
    print(root)
else:
    raise SystemExit("Unsupported fixture invocation")
