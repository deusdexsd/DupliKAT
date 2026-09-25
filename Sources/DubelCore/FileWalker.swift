import Foundation

public struct WalkOptions: Sendable {
    /// Pliki mniejsze od tego są pomijane (drobne pliki systemowe, miniatury).
    public var minSize: Int64
    public var includeHidden: Bool
    /// Pełne ścieżki folderów, do których nie zaglądamy.
    public var excludedPaths: [String]
    /// nil = wszystkie rodzaje.
    public var kinds: Set<MediaKind>?
    /// Tu trafia wszystko, co pominięto (iCloud, brak dostępu, foldery chronione).
    public var log: ScanLog?
    /// Nazwy folderów pomijanych w tym skanie (np. miniatury i baza aparatu na karcie).
    public var skipFolderNames: Set<String> = []
    /// Czy wchodzić do podfolderów (domyślnie tak — foldery w folderach liczą się wszędzie).
    public var recursive = true

    public init(minSize: Int64 = 1, includeHidden: Bool = false, excludedPaths: [String] = [], kinds: Set<MediaKind>? = nil, log: ScanLog? = nil) {
        self.minSize = minSize; self.includeHidden = includeHidden; self.excludedPaths = excludedPaths; self.kinds = kinds; self.log = log
    }
}

public enum FileWalker {
    /// Foldery, których zawartości nigdy nie ruszamy: biblioteki FCP i ich cache, biblioteka Zdjęć, aplikacje,
    /// foldery mediów generowanych przez FCP trzymane poza biblioteką (proxy/zoptymalizowane), foldery robocze Premiere Pro
    /// i DaVinci Resolve (podglądy, autozapis, cache, bazy projektów) oraz szablony Motion
    /// (każdy szablon ma własną kopię mediów w swoim folderze Media — usunięcie „duplikatu” psuje szablon).
    public static let protectedExtensions: Set<String> = ["fcpbundle", "fcpcache", "photoslibrary", "app", "musiclibrary", "tvlibrary", "imovielibrary", "logicx", "fcpxmld", "motn", "band", "xcassets", "xcodeproj", "xcworkspace", "dra", "prproj", "drp"]
    public static let protectedFolderNames: Set<String> = ["Final Cut Proxy Media", "Final Cut Optimized Media", "Motion Templates.localized", "Motion Templates", "Final Cut Backups.localized", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", "node_modules", ".build", "DerivedData",
        // Premiere Pro: podglądy, autozapis, cache mediów, pliki szczytów
        "Adobe Premiere Pro Auto-Save", "Adobe Premiere Pro Video Previews", "Adobe Premiere Pro Audio Previews", "Adobe Premiere Pro Captured Audio",
        "Media Cache", "Media Cache Files", "Peak Files", "Team Projects Cache",
        // DaVinci Resolve: bazy projektów, cache, proxy i media zoptymalizowane
        "Resolve Disk Database", "Resolve Project Library", "CacheClip", "ProxyMedia", "OptimizedMedia", ".gallery", "Resolve Projects"]

    public static func isProtected(_ url: URL) -> Bool {
        protectedExtensions.contains(url.pathExtension.lowercased()) || protectedFolderNames.contains(url.lastPathComponent)
    }

    /// Usuwa z listy foldery zawarte w innych z listy (żeby nie liczyć tych samych plików dwa razy).
    public static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let paths = Array(Set(roots.map { canonical($0.path) })).sorted()
        var out: [String] = []
        for p in paths where !out.contains(where: { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { out.append(p) }
        return out.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Ścieżka w tej samej postaci, w jakiej zwraca ją przeglądanie folderów (np. /var → /private/var).
    /// realpath(3), bo resolvingSymlinksInPath z Foundation celowo obcina „/private” i ścieżki przestają się zgadzać.
    public static func canonical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(r) }
        return String(cString: r)
    }

    public static func isExcluded(_ path: String, _ excluded: [String]) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Zwraca wszystkie zwykłe pliki pod wskazanymi folderami. Twarde dowiązania (ten sam i-węzeł) liczone raz.
    public static func files(in roots: [URL], options: WalkOptions, progress: ProgressHandler? = nil) throws -> [ScannedFile] {
        var options = options
        options.excludedPaths = options.excludedPaths.map(canonical)
        var result: [ScannedFile] = []
        var seen = Set<FileIdentity>()
        var visited = 0
        let fm = FileManager.default
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }

        for root in normalizedRoots(roots) {
            try Task.checkCancellation()
            if isExcluded(root.path, options.excludedPaths) { continue }
            if isProtected(root) { options.log?.skip(root, .protected); continue }
            // Pojedynczy plik podany jako „folder”.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if let f = ScannedFile.stat(root), accept(f, options) {
                    if f.isDataless { options.log?.skip(root, .iCloud) } else { result.append(f) }
                }
                continue
            }
            let log = options.log
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: enumOptions,
                                         errorHandler: { url, _ in log?.skip(url, .noAccess); return true }) else { continue }
            for case let url as URL in en {
                visited += 1
                if visited % 2000 == 0 {
                    try Task.checkCancellation()
                    progress?(ScanProgress(phase: .listing, done: visited, current: url.deletingLastPathComponent().path))
                }
                let name = url.lastPathComponent
                // Pliki AppleDouble („._nazwa”) na dyskach exFAT to metadane macOS, nie treść.
                if name.hasPrefix("._") || name == ".DS_Store" { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if !options.recursive { en.skipDescendants(); continue }
                    if isExcluded(url.path, options.excludedPaths) || options.skipFolderNames.contains(url.lastPathComponent) { en.skipDescendants() }
                    else if isProtected(url) { options.log?.skip(url, .protected); en.skipDescendants() }
                    continue
                }
                guard let f = ScannedFile.stat(url), accept(f, options) else { continue }
                if f.isDataless { options.log?.skip(url, .iCloud); continue }
                if let id = f.identity {
                    if seen.contains(id) { continue }
                    seen.insert(id)
                }
                result.append(f)
            }
        }
        progress?(ScanProgress(phase: .listing, done: visited, total: visited))
        return result
    }

    static func accept(_ f: ScannedFile, _ o: WalkOptions) -> Bool {
        guard f.size >= max(1, o.minSize) else { return false }
        if let kinds = o.kinds, !kinds.contains(f.kind) { return false }
        return true
    }
}
