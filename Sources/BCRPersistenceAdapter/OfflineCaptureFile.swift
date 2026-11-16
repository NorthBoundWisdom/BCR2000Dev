import BCRSurfaceDomain
import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum OfflineCaptureFile {
    /// Read one bounded frozen prefix. Symlinks, FIFOs, directories and remote URLs are rejected.
    public static func load(_ url: URL) throws -> RecordedCapture {
        guard url.isFileURL, !url.path.contains("\0") else { throw CaptureDocumentError.invalidRecord }
        let descriptor = url.withUnsafeFileSystemRepresentation { open(
            $0!,
            O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
        ) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw CaptureDocumentError.invalidRecord }
        guard info.st_size <= RecordedCapture.maximumBytes else { throw CaptureDocumentError.tooLarge }
        let data = try handle.read(upToCount: RecordedCapture.maximumBytes + 1) ?? Data()
        return try RecordedCapture(data: data)
    }
}
