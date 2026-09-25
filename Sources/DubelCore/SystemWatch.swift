import Foundation

/// Pilnowanie „Danych systemowych”: miejsca, które rosną po cichu (cache, symulatory, kopie iPhone'a…).
/// Tylko liczy i porównuje z poprzednim pomiarem — niczego nie usuwa.
public struct Hotspot: Sendable, Identifiable, Hashable {
    /// Celowo bez „można czyścić”: nawet odtwarzalne dane usuwane ręcznie przy otwartej aplikacji potrafią ją zepsuć.
    public enum Safety: String, Sendable { case safe = "Program odtworzy", careful = "Ostrożnie", keep = "Nie ruszaj" }
    public let id: String
    public let title: String
    public let path: String
    public let explanation: String
    public let safety: Safety
    public let symbol: String
}

public enum Hotspots {
    public static func all(home: String = NSHomeDirectory()) -> [Hotspot] {
        func h(_ id: String, _ title: String, _ rel: String, _ why: String, _ s: Hotspot.Safety, _ sym: String) -> Hotspot {
            Hotspot(id: id, title: CoreText.t(title), path: rel.hasPrefix("/") ? rel : home + "/" + rel, explanation: CoreText.t(why), safety: s, symbol: sym)
        }
        return [
            h("caches", "Pamięć podręczna aplikacji", "Library/Caches", "Tymczasowe pliki programów. Programy odtwarzają je same, ale usuwane ręcznie przy otwartej aplikacji potrafią ją zepsuć. Jeśli już — tylko cache konkretnej, zamkniętej aplikacji.", .safe, "internaldrive"),
            h("fcp-app", "Final Cut Pro — dane aplikacji", "Library/Application Support/Final Cut Pro", "Ustawienia i dane pomocnicze FCP. Rendery są w bibliotekach (zakładka Pliki Final Cut).", .keep, "film"),
            h("cacheclip", "CacheClip", "Movies/CacheClip", "Cache wtyczki/aplikacji CacheClip w folderze Filmy.", .careful, "film.stack"),
            h("adobe-media", "Adobe — cache mediów", "Library/Application Support/Adobe/Common", "Media Cache i pliki pomocnicze Premiere/After Effects. Da się wyczyścić z poziomu Premiere (Ustawienia → Pamięć podręczna mediów).", .safe, "a.square"),
            h("adobe-docs", "Adobe — podglądy w Dokumentach", "Documents/Adobe", "Podglądy renderów i audio Premiere (m.in. „Audio Previews”). Premiere odtworzy je przy otwarciu projektu — czyść z poziomu Premiere, nie ręcznie. Leży w iCloud (Dokumenty).", .safe, "a.square"),
            h("simulators", "Symulatory iPhone (Xcode)", "Library/Developer/CoreSimulator", "Urządzenia i dane symulatorów iOS. Czyści się w Xcode → Settings → Platforms albo poleceniem „xcrun simctl delete unavailable”.", .careful, "iphone"),
            h("derived", "Xcode — pliki budowania", "Library/Developer/Xcode/DerivedData", "Pośrednie pliki budowania aplikacji. Xcode odtworzy je sam — czyść w Xcode (Product → Clean Build Folder), przy zamkniętym projekcie.", .safe, "hammer"),
            h("iphone-backups", "Kopie zapasowe iPhone'a", "Library/Application Support/MobileSync/Backup", "Lokalne kopie iPhone'a/iPada z Findera. Usuwaj tylko przez Finder → iPhone → Zarządzaj kopiami.", .careful, "iphone.gen3"),
            h("containers", "Kontenery aplikacji", "Library/Containers", "Dane aplikacji z App Store (w tym ich własne cache). Nie usuwaj ręcznie — czyść w samej aplikacji.", .keep, "shippingbox"),
            h("group-containers", "Wspólne dane aplikacji", "Library/Group Containers", "Dane współdzielone przez aplikacje (np. WhatsApp, Office). Czyść w samej aplikacji.", .keep, "square.stack.3d.up"),
            h("messages", "Załączniki Wiadomości", "Library/Messages/Attachments", "Zdjęcia i filmy z iMessage. Czyść w Wiadomościach (Ustawienia → zachowuj wiadomości).", .careful, "message"),
            h("mail", "Poczta", "Library/Mail", "Skrzynki i załączniki Mail.", .keep, "envelope"),
            h("trash", "Kosz", ".Trash", "Pliki w Koszu nadal zajmują miejsce, dopóki go nie opróżnisz. Opróżnienie jest nieodwracalne — najpierw przejrzyj zawartość.", .safe, "trash"),
            h("logs", "Logi", "Library/Logs", "Dzienniki programów. Zwykle małe — nagły wzrost zwykle oznacza, że jakiś program ma problem. Lepiej znaleźć przyczynę niż kasować.", .safe, "doc.text"),
            h("dev-cache", "Cache narzędzi (npm, pip…)", ".cache", "Pobrane pakiety narzędzi programistycznych. Narzędzia pobiorą je ponownie, gdy będą potrzebne.", .safe, "shippingbox"),
            h("npm", "npm", ".npm", "Pobrane pakiety Node.js. Czyść poleceniem „npm cache clean”, nie ręcznie.", .safe, "shippingbox"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct HotspotMeasure: Codable, Sendable, Hashable {
    public var size: Int64
    /// Duże pliki (powyżej progu) z datą modyfikacji — do wykrycia „nagle pojawił się plik 8 GB”.
    public var bigFiles: [String: Int64]
    public var noAccess: Bool
    /// Rozmiary podfolderów pierwszego poziomu (kto w środku zajmuje miejsce, np. cache konkretnej aplikacji).
    public var children: [String: Int64] = [:]
}

public struct WatchSnapshot: Codable, Sendable {
    public var date: Date
    public var spots: [String: HotspotMeasure]
    public var localSnapshots: Int
    public var freeBytes: Int64
}

public struct WatchChange: Sendable, Identifiable, Hashable {
    public let spot: Hotspot
    public let size: Int64
    public let delta: Int64?
    public let newBigFiles: [(path: String, size: Int64)]
    public let noAccess: Bool
    public var children: [(name: String, size: Int64, delta: Int64?)] = []
    public var id: String { spot.id }
    public static func == (a: WatchChange, b: WatchChange) -> Bool { a.id == b.id && a.size == b.size && a.delta == b.delta }
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(size) }
}

public enum SystemWatch {
    public static func measure(_ spots: [Hotspot], bigFileThreshold: Int64, progress: ProgressHandler?) throws -> WatchSnapshot {
        var out: [String: HotspotMeasure] = [:]
        for (i, s) in spots.enumerated() {
            try Task.checkCancellation()
            progress?(ScanProgress(phase: .measuring, done: i, total: spots.count, current: s.path))
            out[s.id] = try measure(URL(fileURLWithPath: s.path), threshold: bigFileThreshold)
        }
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { Int64($0) } ?? 0
        progress?(ScanProgress(phase: .done, done: spots.count, total: spots.count))
        return WatchSnapshot(date: Date(), spots: out, localSnapshots: localSnapshotCount(), freeBytes: free)
    }

    static func measure(_ url: URL, threshold: Int64) throws -> HotspotMeasure {
        var denied = false
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
                                                      options: [], errorHandler: { _, _ in denied = true; return true }) else { return HotspotMeasure(size: 0, bigFiles: [:], noAccess: true) }
        var total: Int64 = 0
        var big: [String: Int64] = [:]
        var children: [String: Int64] = [:]
        let base = url.standardizedFileURL.path.count + 1
        var n = 0
        for case let f as URL in en {
            n += 1
            if n % 5000 == 0 { try Task.checkCancellation() }
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            let sz = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            total += sz
            if sz >= threshold { big[f.path] = sz }
            let p = f.standardizedFileURL.path
            if p.count > base, let first = p.dropFirst(base).split(separator: "/", maxSplits: 1).first { children[String(first), default: 0] += sz }
        }
        // Tylko największe 12 — reszta to drobnica.
        let top = Dictionary(uniqueKeysWithValues: children.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) })
        return HotspotMeasure(size: total, bigFiles: big, noAccess: denied && total == 0, children: top)
    }

    /// Lokalne migawki Time Machine — potrafią trzymać dziesiątki GB jako „Dane systemowe”.
    public static func localSnapshotCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }

    /// Porównanie z poprzednim pomiarem. Zwraca wszystkie miejsca (posortowane od największego wzrostu).
    public static func compare(_ now: WatchSnapshot, previous: WatchSnapshot?, spots: [Hotspot]) -> [WatchChange] {
        spots.compactMap { s in
            guard let m = now.spots[s.id] else { return nil }
            let prev = previous?.spots[s.id]
            let newBig = m.bigFiles.filter { prev?.bigFiles[$0.key] == nil || (prev?.bigFiles[$0.key] ?? 0) < $0.value / 2 }
                .map { (path: $0.key, size: $0.value) }.sorted { $0.size > $1.size }
            var c = WatchChange(spot: s, size: m.size, delta: prev.map { m.size - $0.size }, newBigFiles: previous == nil ? [] : newBig, noAccess: m.noAccess)
            c.children = m.children.sorted { $0.value > $1.value }.map { kv in (name: kv.key, size: kv.value, delta: prev.map { p in kv.value - (p.children[kv.key] ?? 0) }) }
            return c
        }
        .sorted { ($0.delta ?? 0, $0.size) > ($1.delta ?? 0, $1.size) }
    }

    /// Czy coś urosło „nieoczekiwanie”: o więcej niż próg od poprzedniego pomiaru albo pojawił się nowy duży plik.
    public static func alarms(_ changes: [WatchChange], growthThreshold: Int64) -> [WatchChange] {
        changes.filter { ($0.delta ?? 0) >= growthThreshold || !$0.newBigFiles.isEmpty }
    }
}

private func > (a: (Int64, Int64), b: (Int64, Int64)) -> Bool { a.0 != b.0 ? a.0 > b.0 : a.1 > b.1 }
