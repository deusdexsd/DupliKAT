import AppKit
import CryptoKit
import DubelCore
import Foundation

/// Wszystko, co zmienia pliki na dysku. Wywoływane WYŁĄCZNIE po potwierdzeniu w oknie ConfirmSheet — aplikacja
/// niczego nie robi sama. Każda operacja jest odwracalna (Kosz, przeniesienie) albo sprawdza zawartość przed zmianą (klon).
enum FileActions {
    struct Outcome {
        var done: [URL] = []
        var failed: [(URL, String)] = []
        var summary: String
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(200)))
    }

    /// Do Kosza (każdy dysk ma własny Kosz — miejsce wraca dopiero po jego opróżnieniu).
    static func trash(_ urls: [URL]) async -> Outcome {
        await Task.detached {
            var o = Outcome(summary: "")
            for u in urls {
                do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); o.done.append(u) } catch { o.failed.append((u, error.localizedDescription)) }
            }
            o.summary = "Przeniesiono do Kosza: \(Fmt.files(o.done.count))" + (o.failed.isEmpty ? "" : ", nie udało się: \(o.failed.count)")
            return o
        }.value
    }

    /// Przeniesienie do wybranego folderu. Przy konflikcie nazw dopisuje „ (2)”, „ (3)”…
    static func move(_ urls: [URL], to folder: URL) async -> Outcome {
        await Task.detached {
            var o = Outcome(summary: "")
            let fm = FileManager.default
            for u in urls {
                var dest = folder.appendingPathComponent(u.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: dest.path) {
                    dest = folder.appendingPathComponent("\(u.deletingPathExtension().lastPathComponent) (\(n))").appendingPathExtension(u.pathExtension)
                    n += 1
                }
                do { try fm.moveItem(at: u, to: dest); o.done.append(u) } catch { o.failed.append((u, error.localizedDescription)) }
            }
            o.summary = "Przeniesiono: \(Fmt.files(o.done.count)) do „\(folder.lastPathComponent)”" + (o.failed.isEmpty ? "" : ", nie udało się: \(o.failed.count)")
            return o
        }.value
    }

    /// Zastępuje kopię klonem APFS pliku, który zostaje: plik dalej jest w obu miejscach, ale dane zajmują miejsce raz.
    /// Przed zamianą ponownie porównuje pełną zawartość obu plików — jeśli coś się zmieniło od skanu, pomija.
    static func replaceWithClones(_ pairs: [(duplicate: URL, keeper: URL)]) async -> Outcome {
        await Task.detached {
            var o = Outcome(summary: "")
            for (dup, keeper) in pairs {
                do { try CloneReplacer.replace(duplicate: dup, withCloneOf: keeper); o.done.append(dup) }
                catch { o.failed.append((dup, "\(error)")) }
            }
            o.summary = "Zastąpiono klonami: \(Fmt.files(o.done.count))" + (o.failed.isEmpty ? "" : ", pominięto: \(o.failed.count)")
            return o
        }.value
    }

    /// Kopiuje brakujące pliki do archiwum, zachowując strukturę folderów względem źródła. Istniejących nie nadpisuje.
    static func copy(_ files: [URL], relativeTo roots: [URL], into dest: URL, progress: @escaping @Sendable (Int, Int) -> Void) async -> Outcome {
        await Task.detached {
            var o = Outcome(summary: "")
            let fm = FileManager.default
            for (i, u) in files.enumerated() {
                progress(i, files.count)
                let root = roots.map { FileWalker.canonical($0.path) }.filter { u.path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
                let rootName = root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                let rel = root.map { String(u.path.dropFirst($0.count + 1)) } ?? u.lastPathComponent
                let target = dest.appendingPathComponent(rootName).appendingPathComponent(rel)
                if fm.fileExists(atPath: target.path) { o.failed.append((u, "w archiwum jest już plik o tej nazwie")); continue }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: u, to: target)
                    o.done.append(u)
                } catch { o.failed.append((u, error.localizedDescription)) }
            }
            progress(files.count, files.count)
            o.summary = "Skopiowano do archiwum: \(Fmt.files(o.done.count))" + (o.failed.isEmpty ? "" : ", pominięto: \(o.failed.count)")
            return o
        }.value
    }

    /// Lista grup jako CSV (otwiera się w Numbers/Excelu).
    static func csv(groups: [DuplicateGroup]) -> String {
        var lines = ["grupa;dopasowanie;plik;folder;dysk;rozmiar_bajty;zmodyfikowano"]
        let iso = ISO8601DateFormatter()
        for (i, g) in groups.enumerated() {
            let match: String
            switch g.match {
            case .identical: match = "identyczne"
            case .sampled: match = "prawie na pewno identyczne"
            case .similar(let s): match = "podobne \(Fmt.percent(s))"
            }
            for f in g.files {
                lines.append([String(i + 1), match, f.name, f.folder, f.volumeName, String(f.size), iso.string(from: f.modified)]
                    .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func saveCSV(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.data(using: .utf8)?.write(to: url)
    }

    @MainActor
    static func chooseFolder(title: String, prompt: String, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = true
        panel.message = title
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
    }

    static var isFinalCutRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut").isEmpty }

    /// Uruchomione programy do montażu spośród podanych (nie usuwamy plików spod otwartego programu).
    static func runningEditors(_ apps: Set<EditorApp>) -> [EditorApp] {
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return apps.filter { a in ids.contains { id in a.bundlePrefixes.contains { id.hasPrefix($0) } } }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Czy program jest na tym Macu (po identyfikatorze albo po nazwie w /Applications).
    static func isInstalled(_ app: EditorApp) -> Bool {
        let ws = NSWorkspace.shared
        if app.bundlePrefixes.contains(where: { ws.urlForApplication(withBundleIdentifier: $0) != nil }) { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        switch app {
        case .adobe: return names.contains { $0.hasPrefix("Adobe Premiere") || $0.hasPrefix("Adobe After Effects") }
        case .davinci: return names.contains { $0.hasPrefix("DaVinci Resolve") }
        case .capcut: return names.contains { $0.hasPrefix("CapCut") || $0.contains("剪映") || $0.hasPrefix("Jianying") } || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Movies/JianyingPro")
        case .finalCut: return names.contains { $0.hasPrefix("Final Cut Pro") }
        }
    }
}
