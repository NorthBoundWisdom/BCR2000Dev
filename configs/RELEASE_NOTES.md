BCR Agent Console for macOS 14 or later, with universal Apple Silicon / Intel binaries.

Download the DMG and drag **BCRAgentConsole.app** and **BCRUSBCompatibility.app** to
**Applications**. The ZIP contains the same two applications. Verify downloads
against `SHA256SUMS`.

This release is published only after Developer ID signing, Apple notarization,
and package verification on Apple Silicon and Intel runners succeed.

For direct BCR2000 USB feedback, open **BCRUSBCompatibility**, confirm firmware
1.10 and USB mode **U-1**, enable the compatibility extension in the normal macOS
Driver Extensions settings, then reconnect the controller. No Recovery or reduced
SIP setting is required. Remove the compatibility extension before using other
USB modes; those modes and other firmware versions have not been validated.

Users connecting through a standard DIN MIDI interface can use the console without
enabling this USB compatibility extension. A BCR2000 is optional for launching the
console; physical controls require an explicitly learned mapping. Full validation
of all controls, encoding modes, and operating-system versions remains ongoing.
