# Native accessibility identifiers

Identifiers follow the shared dot-separated semantic naming convention. They are
literal interaction contracts, independent of translated labels, source order and
MIDI addresses. Keep existing identifiers when moving a view or renaming a label;
UI acceptance tools depend on them. New entity rows append their persistent UUID,
parameter ID, macro ID, page ID or physical control identity. Confirmation controls
have distinct identifiers from the action that opens them. Shared view helpers
receive an explicit identity or derive one from their stable owning entity.

| Surface | Identifier contract |
| --- | --- |
| Top encoder rotation | `surface.pushEncoder.<group 1–4>.<index 1–8>` |
| Top encoder press | `surface.pushEncoderButton.<group 1–4>.<index 1–8>` |
| LED buttons | `surface.button.<row 1–2>.<index 1–8>` |
| Lower encoders | `surface.encoder.<row 1–3>.<index 1–8>` |
| User keys | `surface.userButton.1.<index 1–4>` |
| Settings shortcuts | `settings.open.<SettingsTab raw value>` |
| Existing application controls | Retain the exact literals in their view source, including `parameter.*`, `scenes.*`, `preset.*` and `workspace.*` |
| New entity actions | View-specific semantic prefix plus persistent identity suffix |

The 108 catalog identities include all four top encoder groups and separate
rotation/press identities. Their geometry does not depend on assignment, parameter,
page, source, language or learned MIDI mapping. The currently selected physical
group determines which of its existing catalog identities the panel presents.
KnobCell, PushButtonCell, PadCell and UserKeyCell each bind that identity directly.
This does not add device input, output or remote APIs.

Run `python3 configs/check_accessibility.py` to check interactive SwiftUI primitive
coverage, duplicate literal templates and all four panel binding families. CI runs
it with the existing source checks. BuildWorkflowTests cover nested controls,
comments, strings, missing identities, duplicates and physical family omissions.
`HardwareMapTests.testAll108AccessibilityIDsUseOnlyStableGeometry` verifies the
unique catalog and its exact geometry/serialization contract.

These checks inspect source and model values. They do not verify a live native
accessibility tree, focus traversal or system dialogs. Dynamic helper and entity
identities require review alongside the static template check; a unique template
alone cannot prove uniqueness of every runtime instance.
