# BCR Agent Console icon

`AppIcon.png` is the 1024 × 1024 RGBA master for the macOS application icon.
It was created with the built-in `image_gen` tool, then resized with macOS `sips`
for packaging. Transparency is preserved. No external asset service is needed to build.

The graphite rotary console, amber LED ring and terminal symbol connect the physical
BCR2000 control surface with the coding-agent console. The packaging workflow produces
16–1024 pixel iconset entries and `AppIcon.icns` under ignored `build/icons/`; the ICNS
is copied into the app and declared in `CFBundleIconFile`.

Generation prompt:

> Use case: logo-brand. Asset type: production macOS app icon for BCR Agent Console, a native app that turns a BCR2000 rotary MIDI control surface into an AI coding-agent console. Create one square 1024x1024 icon, isolated on a genuinely transparent background. Subject: a beautifully crafted, compact graphite control console with an iconic large rotary encoder, a warm amber segmented LED ring, and a small crisp terminal chevron motif engraved at its center. A few understated smaller rotary controls imply the hardware without excessive detail. Style: premium macOS desktop icon, restrained tactile 3D industrial design, softly rounded square dark metal base, subtle beveled edges, precise warm LED highlights, front view with very slight depth. Composition: centered, generous transparent outer margin, all details readable at 32 pixels; no text, no letters, no brand logos, no watermark, no surrounding objects or cast shadow outside the icon. The rounded square icon tile occupies about 85 percent of the image width. Deliver only the single finished icon.
