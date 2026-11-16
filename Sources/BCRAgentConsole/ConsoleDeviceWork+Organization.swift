import BCRSurfaceDomain
import BCRFoundation
import Foundation

extension ConsoleSurfaceIntents {
    func undo() {
        do { try session.undo() } catch { report(error) }
    }

    func redo() {
        do { try session.redo() } catch { report(error) }
    }
}

extension ConsoleSurfaceIntents {
    func captureScene(name: String, overwrite: Bool = false) {
        do { try session.captureScene(id: UUID().uuidString, name: name, overwrite: overwrite) }
        catch { report(error) }
    }

    func renameScene(_ id: String, to name: String) {
        do { try session.renameScene(id, to: name) } catch { report(error) }
    }

    func deleteScene(_ id: String) {
        do { try session.deleteScene(id) } catch { report(error) }
    }

    func recallScene(_ id: String) {
        do {
            let result = try session.recallScene(id)
            if !result.missingParameters.isEmpty {
                notice = ConsoleNotice(level: .warning,
                                       message: "场景已调用；跳过不存在的参数：\(result.missingParameters.joined(separator: ", "))")
            }
        } catch { report(error) }
    }
}
