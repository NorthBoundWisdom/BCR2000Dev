# Pipe integration example

`chassis-roles.json` uses the consumer-owned `pipe.surface-sim.chassis-roles` schema. It is an
optional Pipe integration example, **not part of the public Surface Control delivery convention**.
Pipe format changes can make this file stale. It pins the generic `../../chassis-controls.json`
configuration to profile version 1.3 and mapping revision `3d93301a62d6f9b6`; it grants no hardware authority.

Read-only assembly check from the host source tree (no platform startup or bytecode writes):

```sh
python3 -B configs/verify_simulation_roles.py --provider build/swiftpm/debug/BCRProviderService
```

The script defaults to this directory's role mapping. Use `--pipe-root` for another consumer
checkout and `--sdk` for a verified SDK. Missing source prints SKIP; incompatible consumers fail
with their actual error. The check never modifies or patches the consumer.

The existing Pipe consumer accepted the previous contract 1.1 example. At the M-round check it
rejected 1.2 with `invalid_mapping_config: Unsupported contract version allowlist`. Its owners
must upgrade (including current contract 1.3 and SDK 1.3.0) `delivery.py`'s contract allowlist and SDK pin, `roles.py`'s capability vocabulary,
`chassis_roles.schema.json`'s contract enum, and reviewed profile/mapping pins. Do not interpret a
role file shipped here as proof of consumer compatibility or of an end-to-end device stop.
