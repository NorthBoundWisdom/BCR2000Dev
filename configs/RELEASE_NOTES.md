BCR Agent Console for macOS 14 or later, with universal Apple Silicon / Intel binaries.

Download the DMG, open it and drag **BCRAgentConsole.app** to **Applications**.
The ZIP contains the same application. Verify downloads against `SHA256SUMS`.

These CI artifacts are ad-hoc signed and are not notarized by Apple. For Developer ID
and notarized distribution, use the documented local signing workflow in
`docs/PACKAGING.md`. A BCR2000 is optional for launching the app; hardware controls
require an explicitly learned mapping.
