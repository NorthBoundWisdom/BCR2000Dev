import BCRSurfaceDomain
import Foundation

public enum OfflineCaptureFile {
    /// One bounded regular-file read through the shared no-follow file boundary.
    public static func load(_ url: URL) throws -> RecordedCapture {
        do {
            guard let data = try LocalDataFile.read(url, maximumBytes: RecordedCapture.maximumBytes)
            else { throw CocoaError(.fileNoSuchFile) }
            return try RecordedCapture(data: data)
        } catch LocalDataFileError.tooLarge {
            throw CaptureDocumentError.tooLarge
        }
    }
}
