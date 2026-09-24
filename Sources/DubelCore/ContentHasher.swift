import CryptoKit
import Foundation

public enum HashError: Error { case unreadable(URL) }

public enum ContentHasher {
    static let sampleChunk = 64 * 1024
    static let readChunk = 4 * 1024 * 1024

    /// Szybki odcisk: rozmiar + 64 KB z początku, środka i końca pliku. Odsiewa 99% par tej samej wielkości
    /// bez czytania całych gigabajtów wideo.
    public static func sampleHash(_ url: URL, size: Int64) throws -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw HashError.unreadable(url) }
        defer { try? h.close() }
        noCache(h)
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let chunk = Int64(sampleChunk)
        let offsets: [Int64] = size <= chunk * 3 ? [0] : [0, size / 2 - chunk / 2, size - chunk]
        for off in offsets {
            try h.seek(toOffset: UInt64(off))
            let data = try h.read(upToCount: size <= chunk * 3 ? Int(size) : sampleChunk) ?? Data()
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    /// Pełny SHA-256 zawartości. `onBytes` dostaje liczbę przeczytanych bajtów (do paska postępu).
    public static func fullHash(_ url: URL, onBytes: ((Int64) -> Void)? = nil) throws -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw HashError.unreadable(url) }
        defer { try? h.close() }
        noCache(h)
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try autoreleasepool { try h.read(upToCount: readChunk) } ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            onBytes?(Int64(data.count))
        }
        return hex(hasher.finalize())
    }

    /// Duże pliki czytamy z pominięciem pamięci podręcznej systemu, żeby skan nie wypychał z RAM-u tego, czym pracujesz.
    private static func noCache(_ h: FileHandle) { _ = fcntl(h.fileDescriptor, F_NOCACHE, 1) }

    private static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
}

/// Pamięć wyników: ścieżka + rozmiar + data modyfikacji → odcisk. Drugi skan tych samych dysków nie czyta plików od nowa.
public final class HashCache: @unchecked Sendable {
    public struct Entry: Codable { public var sample: String?; public var full: String?; public var media: MediaFingerprint? }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let fileURL: URL?
    private var dirty = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    public static func key(_ f: ScannedFile) -> String { "\(f.url.path)|\(f.size)|\(Int(f.modified.timeIntervalSince1970))" }

    public func get(_ f: ScannedFile) -> Entry? { lock.withLock { entries[Self.key(f)] } }

    public func update(_ f: ScannedFile, _ change: (inout Entry) -> Void) {
        lock.withLock {
            var e = entries[Self.key(f)] ?? Entry()
            change(&e)
            entries[Self.key(f)] = e
            dirty = true
        }
    }

    public var count: Int { lock.withLock { entries.count } }

    public func save() {
        guard let fileURL else { return }
        let snapshot: [String: Entry]? = lock.withLock { dirty ? entries : nil }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        lock.withLock { dirty = false }
    }

    public func clear() {
        lock.withLock { entries.removeAll(); dirty = true }
        save()
    }
}
