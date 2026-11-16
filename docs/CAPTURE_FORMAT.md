# Capture JSONL v1 interchange

The X-Touch v1 names/types are the common baseline. UTF-8 JSON objects are LF-terminated, without an array wrapper. Keys are unordered; the recorder emits sorted keys. A truncated final line is evidence of an incomplete file, never an executable row.

## Common envelope and fields

| Record | Fields / meaning |
| --- | --- |
| `capture-start` | First/unique. Integer `schemaVersion=1`, object `session`, audit `timestamp`, descriptive `byteFormat`. |
| `event` | Integer `sequence`, contiguous from 1 across all events including metadata; `source`, audit `timestamp`; optional `direction`, `delivery`, `rawMIDI1Bytes`, `ignored`, `message`, `control`. |
| `capture-end` | Unique terminal marker; `eventCount` exactly counts stored events; audit stop `timestamp`. Earlier events are flushed before the marker, then marker flushed/file closed. No row may follow it. |

`session.sessionID` is the recording identity. `applicationVersion`, `sourceRevision`, `sourceTreeDirty`, `deviceModel` declare software/device provenance; unavailable facts are null or absent. BCR writes `BCR2000`, X-Touch writes `X-TOUCH COMPACT`. A name is not hardware qualification. Endpoint objects, when known, have integer `id` and string `name`; unavailable endpoints are null. Mock ports without an actual endpoint ID are null, with BCR's separate name extension below.

| Field | Common meaning |
| --- | --- |
| `source` | `hardware`, `mock`, `agent`, `application`; observation/provenance, independent of direction. Synthetic Mock input stays Mock even if an Agent initiated it; BCR separately records writer origin. |
| `direction` | `IN` device/Mock to host, `OUT` feedback/attempted output. Absent/null on metadata-only events. |
| `delivery` | `received`, `sent`, `suppressed`, `failed` when known. BCR also retains `disconnected` for failed routing. `sent` is transport/Mock acceptance, not physical acknowledgement. |
| `rawMIDI1Bytes` | Canonical MIDI 1, not UMP, parameter values or inferred control identity. One message per row: status 0x80–0xEF; 2 bytes for Program Change/channel pressure, otherwise 3; seven-bit data bytes. Metadata omits/nulls this field. |
| `timestamp` | UTC ISO-8601 host audit Date with fractional seconds. It can jump; it is not a transferable monotonic origin or arrival acknowledgement. Legacy foreign records may omit it. Sequence is authoritative order. |
| `ignored` | Host ignored the observation; it remains counted/stored. BCR marks identified feedback echoes ignored too. |
| `message`, `control`, `decoded` | Optional diagnostic/device-specific descriptions; display strings are not portable executable mappings or machine control identities. |

X-Touch's configured channels/layers/LED protocol remain its extensions, with channel settings 1–16 independent of the raw channel nibble. BCR does **not** fabricate an A/B `hostLayer`, Global RX channel, factory map or motor/touch metadata. Its map can be learned/arbitrary, so those X-Touch fields cannot truthfully be supplied. Common inspection stays separate from either strict device replay decoder.

## BCR extensions

| Location | Fields / meaning |
| --- | --- |
| Header | `hostFormatVersion=1`, `monotonicTimestamp` |
| session | `deviceSource`, `hardwareMode`, `mappingFingerprint`/`mappingFingerprintAlgorithm=sha256`, `clockDomain`, configuration/map/parameter-value snapshots, `activePageID`, `bcrPortNames`, `bcrDisplay` |
| event | `monotonicTimestamp`, `deviceSource`, `origin` (deviceInput/softwareFeedback/agent/externalState/contextChanged), `echo`, `hardwareMode`, structured `bcrControl`, optional `bcrNRPN`, optional redacted `sysEx` |

BCR's monotonic values are injected host-observation seconds in this recording's process/domain. They are not reconstructed from audit Date and cannot be compared to another process. Native integrity/replay uses that channel. Foreign X-Touch audit strings are inspected as audit values only; no monotonic values or BCR clock origin are invented.

NRPN now writes four canonical CC rows (99/98/6/38); each row retains the logical number/value in `bcrNRPN`. Earlier unpublished BCR 12-byte concatenations remain readable by BCR for compatibility, but are no longer emitted. This corrects the original mismatch with X-Touch's one-message `rawMIDI1Bytes` convention. Input rows now explicitly say `delivery=received`; context rows carry `source=application`.

SysEx preset/BCL payloads are never stored. A `sysEx` object carries only positive `byteCount`, 64-hex `sha256` and `redacted=true`; direction/source still describe receipt but raw bytes are absent. This is an explicit BCR exception, not fabricated canonical voice bytes. The display extension says four digits and actual text unknown because the device does not report that text. Configured software state is never labeled a hardware observation.

## Inspection and replay boundary

Both device samples can be read for common session facts, counts, directions, bytes and audit timestamps. Unknown extensions stay opaque. Foreign device files show their declared model and a clear replay refusal **before** any BCR session, Mock, MIDI port, runtime, MCP or output is constructed. BCR native replay still validates its map fingerprint/configuration/initial values, supported versions and monotonic clock. File reads are bounded/read-only and never rewrite the original.

`RecordedCapture` reports separate version/time/truncation/parse/sequence/boundary/context counters. Complete common evidence does not authorize foreign replay or hardware qualification. BCR imports are bounded to 16 MiB/200000 events; X-Touch's own bounds may differ.

## Committed recorder samples and provenance

- `Tests/Fixtures/Capture/bcr-sample.jsonl`: generated by the BCR recorder with a fixed injected clock/session identity, an explicit two-control Mock map, 15 events including a redacted synthetic SysEx summary and four NRPN CCs. The unit test compares current writer output byte-for-byte.
- `Tests/Fixtures/Capture/xtouch-sample.jsonl`: copied byte-for-byte from XTouchCompactDev `edcc120f74cb597dd4b6dcad3f3a524974a3ed40`; 14 Mock events (12 IN/2 OUT). The BCR test inspects common fields/integrity and checks an explicit other-device replay error.

There is no source dependency between hosts. These are synthetic fixtures, not personal captures, device presets, credentials, or hardware sign-off. See the fixture README for regeneration.
