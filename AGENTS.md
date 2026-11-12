# BCR Agent Console Agent Guide

## Project Contract

- This repository provides a native macOS 14+ BCR2000 console plus optional, independent reference robot and Ackermann chassis simulator modules.
- GUI and headless hosts share versioned MCP/HTTP/SSE provider contracts on IPv4 loopback; consumer business logic remains outside this repository.
- Scope and dependency direction are recorded in `docs/adr/0001-provider-domain-boundaries.md`; real actuator connections and public releases remain separately authorized.
- The current product milestone is a SwiftUI/CoreMIDI MVP with a deterministic Mock Agent.
- `BCRFoundation` contains host value contracts/localization. `BCRSurfaceDomain` owns surface state; `BCRRobotDomain`/`BCRChassisDomain` and `BCRSimulationKernel` are legacy typed facades over shared Robot/Chassis/SimulationContracts values. Host UUID namespaces/opaque grant tokens and legacy error presentation stay outside the shared package. Shared `AgentPlugin` owns Mock Agent state/timing; `BCRAgentDomain` is a compatibility projection (shared state alias, legacy Date/name/Codable/errors), with transition policy delegated to the shared machine.
- `SurfacePlugins` is a separate MIT package, not a clone of this host. Commit an HTTPS remote/full-revision JSON lock; the stdlib/Git manager materializes only committed objects to `build/seed/SurfacePlugins`. `SURFACE_PLUGINS_SOURCE` selects an acquisition source, never a compilation path; legacy `SURFACE_PLUGINS_PATH` is acquisition-only. It has no host/device/localization assumptions. See `docs/SHARED_PLUGINS.md`.
- `BCROutputDomain` and `BCRExamples` are host compatibility/presentation wrappers over shared ParameterOutputPlugin/ExampleParameterSets; no duplicate gate/codec/sample metadata logic. Date APIs, localization, addresses and transports stay in this host.
- `BCRPluginRuntime` owns the one canonical RemoteRegistry, epoch and trusted monotonic clock per host. ProviderApplication, Mock host and OutputController inject the same owner; typed updates commit the value and journal event together. `BCRPluginHost` is only the Agent adapter/driver. Temporary independent PluginRegistry was removed. `BCRConfigurationAdapter` owns old binding translation, legacy feedback API extensions and BCR indicator presentation. Shared MCP tools use each binding's strict schemas and raw object result, while all legacy tools retain their data envelope/errors. Domain control/reset/manual-clock policies apply to both old and new calls; output remote enable is denied by default. Both GUI and headless composition inject neutral bindings; the surface engine stores feedback only by `IndicatorID`.
- Workspace D8 retains `agentPrimaryAction`, `triggerAgent`, `onTriggerAgent` and uninjected legacy fallback for old enum patterns. Production routes generic `triggerAction`. External exhaustive `SurfaceEffect` switches must add the new case; old disk JSON and Provider 1.0 remain unchanged.
- `BCRCodexAdapter`, `BCRCoreMIDIDriver`, persistence, MCP and HTTP/SSE are outer adapters. `BCRProviderApplication` owns explicit composition, not transport or UI.
- `BCRAgentCore` is a source-compatibility export facade only; new domains must not import it. Run `python3 configs/check_domain_boundaries.py` to enforce direction.
- `BCRAgentConsole` is the GUI composition host; `BCRProviderService` is the headless host. Both use the same domain and application services.
- OSC policy uses float32 with exact representable actual seeds; JSON/WebSocket/rosbridge use Double. Production OSC/WS/rosbridge stamp monotonic time at actual IO receipt and use bounded handoff; gate/cadence/RTT consume only that channel once. Date remains audit/fixture compatibility, never a production freshness clock. Invalid host clocks reject ordinary writes; only explicit safety close/fault paths use the last trusted time.
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
- During the authorized shared-plugin integration, the parent workspace D6 overrides automatic pushing: one local commit per task, no push/tag/remote creation. Publishing the planned dependency version remains the user's decision.
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

Use `SURFACE_PLUGINS_SOURCE=../SurfacePlugins` in shell or ignored `build.local.json` while locked commits are unpushed.
Run `python3 configs/surface_plugins_dependency.py ensure` before direct Swift commands; workflow build/test/package/setup
ensure automatically. The manifest only verifies the clean fixed build path and never fetches. For a lock upgrade,
explicit `update` may replace only a manager-owned clean old cache. No source reset/clean and no FreeCM dependency.

```bash
python3 -m compileall -q configs
python3 configs/source_root_workflow.py --help
python3 configs/validate_repo_commands.py .
python3 -m unittest discover -s Tests/BuildWorkflowTests -v
swift test --build-path build/swiftpm  # 单独运行须检查全部测试包，或改用上面的 workflow test
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
