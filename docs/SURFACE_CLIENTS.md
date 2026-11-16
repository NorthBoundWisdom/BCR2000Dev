# Separate surface operator and display clients (SC-R05)

`--surface-principal-file` persists host-issued identities for the **single owner bearer**, interface and
system sources. It never issues credentials and never identifies two clients sharing the owner credential.
The version-1 format remains unchanged. Hardware profile startup still does not accept this simulation-only
persistence flag; use process-local identities there.

F adds opt-in `--surface-client-tokens-stdin`. A private anonymous pipe supplies one strict JSON object with
exactly `owner`, `operator`, `display`: three distinct 64-character lowercase-hex credentials, at most 512
bytes including whitespace. Duplicate/unknown/missing keys fail startup. EOF terminates provisioning.
Regular files/terminals are refused. Do not use a here-document containing credentials or copy them into
argv, a report or a delivery. The old `--token-stdin` and `BCR_PROVIDER_TOKEN` conflict with this mode.
The old single-token startup behavior remains unchanged.

| Principal | Permitted tool scope | Writer identity |
| --- | --- | --- |
| owner | Existing permissions and legacy API unchanged | existing remote_writer_id; optional version-1 private identity record |
| operator | surface discover/snapshot/events, input/renew | new host-issued opaque process-local ID |
| display | surface discover/snapshot/events, feedback | different host-issued opaque process-local ID |

Secondary `tools/list` returns exactly the role scope in the table (operator: five control tools; display:
four), with the same descriptions and schemas as the owner catalogue. Owner discovery is unchanged.
Secondary credentials cannot reset, call legacy parameter tools, open SSE, or delete sessions. MCP initialize/ping/initialized handshakes remain available for the two supported
protocol versions. Tool-level startup permissions still apply; credentials grant no missing capability.
Hardware operator input and renew remain `permission_denied` / `unsupported_hold`; secondary scope cannot
turn hardware into simulation. The hardware display still needs `write` plus `--allow-surface-feedback`.

All three identities share the same existing aggregate/category budgets and canonical session. Rejected
scope checks consume no write quota. Writer identity comes only from successful server authentication and
is scoped synchronously to a request; callers cannot supply writer_id. Interface and system events retain
their own identities. The two secondary IDs explicitly exclude all legacy IDs. They remain stable in one
process and change at restart, even if the owner's version-1 identity file is reused; consumers must re-pin
instance/epoch. No credential or credential fingerprint enters that identity file.

## Process-owner provisioning example

Use the same orchestration pattern for both hosts; BCR flags below select an isolated simulation session:

```python
import json, os, secrets, subprocess
credentials = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
env = {k: v for k, v in os.environ.items() if k != "BCR_PROVIDER_TOKEN"}
process = subprocess.Popen([
    "<delivery>/BCRProviderService", "--port", "0", "--simulation-profile",
    "--surface-instance-id", "pipe-sim", "--allow-device-control",
    "--allow-surface-input", "--allow-surface-feedback", "--surface-client-tokens-stdin",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
process.stdin.write(json.dumps(credentials).encode())
process.stdin.close()
ready = json.loads(process.stdout.readline())
# Deliver credentials["operator"] and credentials["display"] through each client's private
# IPC channel/in-memory configuration. Do not print, persist or include them in evidence.
# The process owner retains credentials["owner"]. No auto-retry or command replay is added.
```

Using runtime SDK 1.4.0, the two clients then receive the same URL/instance and their individual in-memory
credential. Operator uses `Client.input` / `renew`; display uses `Client.feedback`. The event `writer_id`
values distinguish them. This requires no change to contracts 1.3/1.4 or SDK wire semantics.
Real-process proof: `configs/verify_surface_clients_transport.py`, both MCP protocol versions; concurrent
input/feedback events retain distinct writers, secondary cross-role/legacy/reset calls fail, and an owner
call immediately afterwards retains the original authority.

## Optional independent display request budget

`--display-write-limit N` selects an explicit 1..1000 requests/second budget per authenticated display
writer. It requires `--surface-client-tokens-stdin`. Without the flag, the old aggregate budget and its
60/s default remain exactly unchanged, including any existing `--write-limit` override. Owner/operator
budgets and tool permissions are unchanged. With the flag the display budget does not consume the
owner/operator aggregate; a role credential never grants missing display permission or write policy.
Simulation category flags still govern other writers/categories; the explicit display bucket takes
precedence only for the display credential. BCR hardware legacy quota exhaustion continues to report
`invalid_argument`; simulation reports `rate_limited`. Do not treat arbitrary invalid arguments as quota.

The panel load measurements and recommended rates are in `STATUS_PANEL_BUDGET.md` in the H delivery.
