BCR Agent Console for macOS 14 or later, with universal Apple Silicon / Intel binaries.

Download the DMG and drag **BCRAgentConsole.app** to **Applications**. The ZIP
contains the same application. Verify downloads against `SHA256SUMS`.

This is an **ad-hoc signed, unnotarized build** for development/self-use. Downloading
this package does not install the BCR2000 USB compatibility extension. An existing
development-signed compatibility extension remains a separate installation; a new
Mac needs its own eligible development signing/profile setup or a standard DIN
MIDI interface. Ad-hoc signing is not sufficient to load a DriverKit extension
under normal security settings.

The app can run in Mock mode without hardware. Physical controls require an
explicitly learned mapping. This package is not advertised as a notarized,
unrestricted DriverKit distribution.
