import Foundation

/// Pliki, które Final Cut Pro tworzy sam i potrafi odtworzyć: rendery, proxy, media zoptymalizowane, analiza.
/// Oryginalne media („Original Media”) i dane projektów NIE są tu nigdy wliczane.
public enum GeneratedKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case render, preview, proxy, optimized, analysis, segmentation, mediaCache, cache
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .render: return CoreText.t("Rendery")
        case .preview: return CoreText.t("Podglądy")
        case .mediaCache: return CoreText.t("Cache mediów")
        case .cache: return CoreText.t("Cache")
        case .proxy: return CoreText.t("Proxy")
        case .optimized: return CoreText.t("Zoptymalizowane")
        case .analysis: return CoreText.t("Analiza")
        case .segmentation: return CoreText.t("Segmentacja")
        }
    }

    public var symbol: String {
        switch self {
        case .render: return "square.stack.3d.down.right"
        case .preview: return "play.rectangle"
        case .mediaCache: return "waveform.badge.magnifyingglass"
        case .cache: return "internaldrive"
        case .proxy: return "rectangle.compress.vertical"
        case .optimized: return "wand.and.stars"
        case .analysis: return "waveform.path.ecg"
        case .segmentation: return "person.crop.rectangle"
        }
    }

    /// Co się stanie po usunięciu — pokazywane przy potwierdzeniu.
    public var consequence: String {
        switch self {
        case .render: return CoreText.t("FCP wyrenderuje ponownie przy odtwarzaniu/eksporcie.")
        case .preview: return CoreText.t("Premiere wyrenderuje podglądy ponownie, gdy będą potrzebne.")
        case .mediaCache: return CoreText.t("Premiere/After Effects odbudują cache i pliki szczytów przy imporcie (pierwsze otwarcie projektu będzie wolniejsze).")
        case .cache: return CoreText.t("Program odtworzy cache przy odtwarzaniu (pierwsze odtworzenie będzie wolniejsze).")
        case .proxy: return CoreText.t("Jeśli montujesz na proxy, trzeba je utworzyć ponownie w programie.")
        case .optimized: return CoreText.t("Program wróci do oryginałów; zoptymalizowane media można utworzyć ponownie.")
        case .analysis: return CoreText.t("Analiza (stabilizacja, ludzie) zostanie policzona ponownie, jeśli będzie potrzebna.")
        case .segmentation: return CoreText.t("Dane masek/izolacji obiektów zostaną policzone ponownie przy użyciu.")
        }
    }
}

/// Program, do którego należą pliki robocze.
public enum EditorApp: String, CaseIterable, Sendable, Codable, Identifiable {
    case finalCut, adobe, davinci, capcut
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .finalCut: return CoreText.t("Final Cut Pro")
        case .adobe: return CoreText.t("Premiere Pro / After Effects")
        case .davinci: return CoreText.t("DaVinci Resolve")
        case .capcut: return CoreText.t("CapCut")
        }
    }
    /// Identyfikatory aplikacji (do wykrycia, czy program jest zainstalowany / uruchomiony).
    public var bundlePrefixes: [String] {
        switch self {
        case .finalCut: return ["com.apple.FinalCut"]
        case .adobe: return ["com.adobe.PremierePro", "com.adobe.AfterEffects"]
        case .davinci: return ["com.blackmagic-design.DaVinciResolve"]
        case .capcut: return ["com.lemon.lvoverseas", "com.lemon.lvpro"]
        }
    }
}

public struct GeneratedFolder: Identifiable, Sendable, Hashable {
    public let url: URL
    public let kind: GeneratedKind
    public let size: Int64
    /// Nazwa wydarzenia w bibliotece (nil dla folderów spoza biblioteki).
    public let event: String?
    public var id: String { url.path }
}

public struct LibraryReport: Identifiable, Sendable, Hashable {
    public let url: URL
    /// true = folder z plikami roboczymi (nie biblioteka FCP), np. „Final Cut Proxy Media”, CacheClip, Media Cache.
    public let isExternalFolder: Bool
    public let folders: [GeneratedFolder]
    public var app: EditorApp = .finalCut
    /// Własna nazwa do wyświetlenia (np. „Media Cache (Adobe)”); nil = z nazwy folderu/biblioteki.
    public var label: String?
    public init(url: URL, isExternalFolder: Bool, folders: [GeneratedFolder], app: EditorApp = .finalCut, label: String? = nil) {
        self.url = url; self.isExternalFolder = isExternalFolder; self.folders = folders; self.app = app; self.label = label
    }
    public var id: String { url.path }
    public var name: String { label ?? (isExternalFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent) }
    public var total: Int64 { folders.reduce(0) { $0 + $1.size } }
    public func size(of kind: GeneratedKind) -> Int64 { folders.filter { $0.kind == kind }.reduce(0) { $0 + $1.size } }
    public var volumeName: String { VolumeInfo.volumeName(forPath: url.path) }
}

public enum FCPGeneratedScanner {
    /// `includeFixed`: dołącz stałe miejsca cache programów (Adobe Media Cache, CapCut…), nawet spoza wskazanych folderów.
    public static func scan(roots: [URL], excluded: [String] = [], includeFixed: Bool = true, progress: ProgressHandler? = nil) throws -> [LibraryReport] {
        let excluded = excluded.map(FileWalker.canonical)
        var reports: [LibraryReport] = []
        let fm = FileManager.default
        var visited = 0
        // Domyślne miejsce podglądów Premiere (Dokumenty/Adobe) — szukamy tam tylko folderów podglądów po nazwie.
        let adobeDocs = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Adobe")
        let allRoots = includeFixed && fm.fileExists(atPath: adobeDocs.path) ? roots + [adobeDocs] : roots
        for root in FileWalker.normalizedRoots(allRoots) {
            try Task.checkCancellation()
            if let r = try report(for: root, progress: progress) { reports.append(r); continue }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                visited += 1
                if visited % 2000 == 0 {
                    try Task.checkCancellation()
                    progress?(ScanProgress(phase: .listing, done: visited, current: url.path))
                }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
                if FileWalker.isExcluded(url.path, excluded) { en.skipDescendants(); continue }
                if let r = try report(for: url, progress: progress) {
                    reports.append(r); en.skipDescendants(); continue
                }
                if v?.isPackage == true { en.skipDescendants() } // .app, .photoslibrary itp.
            }
        }
        if includeFixed {
            let seen = Set(reports.map { FileWalker.canonical($0.url.path) })
            for (url, app, kind, label) in fixedLocations() where !seen.contains(FileWalker.canonical(url.path)) && !FileWalker.isExcluded(FileWalker.canonical(url.path), excluded) {
                try Task.checkCancellation()
                progress?(ScanProgress(phase: .measuring, current: url.path))
                let size = try directorySize(url)
                if size > 0 { reports.append(LibraryReport(url: url, isExternalFolder: true, folders: [GeneratedFolder(url: url, kind: kind, size: size, event: nil)], app: app, label: CoreText.t(label))) }
            }
        }
        progress?(ScanProgress(phase: .done))
        return reports.filter { $0.total > 0 }.sorted { $0.total > $1.total }
    }

    /// Jeśli `url` to biblioteka FCP albo zewnętrzny folder mediów FCP — zwraca raport, inaczej nil.
    static func report(for url: URL, progress: ProgressHandler?) throws -> LibraryReport? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if ext == "fcpbundle" {
            return LibraryReport(url: url, isExternalFolder: false, folders: try libraryFolders(url, progress: progress))
        }
        if let (app, kind, label) = namedFolders[name] {
            progress?(ScanProgress(phase: .measuring, current: url.path))
            let size = try directorySize(url)
            let parent = url.deletingLastPathComponent().lastPathComponent
            return LibraryReport(url: url, isExternalFolder: true, folders: size > 0 ? [GeneratedFolder(url: url, kind: kind, size: size, event: nil)] : [],
                                 app: app, label: label.map { "\(CoreText.t($0)) — \(parent)" })
        }
        return nil
    }

    /// Foldery z plikami roboczymi rozpoznawane po nazwie w dowolnym miejscu skanu.
    static let namedFolders: [String: (EditorApp, GeneratedKind, String?)] = [
        "Final Cut Proxy Media": (.finalCut, .proxy, nil),
        "Final Cut Optimized Media": (.finalCut, .optimized, nil),
        "Adobe Premiere Pro Video Previews": (.adobe, .preview, "Podglądy wideo"),
        "Adobe Premiere Pro Audio Previews": (.adobe, .preview, "Podglądy audio"),
        "CacheClip": (.davinci, .cache, "CacheClip"),
        "ProxyMedia": (.davinci, .proxy, "Proxy"),
        "OptimizedMedia": (.davinci, .optimized, "Zoptymalizowane"),
    ]

    /// Stałe miejsca cache programów (niezależnie od tego, jakie foldery wskazano do skanu).
    public static func fixedLocations(home: String = NSHomeDirectory()) -> [(URL, EditorApp, GeneratedKind, String)] {
        let adobe = home + "/Library/Application Support/Adobe/Common"
        let list: [(String, EditorApp, GeneratedKind, String)] = [
            (adobe + "/Media Cache Files", .adobe, .mediaCache, "Media Cache Files"),
            (adobe + "/Media Cache", .adobe, .mediaCache, "Media Cache (bazy)"),
            (adobe + "/Peak Files", .adobe, .mediaCache, "Pliki szczytów audio"),
            (adobe + "/Analyzer Cache Files", .adobe, .mediaCache, "Cache analizy"),
            (home + "/Movies/CacheClip", .davinci, .cache, "CacheClip"),
            (home + "/Movies/CapCut/User Data/Cache", .capcut, .cache, "Cache CapCut"),
            (home + "/Movies/JianyingPro/User Data/Cache", .capcut, .cache, "Cache Jianying"),
            (home + "/Library/Containers/com.lemon.lvoverseas/Data/Library/Caches", .capcut, .cache, "Cache aplikacji CapCut"),
        ]
        return list.map { (URL(fileURLWithPath: $0.0), $0.1, $0.2, $0.3) }.filter { FileManager.default.fileExists(atPath: $0.0.path) }
    }

    /// Struktura biblioteki: <biblioteka>/<wydarzenie>/{Render Files, Transcoded Media/{Proxy Media, High Quality Media}, Analysis Files},
    /// plus <biblioteka>/VideoSegmentationFiles i ewentualny cache (*.fcpcache) z tą samą strukturą wydarzeń.
    static func libraryFolders(_ lib: URL, progress: ProgressHandler?) throws -> [GeneratedFolder] {
        let fm = FileManager.default
        var out: [GeneratedFolder] = []
        func add(_ url: URL, _ kind: GeneratedKind, _ event: String?) throws {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            progress?(ScanProgress(phase: .measuring, current: url.path))
            let size = try directorySize(url)
            if size > 0 { out.append(GeneratedFolder(url: url, kind: kind, size: size, event: event)) }
        }
        func scanEvents(in container: URL) throws {
            let children = (try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for ev in children where (try? ev.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !ev.lastPathComponent.hasPrefix("__") {
                try Task.checkCancellation()
                let e = ev.lastPathComponent
                try add(ev.appendingPathComponent("Render Files"), .render, e)
                try add(ev.appendingPathComponent("Transcoded Media/Proxy Media"), .proxy, e)
                try add(ev.appendingPathComponent("Transcoded Media/High Quality Media"), .optimized, e)
                try add(ev.appendingPathComponent("Analysis Files"), .analysis, e)
            }
        }
        try scanEvents(in: lib)
        try add(lib.appendingPathComponent("VideoSegmentationFiles"), .segmentation, nil)
        let caches = ((try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil, options: [])) ?? []).filter { $0.pathExtension == "fcpcache" || $0.lastPathComponent == ".fcpcache" }
        for c in caches { try scanEvents(in: c) }
        return out
    }

    /// Rozmiar zajęty na dysku przez folder (suma rozmiarów przydzielonych plików).
    public static func directorySize(_ url: URL) throws -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
                                                      options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let f as URL in en {
            n += 1
            if n % 5000 == 0 { try Task.checkCancellation() }
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
