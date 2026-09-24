import DubelCore
import Foundation
import SwiftUI

/// Trzy poziomy czułości zamiast suwaka z liczbami. Wartości zmierzone na prawdziwych plikach (patrz Similarity.swift).
enum Sensitivity: Int, CaseIterable, Identifiable {
    case strict = 0, normal = 1, loose = 2
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .strict: return "Ścisłe"
        case .normal: return "Normalne"
        case .loose: return "Luźne"
        }
    }

    func photoHint() -> String {
        switch self {
        case .strict: return "Ten sam obraz w innym rozmiarze, jakości lub formacie."
        case .normal: return "Jak wyżej + kolejne zdjęcia z serii (to samo ujęcie)."
        case .loose: return "Jak wyżej + warianty i małe miniatury. Przeglądaj uważnie."
        }
    }

    func mediaHint() -> String {
        switch self {
        case .strict: return "Ten sam materiał, inny kodek lub rozdzielczość."
        case .normal: return "Jak wyżej + eksporty z lekką korekcją koloru."
        case .loose: return "Jak wyżej + wersje z innym gradingiem lub napisami. Przeglądaj uważnie."
        }
    }

    var imageDistance: Float { [0.12, 0.25, 0.40][rawValue] }
    var videoDistance: Float { [0.15, 0.25, 0.38][rawValue] }
    var audioCorrelation: Double { [0.95, 0.90, 0.84][rawValue] }
}

/// Ustawienia aplikacji (UserDefaults). Jeden obiekt, wstrzykiwany do widoków.
@MainActor
final class Prefs: ObservableObject {
    static let defaults: UserDefaults = ProcessInfo.processInfo.environment["DUBEL_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard

    @Published var minSizeMB: Double { didSet { Self.defaults.set(minSizeMB, forKey: "minSizeMB") } }
    @Published var includeHidden: Bool { didSet { Self.defaults.set(includeHidden, forKey: "includeHidden") } }
    @Published var excludedPaths: [String] { didSet { Self.defaults.set(excludedPaths, forKey: "excludedPaths") } }
    @Published var quickMode: Bool { didSet { Self.defaults.set(quickMode, forKey: "quickMode") } }
    @Published var photoSensitivity: Sensitivity { didSet { Self.defaults.set(photoSensitivity.rawValue, forKey: "photoSensitivity") } }
    @Published var mediaSensitivity: Sensitivity { didSet { Self.defaults.set(mediaSensitivity.rawValue, forKey: "mediaSensitivity") } }
    @Published var backupVerify: Bool { didSet { Self.defaults.set(backupVerify, forKey: "backupVerify") } }
    @Published var useCache: Bool { didSet { Self.defaults.set(useCache, forKey: "useCache") } }
    /// Reguły automatyczne, cele zgrywania, alarmy, pasek menu. Wszystko domyślnie wyłączone — ustawiane w przewodniku albo w Ustawieniach.
    @Published var auto: Automation { didSet { if let d = try? JSONEncoder().encode(auto) { Self.defaults.set(d, forKey: "automation") } } }

    init() {
        let d = Self.defaults
        minSizeMB = d.object(forKey: "minSizeMB") as? Double ?? 1
        includeHidden = d.bool(forKey: "includeHidden")
        excludedPaths = d.stringArray(forKey: "excludedPaths") ?? []
        quickMode = d.bool(forKey: "quickMode")
        photoSensitivity = Sensitivity(rawValue: d.object(forKey: "photoSensitivity") == nil ? 1 : d.integer(forKey: "photoSensitivity")) ?? .normal
        mediaSensitivity = Sensitivity(rawValue: d.object(forKey: "mediaSensitivity") == nil ? 1 : d.integer(forKey: "mediaSensitivity")) ?? .normal
        backupVerify = d.object(forKey: "backupVerify") as? Bool ?? true
        useCache = d.object(forKey: "useCache") as? Bool ?? true
        auto = d.data(forKey: "automation").flatMap { try? JSONDecoder().decode(Automation.self, from: $0) } ?? Automation()
    }

    func walk(minSize: Int64? = nil, log: ScanLog? = nil) -> WalkOptions {
        WalkOptions(minSize: minSize ?? Int64(minSizeMB * 1_000_000), includeHidden: includeHidden, excludedPaths: excludedPaths + [AppPaths.support.path], log: log)
    }

    static func paths(_ key: String) -> [URL] { (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) } }
    static func setPaths(_ urls: [URL], _ key: String) { defaults.set(urls.map(\.path), forKey: key) }
}

/// Folder, do którego zgrywasz (dysk wewnętrzny, M, T7-2…). Przy każdej karcie wybierasz, który tym razem.
struct Destination: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
    var volumeName: String { VolumeInfo.volumeName(forPath: path) }
    var title: String { url.lastPathComponent == volumeName || path == "/" ? volumeName : "\(volumeName) ▸ \(url.lastPathComponent)" }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Stała para „zawsze porównuj to z tym”.
struct ComparePair: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var target: String
    /// Uruchom porównanie (tylko odczyt), gdy oba miejsca są dostępne po podłączeniu dysku.
    var runOnMount = false
    var isAvailable: Bool { FileManager.default.fileExists(atPath: source) && FileManager.default.fileExists(atPath: target) }
}

struct Automation: Codable, Equatable {
    // Zgrywanie kart
    var cardImportEnabled = false
    var destinations: [Destination] = []
    var lastDestinationID: UUID?
    var folderTemplate = "{data} {karta}"
    var verifyCopies = true
    var askFormatAfterImport = true
    // Dyski
    var checkVolumesOnMount: [String] = []
    var pairs: [ComparePair] = []
    // Alarmy
    var spaceAlarmEnabled = false
    var spaceAlarmPercent: Double = 90
    var weeklyReportEnabled = false
    var lastWeeklyReport: Date?
    var systemWatchEnabled = false
    var systemWatchGrowthGB: Double = 5
    var systemWatchBigFileGB: Double = 2
    var systemWatchIntervalHours: Double = 24
    var lastSystemWatch: Date?
    // Karta: gdzie szukać kopii (puste = wszystkie podłączone dyski + Filmy, Obrazy, Biurko, Pobrane)
    var searchLocations: [String] = []
    var lastCopyFolder: String?
    var keepCardFolders = true
    /// Co zrobić po automatycznym sprawdzeniu karty: „show” — tylko pokaż, „ask” — zapytaj, czy skopiować brakujące
    /// do `cardAutoFolder`, „auto” — kopiuj brakujące od razu (tylko dodaje, nic nie usuwa, każda kopia sprawdzana).
    var cardAfterCheck = "show"
    /// Z karty tylko zdjęcia/wideo/audio (bez XML, bazy aparatu, miniatur).
    var cardMediaOnly = true
    var cardMinSizeMB: Double = 0
    /// Porównanie karty z archiwum bajt po bajcie (wolno przez USB). Domyślnie: rozmiar + fragmenty.
    var cardExact = false
    var cardAutoFolder: String?
    // Wygląd i działanie
    var appIcon = "kat1"
    var hotkeyCheck: HotKeySpec?
    var hotkeyWindow: HotKeySpec?
    /// „rich” = jak przewodnik (poświata, kolorowe ikony trybów), „classic” = natywny, stonowany.
    var uiStyle = "rich"
    /// Tryby ukryte w pasku bocznym (rawValue). „fcp” jest też ukrywany automatycznie, gdy nie ma Final Cut Pro.
    var hiddenModes: [String] = []
    var fcpForced = false
    var tourDone = false
    var menuBarIcon = "cards"
    var showMenuBarIcon = true
    var showInDock = true
    var launchAtLogin = false
    var onboardingDone = false

    init() {}

    // Odporne dekodowanie: nowe pola w przyszłych wersjach nie kasują zapisanych ustawień.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Automation()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        cardImportEnabled = v(.cardImportEnabled, d.cardImportEnabled)
        destinations = v(.destinations, d.destinations)
        lastDestinationID = v(.lastDestinationID, d.lastDestinationID)
        folderTemplate = v(.folderTemplate, d.folderTemplate)
        verifyCopies = v(.verifyCopies, d.verifyCopies)
        askFormatAfterImport = v(.askFormatAfterImport, d.askFormatAfterImport)
        checkVolumesOnMount = v(.checkVolumesOnMount, d.checkVolumesOnMount)
        pairs = v(.pairs, d.pairs)
        spaceAlarmEnabled = v(.spaceAlarmEnabled, d.spaceAlarmEnabled)
        spaceAlarmPercent = v(.spaceAlarmPercent, d.spaceAlarmPercent)
        weeklyReportEnabled = v(.weeklyReportEnabled, d.weeklyReportEnabled)
        lastWeeklyReport = v(.lastWeeklyReport, d.lastWeeklyReport)
        systemWatchEnabled = v(.systemWatchEnabled, d.systemWatchEnabled)
        systemWatchGrowthGB = v(.systemWatchGrowthGB, d.systemWatchGrowthGB)
        systemWatchBigFileGB = v(.systemWatchBigFileGB, d.systemWatchBigFileGB)
        systemWatchIntervalHours = v(.systemWatchIntervalHours, d.systemWatchIntervalHours)
        lastSystemWatch = v(.lastSystemWatch, d.lastSystemWatch)
        searchLocations = v(.searchLocations, d.searchLocations)
        lastCopyFolder = v(.lastCopyFolder, d.lastCopyFolder)
        keepCardFolders = v(.keepCardFolders, d.keepCardFolders)
        cardAfterCheck = v(.cardAfterCheck, d.cardAfterCheck)
        cardMediaOnly = v(.cardMediaOnly, d.cardMediaOnly)
        cardMinSizeMB = v(.cardMinSizeMB, d.cardMinSizeMB)
        cardExact = v(.cardExact, d.cardExact)
        cardAutoFolder = v(.cardAutoFolder, d.cardAutoFolder)
        appIcon = v(.appIcon, d.appIcon)
        hotkeyCheck = v(.hotkeyCheck, d.hotkeyCheck)
        hotkeyWindow = v(.hotkeyWindow, d.hotkeyWindow)
        uiStyle = v(.uiStyle, d.uiStyle)
        hiddenModes = v(.hiddenModes, d.hiddenModes)
        fcpForced = v(.fcpForced, d.fcpForced)
        tourDone = v(.tourDone, d.tourDone)
        menuBarIcon = v(.menuBarIcon, d.menuBarIcon)
        showMenuBarIcon = v(.showMenuBarIcon, d.showMenuBarIcon)
        showInDock = v(.showInDock, d.showInDock)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        onboardingDone = v(.onboardingDone, d.onboardingDone)
    }

    /// Gdzie szukać kopii plików z karty. Domyślnie: wszystkie podłączone dyski (poza samą kartą) + typowe foldery.
    func copySearchRoots(excluding card: URL?) -> [URL] {
        if !searchLocations.isEmpty { return searchLocations.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = ["Movies", "Pictures", "Desktop", "Downloads"].map { home.appendingPathComponent($0) }
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        roots += vols.filter { $0.path.hasPrefix("/Volumes/") && $0.standardizedFileURL != card?.standardizedFileURL && !CameraCard.isCard($0) }
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var richUI: Bool { uiStyle != "classic" }

    var anyRuleEnabled: Bool { cardImportEnabled || !checkVolumesOnMount.isEmpty || pairs.contains(where: \.runOnMount) || spaceAlarmEnabled || weeklyReportEnabled || systemWatchEnabled }
}

enum AppPaths {
    static var support: URL {
        if let dev = ProcessInfo.processInfo.environment["DUBEL_DATA_DIR"] { return URL(fileURLWithPath: dev) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dubel")
    }
    static var cacheFile: URL { support.appendingPathComponent("odciski.json") }
    static var watchFile: URL { support.appendingPathComponent("pomiary.json") }
}
