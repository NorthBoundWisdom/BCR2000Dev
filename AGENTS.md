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
python3 configs/source_roots.py status --format json
python3 configs/source_roots.py verify
swift test --build-path build/swiftpm
git diff --check
```

## Owner-Managed FreeCM Policy

- `FreeCM/` is the repository's FreeCM submodule and follows `FreeCM/master`.
- The committed `.gitmodules` URL is the canonical remote. A local URL override is allowed to avoid
  redundant network transfer on the owner's workstation.
- Refresh from the host root with
  `git submodule update --remote --checkout FreeCM`; do not run `git -C FreeCM pull`.
- Only refresh from clean host and submodule worktrees. Validate host commands after any gitlink
  change, and publish only when the user explicitly requests it.
