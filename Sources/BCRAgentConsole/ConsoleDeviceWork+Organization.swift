import BCRSurfaceDomain

extension ConsoleSurfaceIntents {
    func undo() {
        do { try session.undo() } catch { report(error) }
    }

    func redo() {
        do { try session.redo() } catch { report(error) }
    }
}
