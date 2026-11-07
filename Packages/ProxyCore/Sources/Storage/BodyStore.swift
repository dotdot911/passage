import Foundation
import ProxyModel

/// Bodies live as plain files: `<dir>/<flowID>.req` and `.res`, stored exactly as sent
/// on the wire (still gzip/br-encoded if Content-Encoding says so).
public final class BodyStore: Sendable {
    /// Bytes saved per body; the rest of a larger transfer still reaches the app but is not saved.
    public static let defaultMaxBodyBytes = 100 * 1024 * 1024

    public let directory: URL
    public let maxBodyBytes: Int

    public init(directory: URL, maxBodyBytes: Int = BodyStore.defaultMaxBodyBytes) {
        self.directory = directory
        self.maxBodyBytes = maxBodyBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(flowID: UUID, side: BodySide) -> URL {
        directory.appendingPathComponent("\(flowID.uuidString).\(side.rawValue)")
    }

    public func read(flowID: UUID, side: BodySide) -> Data? {
        try? Data(contentsOf: url(flowID: flowID, side: side))
    }

    /// Reads at most `maxBytes` from the start of a body without loading the whole file.
    /// - Returns: the bytes read and the file's full size, or nil if there is no body file.
    public func readPrefix(flowID: UUID, side: BodySide, maxBytes: Int) -> (data: Data, totalSize: Int)? {
        let u = url(flowID: flowID, side: side)
        guard let handle = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()).map(Int.init) ?? 0
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        let data = (try? handle.read(upToCount: max(0, maxBytes))) ?? nil
        return (data ?? Data(), total)
    }

    /// Opens a streaming writer. Writes happen on a private serial queue.
    public func writer(flowID: UUID, side: BodySide) -> BodySink {
        FileBodySink(url: url(flowID: flowID, side: side), limit: maxBodyBytes)
    }

    /// Writes a whole body at once (imports).
    public func write(_ data: Data, flowID: UUID, side: BodySide) throws {
        try data.write(to: url(flowID: flowID, side: side), options: .atomic)
    }

    /// Removes both bodies of a flow; returns the bytes freed.
    @discardableResult
    public func remove(flowID: UUID) -> Int {
        var freed = 0
        for side in [BodySide.request, .response] {
            let u = url(flowID: flowID, side: side)
            freed += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: u)
        }
        return freed
    }

    public func removeAll() throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func totalSize() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    /// Every body file with the flow it belongs to (nil for a name that is not `<uuid>.<side>`).
    func files() -> [(url: URL, flowID: UUID?, size: Int, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.map { u in
            let values = try? u.resourceValues(forKeys: Set(keys))
            let id = UUID(uuidString: u.deletingPathExtension().lastPathComponent)
            return (u, id, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }
}

/// Streams one body to disk. It stops saving (keeping what it has) once the body reaches
/// `limit`, or when more than `maxQueuedBytes` wait for the disk, so memory stays bounded.
final class FileBodySink: BodySink, @unchecked Sendable {
    static let maxQueuedBytes = 8 * 1024 * 1024
    private static let queue = DispatchQueue(label: "passage.bodies")
    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    private var accepted = 0
    private var queued = 0
    private var stopped = false
    private var handle: FileHandle?
    private var finished = false

    init(url: URL, limit: Int = BodyStore.defaultMaxBodyBytes) {
        self.url = url
        self.limit = limit
    }

    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let chunk: ArraySlice<UInt8>? = lock.withLock {
            guard !stopped else { return nil }
            if queued + bytes.count > Self.maxQueuedBytes {
                stopped = true
                return nil
            }
            let take = min(bytes.count, limit - accepted)
            if take < bytes.count { stopped = true }
            guard take > 0 else { return nil }
            accepted += take
            queued += take
            return bytes.prefix(take)
        }
        guard let chunk else { return }
        Self.queue.async { [self] in
            defer { lock.withLock { queued -= chunk.count } }
            guard !finished else { return }
            if handle == nil {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
            }
            try? handle?.write(contentsOf: Data(chunk))
        }
    }

    func finish() {
        Self.queue.async { [self] in
            guard !finished else { return }
            finished = true
            try? handle?.close()
            handle = nil
        }
    }

    /// Test hook: waits until all queued writes have hit the disk.
    static func drain() { queue.sync {} }
}
