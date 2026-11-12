#if DEBUG
    import AppKit

    /// Debug integration adapter: render the current view without WindowServer compositing or activation.
    @MainActor
    enum IntegrationWindowCapture {
        private static var observer: (any NSObjectProtocol)?

        static func install(directory: URL) {
            guard observer == nil else { return }
            let name = Notification
                .Name("dev.bcragentconsole.integration.capture.\(ProcessInfo.processInfo.processIdentifier)")
            observer = DistributedNotificationCenter.default()
                .addObserver(forName: name, object: nil, queue: .main) { note in
                    guard let nonce = note.object as? String, UUID(uuidString: nonce) != nil else { return }
                    MainActor.assumeIsolated {
                        let target = directory.appending(path: "capture-\(nonce)")
                        do {
                            guard let window = NSApp.windows
                                .first(where: { $0.canBecomeMain && $0.title.hasPrefix("BCRTest-") }),
                                let view = (window.attachedSheet ?? window).contentView
                            else { throw CocoaError(.fileReadNoSuchFile) }
                            view.layoutSubtreeIfNeeded()
                            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                            try data.write(to: target.appendingPathExtension("png"), options: .atomic)
                        } catch {
                            try? Data(error.localizedDescription.utf8).write(
                                to: target.appendingPathExtension("error"),
                                options: .atomic
                            )
                        }
                    }
                }
        }
    }
#endif
