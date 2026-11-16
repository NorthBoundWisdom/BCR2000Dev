import BCRFoundation
import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum LocalDataFileError: Error, LocalizedError, Equatable {
    case notRegularFile, symbolicLink, tooLarge, changedFile, newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile: L10n.text("本地数据必须是普通文件")
        case .symbolicLink: L10n.text("本地数据文件拒绝符号链接")
        case .tooLarge: L10n.text("本地数据文件超过大小上限")
        case .changedFile: L10n.text("原文件已更改，未覆盖")
        case let .newerVersion(version): L10n.text("文件版本 v\(version) 高于当前支持版本，原文件已保留")
        }
    }
}

/// One POSIX boundary for bounded reads, exclusive evidence and atomic JSON replacement.
/// Parent directory and final component are opened without following symbolic links.
public enum LocalDataFile {
    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func parent(_ url: URL, create: Bool) throws -> Int32? {
        guard url.isFileURL, !url.path.contains("\0") else { throw CocoaError(.fileReadUnsupportedScheme) }
        let directory = url.deletingLastPathComponent()
        var info = stat()
        if directory.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0,
           info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { throw LocalDataFileError.symbolicLink }
        if create {
            // Creation never replaces an existing directory or symlink. The descriptor
            // check below rejects an immediate parent symlink, including a broken link.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let descriptor = directory.withUnsafeFileSystemRepresentation { open(
            $0!,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ) }
        if descriptor < 0 {
            if !create, errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw LocalDataFileError.symbolicLink }
            throw failure()
        }
        return descriptor
    }

    private static func read(_ name: String, parent: Int32, maximumBytes: Int) throws -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw LocalDataFileError.tooLarge }
        let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw LocalDataFileError.symbolicLink }
            throw failure()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LocalDataFileError.notRegularFile }
        guard info.st_size <= maximumBytes else { throw LocalDataFileError.tooLarge }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw LocalDataFileError.tooLarge }
        return data
    }

    public static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        guard let descriptor = try parent(url, create: false) else { return nil }
        defer { _ = close(descriptor) }
        return try read(url.lastPathComponent, parent: descriptor, maximumBytes: maximumBytes)
    }

    public static func createExclusive(_ url: URL) throws -> FileHandle {
        guard let directory = try parent(url, create: false) else { throw CocoaError(.fileNoSuchFile) }
        defer { _ = close(directory) }
        let descriptor = openat(directory, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw failure() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public static func replace(_ data: Data, at url: URL, maximumBytes: Int,
                               validateExisting: (Data?) throws -> Void) throws
    {
        guard data.count <= maximumBytes else { throw LocalDataFileError.tooLarge }
        guard let directory = try parent(url, create: true) else { throw CocoaError(.fileNoSuchFile) }
        defer { _ = close(directory) }
        let name = url.lastPathComponent
        let original = try read(name, parent: directory, maximumBytes: maximumBytes)
        try validateExisting(original)
        let temporary = ".bcr-" + UUID().uuidString + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw failure() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlinkat(directory, temporary, 0) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard try read(name, parent: directory, maximumBytes: maximumBytes) == original else {
            throw LocalDataFileError.changedFile
        }
        guard renameat(directory, temporary, directory, name) == 0 else { throw failure() }
    }

    @discardableResult
    public static func contentBackup(_ data: Data, original: URL, kind: String, maximumBytes: Int,
                                     write: (Data, URL) throws -> Void = { data, url in
                                         let handle = try createExclusive(url)
                                         defer { try? handle.close() }
                                         try handle.write(contentsOf: data)
                                         try handle.synchronize()
                                     }) throws -> URL
    {
        guard try read(original, maximumBytes: maximumBytes) == data else { throw LocalDataFileError.changedFile }
        let url = original.appendingPathExtension("\(kind).\(ContentDigest.sha256(data)).json")
        if let existing = try read(url, maximumBytes: maximumBytes) {
            guard existing == data else { throw ConfigurationFileError(reason: L10n.text("备份冲突，未覆盖原文件")) }
        } else { try write(data, url) }
        guard try read(url, maximumBytes: maximumBytes) == data,
              try read(original, maximumBytes: maximumBytes) == data
        else { throw ConfigurationFileError(reason: L10n.text("备份校验失败，未覆盖原文件")) }
        return url
    }

    public static func rejectFutureVersion(in data: Data, supported: Int) throws {
        // Inspect the envelope before decoding fields an older application cannot know.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version > supported else { return }
        throw LocalDataFileError.newerVersion(version)
    }
}
