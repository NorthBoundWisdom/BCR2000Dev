# BCR Agent Console Agent Guide

## Project Contract

- This repository provides a native macOS 14+ BCR2000 console plus optional, independent reference robot and Ackermann chassis simulator modules.
- GUI and headless hosts share versioned MCP/HTTP/SSE provider contracts on IPv4 loopback; consumer business logic remains outside this repository.
- Scope and dependency direction are recorded in `docs/adr/0001-provider-domain-boundaries.md`; real actuator connections and public releases remain separately authorized.
- The current product milestone is a SwiftUI/CoreMIDI MVP with a deterministic Mock Agent.
- `BCRFoundation` contains shared value contracts and localization; `BCRSurfaceDomain`, `BCRAgentDomain`, `BCRRobotDomain`, and `BCRChassisDomain` own independent domain state.
- `BCRCodexAdapter`, `BCRCoreMIDIDriver`, persistence, MCP and HTTP/SSE are outer adapters. `BCRProviderApplication` owns explicit composition, not transport or UI.
- `BCRAgentCore` is a source-compatibility export facade only; new domains must not import it. Run `python3 configs/check_domain_boundaries.py` to enforce direction.
- `BCRAgentConsole` is the GUI composition host; `BCRProviderService` is the headless host. Both use the same domain and application services.
- Views render state and emit user intent; they do not own MIDI or Mock business logic.
- Do not guess a user's BCR2000 preset. Keep physical controls behind the persisted Quick Learn profile.
- Port 1 is the preferred BCR2000 control-surface endpoint, with a visible disconnected/error state.

## Code Rules

- Use Swift 6 with strict concurrency and value types across callback boundaries.
- UI-observed state is `@MainActor`; CoreMIDI callbacks perform only packet decoding and hand-off.
- Keep classes `final`, dependencies explicit, and failures visible. Do not add silent fallbacks.
- Any new state transition or MIDI message shape needs a focused unit test.
- Keep secrets, absolute user paths, generated app bundles, MIDI captures, and local mappings out of git.
- Develop and verify only in the `main` working tree: no branches, no `git worktree`, no extra clones
  (unless the user explicitly asks). After each verified change, commit with a Conventional Commit
  message and push to `origin/main`; never force-push `main`.
- The working tree may be shared with other developers/agents: check `git status` first and never
  overwrite, stash, reset, or commit someone else's uncommitted changes without confirming.
- Version tags and releases are created or pushed only when explicitly requested.
- Follow `CONTRIBUTING.md` (conventions, pre-commit checks) and `ROADMAP.md` (phase plan).

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
- See `docs/PACKAGING.md` for local and CI release commands. Do not push version tags or publish
  releases unless asked.
