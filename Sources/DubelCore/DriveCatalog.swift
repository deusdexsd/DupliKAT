import Foundation

/// Zapamiętana zawartość dysku: lista plików (ścieżka względna, rozmiar, data) — bez treści, bez czytania plików.
/// Dzięki niej wiadomo, że plik jest na M2, nawet gdy M2 leży w szufladzie. Dopasowanie po nazwie i rozmiarze w bajtach.
public struct DriveCatalog: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public var path: String
        public var size: Int64
        public var modified: Double
    }

    /// UUID woluminu (albo nazwa, gdy system go nie podaje).
    public var key: String
    public var name: String
    /// Ścieżka, pod którą dysk był ostatnio podłączony („/Volumes/M2”).
    public var root: String
    public var date: Date
    public var items: [Item]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Lista plików dysku (tylko metadane). Pliki mniejsze niż `minSize` pomijane — to nie materiał.
    public static func build(volume: URL, key: String, name: String, minSize: Int64 = 256_000, excluded: [String] = [], progress: ProgressHandler? = nil) throws -> DriveCatalog {
        var walk = WalkOptions(minSize: minSize, includeHidden: false, excludedPaths: excluded)
        walk.recursive = true
        let root = FileWalker.canonical(volume.path)
        let files = try FileWalker.files(in: [volume], options: walk, progress: progress)
        let items = files.map { f -> Item in
            let p = FileWalker.canonical(f.url.path)
            let rel = p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : f.url.lastPathComponent
            return Item(path: rel, size: f.size, modified: f.modified.timeIntervalSince1970)
        }
        return DriveCatalog(key: key, name: name, root: volume.path, date: Date(), items: items)
    }

    // MARK: Zapis

    public static func fileName(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.map(String.init).joined() + ".json"
    }

    public func save(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(Self.fileName(key)), options: .atomic)
    }

    public static func load(from dir: URL) -> [DriveCatalog] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(DriveCatalog.self, from: Data(contentsOf: $0)) }
    }

    public static func delete(key: String, in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName(key)))
    }
}

/// Katalog przygotowany do szybkiego szukania: (nazwa małymi literami, rozmiar) → ścieżki.
public struct CatalogIndex: Sendable {
    public let name: String
    public let root: String
    public let date: Date
    private let map: [String: [String]]

    public init(_ c: DriveCatalog) {
        name = c.name; root = c.root; date = c.date
        var m: [String: [String]] = [:]
        for i in c.items { m[Self.k((i.path as NSString).lastPathComponent, i.size), default: []].append(i.path) }
        map = m
    }

    static func k(_ name: String, _ size: Int64) -> String { "\(name.lowercased())|\(size)" }

    /// Pełne ścieżki (pod dawnym punktem montowania) plików o tej samej nazwie i rozmiarze.
    public func matches(name: String, size: Int64) -> [URL] {
        (map[Self.k(name, size)] ?? []).map { URL(fileURLWithPath: root).appendingPathComponent($0) }
    }

    public func contains(name: String, size: Int64) -> Bool { map[Self.k(name, size)] != nil }
}
