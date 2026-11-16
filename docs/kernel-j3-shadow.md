# J3 runtime shadow

The native reference is `36692f1422b0c3952f9048847a0bafd65421bc72`. This includes the separately reviewed
connection-publication safety fix. The local managed Kit dependency is
`545ba46c3cb5298663c3dd12e53604a5a68da7a0`. The BCR runtime has switched this block to Kit. Original algorithms are retained only in Tests;
see [the exact reference mapping](../Tests/J3Support/ORACLE_MAPPING.md).

| Actual operation | Kit runtime | Native knowledge retained |
| --- | --- | --- |
| `SurfaceConfiguration.assignment(for:)` ordered first match | `ControlBinding` / `BindingContext.targetForControl` returns the original configuration's opaque entry offset | Physical role/logical facet projection; the sole action/parameter payload stays in native configuration |
| `SurfaceSession.handleConnection` route/status/generation facts | `BCRConnectionRuntime` owns published snapshot/generation and advances a temporary `ConnectionState` | Selected endpoint names and optional origin; notification publication ownership, GUI confirmation and device effects |
| Parameter/authority/display/transport completion and failed queue requeue scope | `ContextScope.matches` on stable source, input epoch, binding revision and optional endpoint | Default nil authorization, identity permissions, actual-value validation, private display receipt and canonical completion |
| `FeedbackScheduler` enqueue/cancel/drain/clear identity order | `ContextResourceIndex` starts empty and receives each real operation, retaining its own ordered IDs and complete optional scope | The sole MIDI payload dictionary, token bucket, timing/cooldown and physical clear/drain boundaries |

Connection generation advances before synchronous journal/queue observers; the runtime publishes its route only
at the original native snapshot publication point. An obsolete callback never assigns a whole candidate afterward.
Binding facets and observed physical contexts are not input lifecycle identity. BCR echo/absolute/increment/trigger
cache algorithms stay native; their exact IDs are recorded before transitions and after publication.

The configuration-level API declares no input kind. `SurfaceConfiguration` owns one immutable derived control
index for its active assignment array. Base assignments, page storage and active-page changes rebuild that value;
ordinary getters reuse it, and parameter presentation metadata does not change it. It contains only role/facet to
native offset references. Value copies replace their own index, with no global cache, payload copy or unsafe pointer.
The original eight-field equality and explicit Codable shape/version exclude this cache and its diagnostic build
count. Tests cover repeated reads, mutation rollback, pages, macro/parameter removal, copies and decoding.

`macos_workflow.py test` automatically enables a fresh actual-result trace for its native test processes and then
runs the Tests-only 366 legacy oracle as a mandatory success gate, including CI. The product's Debug tap remains off
outside that explicit testing environment. Any legacy difference, missing core coverage or reused/empty evidence fails
the workflow. Scope fields, unknown provenance and queue ordering remain exact. No production old algorithm or
native/candidate comparison remains. The negative-gate test's independent children retain deliberate mismatches under
`expected-negative/`; those are separate from the ordinary actual Kit operation inventory.

Each process writes JSONL with contiguous sequence numbers. Repeated immutable binding tables are registered as
`record_kind=catalogue` records containing their complete original values. Later `$catalogue` references resolve
within that file. Registration uses exact content equality; the Tests-only oracle reconstructs all values before comparing actual results and never compares hashes or
catalogue aliases. Raw control identities contain section/row/index;
raw MIDI identities contain kind/channel/number. Every native endpoint, scope field and connection snapshot is retained.

`Tests/J3Support/verify_runtime_shadow.py <operation-directory> --output <proof.json>` independently replays the
native first-match, route/status/generation, ordered-index and exact-scope algorithms from those actual inputs. Its
state starts at explicit initialization, not at native/candidate result IDs. It verifies all reconstructed results,
including removed IDs and full optional scope, against the actual Kit result. The older dual shadow format remains
readable for the preserved pre-cut evidence. The older J2 native/typed owner comparison remains
separate and continues to cover complete observations, feedback and ordered transmission traces.

No device transaction, preset, learned map, motor policy or physical qualification changes here. Same-target receipt
supersession and cross-epoch `delivery_failed` remain in their canonical native owner. Kit has no business value copy.
