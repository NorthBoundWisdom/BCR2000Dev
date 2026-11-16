# Process-owned virtual rehearsal

`--owned-virtual-rehearsal` is an explicit, nonphysical Release mode. It requires `--source hardware
--hardware-profile --hardware-map <explicit fixture map>` and memory-only state. It uses only a client, source,
destination and input/output ports created by this process. It never creates the ordinary native driver,
enumerates external endpoints, searches by name/UID, changes a preset, or falls back to hardware.
The mode is incompatible with simulation launch options, data-directory persistence and Debug hardware settings.

The dedicated profile is `bcr2000.owned-virtual-rehearsal/1.5`, with
`session.owned_virtual_rehearsal`. Discovery/profile, ready, lifecycle audit and SDK1.5 diagnostic capture identify it
as rehearsal. `physical_evidence` and hardware qualification remain false. `source=hardware` describes the fenced
contract direction, not physical-device evidence. Without this explicit flag, simulation1.3/hardware1.4 defaults
and descriptors are unchanged. Independent retention remains a separate capacity option.

The optional `--owned-virtual-rehearsal-input-fd N` transfers ownership of one inherited readable anonymous FIFO,
separate from credential stdin. Bounded JSON lines express only:

- `{"operation":"input","control":{"section":"encoder","row":1,"index":1},"value":45}`
- `{"operation":"disconnect"}`
- `{"operation":"reconnect"}`

This is a private process-owner peer, never an RPC or public raw-MIDI command sink. The selected fixture must
structurally express the control/encoding; this grants no real map or device qualification. Unknown, relative/NRPN
or visualization-only entries are rejected, as are raw bytes, foreign refs, SysEx and program-change commands.
Input is published through the created CoreMIDI source and received by the connected input-port callback.
The created destination is display receipt/audit only; its callback never becomes input or parameter state.

Startup, connection, reconnection and shutdown send no display feedback. Remote input/renew/reset keep their fixed
hardware rejections. Explicit display requires write policy plus display permission and the existing gateway gates.
Feedback leaves the contract input sequence and canonical parameter values unchanged. After a new genuine input,
the unchanged native engine can plan a correction to a retained desired-display overlay; that plan carries the
new input generation. It is separate from connection lifecycle replay, old queued work, echo or observation evidence.

`configs/verify_owned_virtual_rehearsal.py --artifact <actual Release artifact> --output <fresh directory>` runs the
real CoreMIDI owned source/destination roundtrip and actual SDK/HTTP matrix. It checks created refs, factory counts,
remote denial, display isolation, generation/unknown transitions, lifecycle-zero sends, SDK nonphysical markers
and cleanup. Ordinary Release still rejects Debug hardware injection. Source-boundary negative tests reject
intentional global enumeration/native-factory calls; the same production call policy rejects foreign refs.
No credentials are placed in argv, ready or logs. Failed owned cleanup is visible and returns a nonzero result.
These are software/virtual rehearsal results and never physical qualification or real actuator authorization.

All asynchronous entrances are bounded independently. Native input holds at most 256 consumption tickets;
private peer commands hold at most 16 batches, 64 commands and 64 KiB of UTF-8 payload until consumption;
display receipts hold at most 64 pending batches and 4096 UMP words. The incomplete peer buffer is separately
limited to 64 KiB. Peer freshness begins at its first FD read, including partial lines, and is checked again
before every command. Capacity exhaustion closes the peer or seals the callback scope before queuing one fault.
Unrelated MIDI notifications enqueue nothing; owned notifications share one coalesced pending slot.

The owned path validates every word of a batch as complete group-zero MIDI1 CC/note data with seven-bit fields.
Unsupported, truncated, mixed or high-bit words reject the whole batch. Receipt audit separates original UMP words
and packet timestamps from its normalized MIDI1 view. A private send timestamp attributes a receipt to the exact
original generation; a delayed old-generation receipt is history only. Receipt storage stops before 4096 words,
call audit retains 4096 attempts, and bounded failure history retains 64 entries with truncation counters.

Logical disconnect and generation revocation precede the system call. A throwing disconnect or connect leaves
ownership uncertain, blocks reuse and is never implicitly retried; cleanup may dispose only the owned refs once.
A new process is required to recover unconfirmed connection state. Stop is terminal, including synchronous callback
reentry, and repeated stop preserves the previous cleanup result. No queued peer batch can continue after stop.
