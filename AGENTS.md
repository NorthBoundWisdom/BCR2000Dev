# BCR Agent Console Agent Guide

## Project Contract

- This is a native macOS 14+ controller app for a Behringer BCR2000.
- The current product milestone is a SwiftUI/CoreMIDI MVP with a deterministic Mock Agent.
- `BCRAgentCore` owns domain state, MIDI value types, mapping, and testable state transitions.
- `BCRAgentConsole` owns SwiftUI, CoreMIDI object lifetimes, persistence, and dependency wiring.
- Views render state and emit user intent; they do not own MIDI or Mock business logic.
- Do not guess a user's BCR2000 preset. Keep physical controls behind the persisted Quick Learn profile.
- Port 1 is the preferred BCR2000 control-surface endpoint, with a visible disconnected/error state.

## Code Rules

- Use Swift 6 with strict concurrency and value types across callback boundaries.
- UI-observed state is `@MainActor`; CoreMIDI callbacks perform only packet decoding and hand-off.
- Keep classes `final`, dependencies explicit, and failures visible. Do not add silent fallbacks.
- Any new state transition or MIDI message shape needs a focused unit test.
- Keep secrets, absolute user paths, generated app bundles, MIDI captures, and local mappings out of git.
- Work on `main` unless the user explicitly requests a branch. Do not commit or publish unless asked.

## Development Commands

```bash
python3 configs/setup_local_project.py
python3 configs/macos_workflow.py build
python3 configs/macos_workflow.py test
python3 configs/macos_workflow.py run
```

Focused checks:

```bash
python3 -m compileall -q configs
python3 configs/source_root_workflow.py --help
python3 configs/validate_repo_commands.py .
python3 -m unittest discover -s Tests/BuildWorkflowTests -v
swift test --build-path build/swiftpm
git diff --check
```

## Build Configuration and FreeCM Plugin

- FreeCM is not a submodule or build dependency. Do not restore checkout or refresh behavior.
- Preserve optional Config/Build/Run/Test/Package wiring in `configs/freecm.commands.jsonc`.
  `configs/source_root_workflow.py` is only a setup/cleanup adapter, without dependency locks.
- Only the MIT-licensed command validator is vendored under `configs/_vendor/`, with provenance.
- Version defaults live in `configs/app_build.json`; ignored `build.local.json` holds local
  environment/PATH and signing overrides. Setup creates it only when missing.
- Packaging uses `configs/macos_workflow.py`: signed `.app`, ZIP/DMG, checksums and build records.
  Developer ID packaging must require successful notarization, stapling and Gatekeeper checks.
- Keep credentials in Keychain/local environment. CI defaults to ad-hoc signing, tests final
  universal packages on ARM and Intel runners, and publishes only explicitly pushed version tags.
- See `docs/PACKAGING.md` for local and CI release commands. Do not commit or publish unless asked.
