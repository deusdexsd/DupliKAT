import Foundation

/// Zastępuje kopię klonem APFS pliku, który zostaje: plik dalej jest w obu miejscach, ale dane zajmują miejsce raz.
public enum CloneReplacer {
    public enum Failure: Error, CustomStringConvertible {
        case contentDiffers, cloneFailed(String), renameFailed(String)
        public var description: String {
            switch self {
            case .contentDiffers: return "zawartość różni się od pliku, który zostaje"
            case .cloneFailed(let e): return "nie udało się utworzyć klonu (\(e))"
            case .renameFailed(let e): return "nie udało się podmienić pliku (\(e))"
            }
        }
    }

    /// Przed zamianą ponownie porównuje pełną zawartość — jeśli coś się zmieniło od skanu, nic nie robi.
    /// Zachowuje daty i uprawnienia kopii. Podmiana przez rename(2) jest atomowa: nie ma chwili, w której pliku nie ma.
    public static func replace(duplicate dup: URL, withCloneOf keeper: URL) throws {
        guard let h1 = try? ContentHasher.fullHash(dup), let h2 = try? ContentHasher.fullHash(keeper), h1 == h2 else { throw Failure.contentDiffers }
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: dup.path)
        let tmp = dup.deletingLastPathComponent().appendingPathComponent(".dubel-klon-\(UUID().uuidString)")
        guard clonefile(keeper.path, tmp.path, 0) == 0 else { throw Failure.cloneFailed(String(cString: strerror(errno))) }
        var keep: [FileAttributeKey: Any] = [:]
        for k in [FileAttributeKey.modificationDate, .creationDate, .posixPermissions] { keep[k] = attrs[k] }
        try? fm.setAttributes(keep, ofItemAtPath: tmp.path)
        guard rename(tmp.path, dup.path) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw Failure.renameFailed(err)
        }
    }
}
