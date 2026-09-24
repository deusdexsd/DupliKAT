import Foundation

/// Rodzaj pliku z punktu widzenia twórcy wideo. Rozpoznawany po rozszerzeniu (szybko, bez otwierania pliku).
public enum MediaKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case video, audio, image, project, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .video: return "Wideo"
        case .audio: return "Audio"
        case .image: return "Zdjęcia"
        case .project: return "Projekty"
        case .other: return "Inne"
        }
    }

    public var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .project: return "doc.badge.gearshape"
        case .other: return "doc"
        }
    }

    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "braw", "r3d", "insv", "lrf", "webm", "3gp", "hevc", "dv", "mpg", "mpeg", "wmv", "flv"]
    static let audioExt: Set<String> = ["wav", "mp3", "aac", "m4a", "aif", "aiff", "flac", "caf", "ogg", "opus", "wma", "alac", "bwf"]
    static let imageExt: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "arw", "cr2", "cr3", "nef", "dng", "raf", "orf", "rw2", "srw", "pef", "webp", "gif", "psd", "bmp", "avif", "jxl"]
    static let projectExt: Set<String> = ["fcpxml", "fcpxmld", "motn", "moef", "moti", "motr", "prproj", "drp", "aep", "als", "logicx", "cube", "3dl", "lut"]

    public static func from(extension ext: String) -> MediaKind {
        let e = ext.lowercased()
        if videoExt.contains(e) { return .video }
        if audioExt.contains(e) { return .audio }
        if imageExt.contains(e) { return .image }
        if projectExt.contains(e) { return .project }
        return .other
    }
}

/// Tożsamość pliku na dysku (urządzenie + i-węzeł). Dwa wpisy o tej samej tożsamości to twarde dowiązanie,
/// czyli JEDEN plik widoczny w dwóch miejscach — usunięcie jednego nie zwalnia miejsca, więc to nie jest duplikat.
public struct FileIdentity: Hashable, Sendable, Codable {
    public let device: Int32
    public let inode: UInt64
}

public struct ScannedFile: Hashable, Sendable, Identifiable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    public let created: Date?
    public let identity: FileIdentity?
    public let kind: MediaKind
    /// Plik istnieje tylko w iCloud (na dysku jest sam „cień”). Czytanie go wymusza pobranie — nigdy tego nie robimy.
    public var isDataless: Bool = false

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var folder: String { url.deletingLastPathComponent().path }
    public var volumeName: String { VolumeInfo.volumeName(forPath: url.path) }

    public init(url: URL, size: Int64, modified: Date, created: Date?, identity: FileIdentity?, kind: MediaKind? = nil) {
        self.url = url; self.size = size; self.modified = modified; self.created = created; self.identity = identity
        self.kind = kind ?? MediaKind.from(extension: url.pathExtension)
    }

    /// Czyta metadane pliku jednym wywołaniem stat (szybciej niż resourceValues przy setkach tysięcy plików).
    public static func stat(_ url: URL) -> ScannedFile? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mod = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let birth = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
        var f = ScannedFile(url: url, size: Int64(st.st_size), modified: mod, created: birth,
                            identity: FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino)))
        f.isDataless = (st.st_flags & UInt32(SF_DATALESS)) != 0
        return f
    }
}

public enum VolumeInfo {
    /// "/Volumes/M/…" → "M", wszystko inne → nazwa dysku startowego.
    public static func volumeName(forPath path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let rest = path.dropFirst("/Volumes/".count)
            return String(rest.split(separator: "/", maxSplits: 1).first ?? Substring(rest))
        }
        return bootName
    }

    public static let bootName: String = {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }()

    /// Czy da się zrobić klon APFS (plik zajmuje miejsce raz, choć widać go w dwóch miejscach).
    public static func supportsCloning(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) ?? false
    }
}

/// Postęp długiej operacji, podawany do UI.
public struct ScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case listing = "Przeglądam foldery"
        case grouping = "Szukam plików tej samej wielkości"
        case sampling = "Porównuję fragmenty plików"
        case hashing = "Porównuję pełną zawartość"
        case fingerprinting = "Analizuję obraz i dźwięk"
        case comparing = "Porównuję podobieństwo"
        case measuring = "Liczę rozmiary"
        case copying = "Kopiuję"
        case verifying = "Sprawdzam kopię bajt po bajcie"
        case done = "Gotowe"
    }
    public var phase: Phase
    public var done: Int = 0
    public var total: Int = 0
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var current: String = ""

    public init(phase: Phase, done: Int = 0, total: Int = 0, bytesDone: Int64 = 0, bytesTotal: Int64 = 0, current: String = "") {
        self.phase = phase; self.done = done; self.total = total; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.current = current
    }

    public var fraction: Double? {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if total > 0 { return min(1, Double(done) / Double(total)) }
        return nil
    }
}

public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

/// Grupa plików uznanych za kopie (identyczne) albo za bardzo podobne.
public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public enum Match: Sendable, Hashable {
        /// Pełna zawartość bajt po bajcie taka sama.
        case identical
        /// Ten sam rozmiar i te same próbki z początku/środka/końca — prawie na pewno identyczne (bez pełnego czytania).
        case sampled
        /// Podobne, ale nie identyczne (zdjęcie w innym rozmiarze, inny eksport). similarity 0…1.
        case similar(Double)
    }

    public let id: String
    public var files: [ScannedFile]
    public let match: Match

    public init(id: String, files: [ScannedFile], match: Match) { self.id = id; self.files = files; self.match = match }

    public var kind: MediaKind { files.first?.kind ?? .other }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    /// Ile miejsca wróci, jeśli zostawisz jedną (największą) kopię.
    public var reclaimable: Int64 { totalSize - (files.map(\.size).max() ?? 0) }
    public var isExact: Bool { if case .similar = match { return false } else { return true } }
}
