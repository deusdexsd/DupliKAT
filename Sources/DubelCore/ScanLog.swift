import Foundation

/// Dziennik skanu: co zostało pominięte i dlaczego. Pokazywany w UI, żeby było widać, że skan „coś robi”
/// i czego nie dotknął (np. pliki trzymane tylko w iCloud — czytanie ich wymusiłoby pobieranie i zajmowało dysk).
public final class ScanLog: @unchecked Sendable {
    public enum Reason: String, Sendable, CaseIterable {
        case iCloud = "Tylko w iCloud — nie pobrany na dysk"
        case protected = "Folder chroniony (biblioteka FCP, szablony Motion…)"
        case noAccess = "Brak dostępu"
        case unreadable = "Nie udało się odczytać"
    }

    public struct Entry: Sendable, Identifiable, Hashable {
        public let id = UUID()
        public let path: String
        public let reason: Reason
    }

    private var entries: [Entry] = []
    private let lock = NSLock()
    public init() {}

    public func skip(_ url: URL, _ reason: Reason) { lock.withLock { entries.append(Entry(path: url.path, reason: reason)) } }
    public var all: [Entry] { lock.withLock { entries } }
    public var count: Int { lock.withLock { entries.count } }
    public func count(_ r: Reason) -> Int { lock.withLock { entries.filter { $0.reason == r }.count } }
}
