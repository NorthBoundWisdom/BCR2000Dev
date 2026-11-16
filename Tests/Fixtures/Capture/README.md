# Synthetic interchange captures

`xtouch-sample.jsonl` is copied byte-for-byte from XTouchCompactDev commit
`edcc120f74cb597dd4b6dcad3f3a524974a3ed40`, `Tests/Fixtures/Capture/xtouch-sample.jsonl`.
It is the committed recorder-generated Mock sample, not a handwritten placeholder.

`bcr-sample.jsonl` is produced by the BCR recorder with explicit synthetic values,
a fixed injected clock/session ID and a two-control Mock map. Regenerate only with
`BCR_UPDATE_CAPTURE_FIXTURES=1 swift test --build-path build/swiftpm --filter CaptureInterchangeTests.testRecorderMatchesCommittedSample`.
The normal test compares exact current writer output to the fixture. Neither file
is a physical-device capture, hardware qualification, personal preset or credential.
