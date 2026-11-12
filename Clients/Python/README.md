# Provider Python SDK 1.0.0

Pure Python 3.11+ standard library. The published `bcr-provider-sdk-1.0.0.zip` can be placed directly on
`PYTHONPATH`, or its `bcr_provider` package can be unpacked into a consumer environment. No repository
path, app internals, GUI control or third-party Python packages are required.

`Client(url, token, expected_provider_id=...)` accepts only an explicit numeric-loopback `/mcp` URL and never follows redirects
or ambient proxies. Supply credentials through local environment/secure process input, never argv.
Use `discover()`, `tools()`, `call(name, arguments)` and `events(channel)` for the public contract.
The client never retries a command or automatically replays inputs after reconnecting. The caller
must reconcile the device snapshot, generation and last accepted command sequence after uncertainty.
Pin the startup-unique `provider_id` from the owner's `provider.ready` record. Every RPC and SSE request
uses `BCR-Provider-Id`; a different process on the same port is rejected, and a missing/mismatched response
identity fails closed. No automatic rebinding occurs after a process restart. An unpinned client is
retained only for legacy compatibility and is unsuitable for device control that relies on instance identity.

SSE channels are `parameters`, `console`, and (when provided by the host) `devices`. A reset snapshot
is state, not a new physical command. Observe generation, sequence, source and ignored/accepted flags;
do not infer a human approval from a parameter or event source label. Blocking for a quiet stream
uses a heartbeat timeout, independently of the freshness of an individual input or motion command.

Published API and models are documented by `PROVIDER_API.md` and `provider.schema.json` in the release.
Examples use only this SDK and `BCR_PROVIDER_URL` / `BCR_PROVIDER_TOKEN` / `BCR_PROVIDER_ID`.

## Optional Surface control SDK

The generic `surface_control` SDK (1.1.0) is not maintained in this repository. Its only source is the
locked SurfacePlugins package (`clients/python/surface_control/`, materialized at
`build/seed/SurfacePlugins`), which also holds its unit tests and the Pipe integration example. The
provider delivery ships it unchanged as `surface-control-sdk-1.1.0.zip`, with its file hash and
shared revision recorded in `manifest.json`. To pin this provider's identity, pass both
`provider_id` and `provider_header="BCR-Provider-Id"` to `surface_control.Client`. See
`docs/SURFACE_SIMULATION.md`. This Provider SDK (`bcr_provider` 1.0.0) is unchanged.
