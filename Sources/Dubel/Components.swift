import AppKit
import DubelCore
import MidniteUIKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Gdzie szukać

/// Karta z listą folderów/dysków. Foldery można przeciągnąć z Findera.
struct LocationsCard: View {
    let title: String
    var hint: String? = nil
    @Binding var urls: [URL]
    @EnvironmentObject var app: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title).padding(.leading, 4)
            Card(padding: 10, radius: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    if urls.isEmpty {
                        Label(hint ?? "Nic jeszcze nie wybrano — dodaj folder albo dysk", systemImage: "tray")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(urls, id: \.self) { u in LocationChip(url: u) { urls.removeAll { $0 == u } } }
                        }
                    }
                    HStack(spacing: 8) {
                        Menu {
                            Button { urls = merged(urls + FileActions.chooseFolder(title: title, prompt: "Dodaj", multiple: true)) } label: {
                                Label("Wybierz folder lub dysk…", systemImage: "folder.badge.plus")
                            }
                            let places = app.quickPlaces
                            Section("Dyski") {
                                ForEach(places.filter { $0.symbol == "externaldrive" }, id: \.url) { p in
                                    Button { urls = merged(urls + [p.url]) } label: { Label(p.title, systemImage: p.symbol) }
                                }
                            }
                            Section("Foldery") {
                                ForEach(places.filter { $0.symbol != "externaldrive" }, id: \.url) { p in
                                    Button { urls = merged(urls + [p.url]) } label: { Label(p.title, systemImage: p.symbol) }
                                }
                            }
                        } label: { Label("Dodaj miejsce", systemImage: "plus") }
                            .fixedSize()
                            .help("Wybierz folder albo dysk — możesz też przeciągnąć folder z Findera")
                        Text("albo przeciągnij tu folder z Findera").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Spacer()
                        if !urls.isEmpty {
                            Button("Wyczyść") { urls = [] }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.primary.opacity(targeted ? 0.9 : 0), lineWidth: 1.5))
            .coachAnchor("locations")
            .dropDestination(for: URL.self) { dropped, _ in
                urls = merged(urls + dropped.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
                return true
            } isTargeted: { targeted = $0 }
        }
    }

    private func merged(_ list: [URL]) -> [URL] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

struct LocationChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hover = false

    var isVolume: Bool { url.path.hasPrefix("/Volumes/") && url.pathComponents.count == 3 }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isVolume ? "externaldrive" : "folder").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if !isVolume {
                Text(VolumeInfo.volumeName(forPath: url.path)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover ? 1 : 0.5)
                .accessibilityLabel("Usuń \(url.lastPathComponent)").help("Usuń z listy")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(hover ? 0.09 : 0.06)))
        .onHover { hover = $0 }
        .help(Fmt.path(url.path))
    }
}

// MARK: - Postęp

/// Postęp z tym, co naprawdę widać: aktualny plik (pełna ścieżka), prędkość, ile zostało, co pominięto i dlaczego.
struct ProgressCard: View {
    let progress: ScanProgress
    var log: ScanLog? = nil
    let onCancel: () -> Void
    @State private var started = Date()
    @State private var samples: [(t: Date, bytes: Int64, done: Int)] = []
    @State private var showSkipped = false

    var body: some View {
        Card(padding: 12, radius: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress.phase.rawValue).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Button("Przerwij", action: onCancel).controlSize(.small)
                }
                if let f = progress.fraction { ProgressView(value: f).tint(Theme.accent.primary) } else { ProgressView().progressViewStyle(.linear).tint(Theme.accent.primary) }
                HStack(spacing: 10) {
                    Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(progress.current.isEmpty ? "…" : Fmt.path(progress.current))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(speed).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    if let log, log.count > 0 {
                        Button { showSkipped = true } label: {
                            Label("Pominięto \(log.count)", systemImage: "eye.slash").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showSkipped) { SkippedList(log: log) }
                        .help("Co zostało pominięte i dlaczego")
                    }
                }
            }
        }
        .onChange(of: progress) { _, p in
            let now = Date()
            samples.append((now, p.bytesDone, p.done))
            samples.removeAll { now.timeIntervalSince($0.t) > 4 }
        }
        .onAppear { started = Date() }
    }

    var detail: String {
        if progress.bytesTotal > 0 { return "\(Fmt.bytes(progress.bytesDone)) z \(Fmt.bytes(progress.bytesTotal))" }
        if progress.total > 0 { return "\(progress.done) z \(progress.total)" }
        if progress.done > 0 { return "\(progress.done) sprawdzonych" }
        return ""
    }

    /// Prędkość z ostatnich ~4 s i szacowany czas do końca.
    var speed: String {
        guard let a = samples.first, let b = samples.last, b.t.timeIntervalSince(a.t) > 0.5 else { return "" }
        let dt = b.t.timeIntervalSince(a.t)
        if progress.bytesTotal > 0 {
            let rate = Double(b.bytes - a.bytes) / dt
            guard rate > 0 else { return "czekam na dysk…" }
            let left = Double(progress.bytesTotal - progress.bytesDone) / rate
            return "\(Fmt.bytes(Int64(rate)))/s · \(Fmt.eta(left))"
        }
        let rate = Double(b.done - a.done) / dt
        guard rate > 0 else { return dt > 3 ? "czekam na dysk…" : "" }
        let left = progress.total > 0 ? " · \(Fmt.eta(Double(progress.total - progress.done) / rate))" : ""
        return "\(Int(rate.rounded())) plików/s" + left
    }
}

struct SkippedList: View {
    let log: ScanLog
    var body: some View {
        let all = log.all
        VStack(alignment: .leading, spacing: 8) {
            Text("Pominięte (\(all.count))").font(.system(size: 13, weight: .semibold))
            ForEach(ScanLog.Reason.allCases, id: \.self) { r in
                let n = all.filter { $0.reason == r }.count
                if n > 0 { Text("\(r.rawValue): \(n)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(all.prefix(500)) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: e.reason == .iCloud ? "icloud" : e.reason == .protected ? "lock" : "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                            Text(Fmt.path(e.path)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    if all.count > 500 { Text("…i \(all.count - 500) więcej").font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
            }
            .frame(height: 260)
            if all.contains(where: { $0.reason == .iCloud }) {
                Text("Pliki trzymane tylko w iCloud są pomijane celowo: odczyt wymusiłby pobieranie ich na dysk.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 460)
    }
}

/// Główna liczba ekranu (jedyne miejsce z gradientem marki) + podział na rodzaje.
struct HeroNumber: View {
    let caption: String
    let value: String
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Caption(caption)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.accent.gradient)
            if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

/// Pasek podziału (np. ile z odzyskiwanego miejsca to wideo, audio…) z legendą.
struct BreakdownBar: View {
    let parts: [(title: String, color: Color, value: Int64)]

    var body: some View {
        let parts = self.parts.filter { $0.value > 0 }
        let total = max(1, parts.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(parts[i].color.gradient)
                            .frame(width: max(3, (geo.size.width - CGFloat(parts.count) * 2) * CGFloat(parts[i].value) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 8)
            FlowLayout(spacing: 12) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle().fill(parts[i].color).frame(width: 7, height: 7)
                        Text(parts[i].title).font(.system(size: 11))
                        Text(Fmt.bytes(parts[i].value)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - Miniatury

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, size: CGFloat) async -> NSImage {
        let key = "\(url.path)@\(Int(size))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        let img: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            img = rep.nsImage
        } else {
            img = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

struct Thumbnail: View {
    let url: URL
    var size: CGFloat = 34
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url, size: size) }
    }
}

// MARK: - Pusty stan / błąd

struct EmptyHint: View {
    let symbol: String
    let title: String
    let text: String
    @Environment(\.richUI) private var rich

    var body: some View {
        VStack(spacing: 8) {
            if rich {
                IconCircle(symbol: symbol, color: Color.secondary, on: false, size: 52)
            } else {
                Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// Nagłówek trybu: tytuł + jedno zdanie, co robi.
struct ModeHeader<Trailing: View>: View {
    let mode: Mode
    @ViewBuilder var trailing: Trailing
    @Environment(\.richUI) private var rich

    var body: some View {
        HStack(alignment: rich ? .center : .firstTextBaseline, spacing: 14) {
            if rich {
                IconCircle(symbol: mode.symbol, color: mode.color, size: 44).shadow(color: mode.color.opacity(0.35), radius: 12, y: 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.title).font(.system(size: rich ? 22 : 20, weight: .bold))
                Text(mode.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
    }
}

extension ModeHeader where Trailing == EmptyView {
    init(mode: Mode) { self.mode = mode; self.trailing = EmptyView() }
}

/// Przycisk startu skanu (gradient marki) — jedyny „głośny” przycisk na ekranie.
struct ScanButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: "magnifyingglass").font(.system(size: 12.5, weight: .semibold)) }
            .buttonStyle(GradientButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .keyboardShortcut("r", modifiers: .command)
            .help("Szukaj (⌘R)")
            .coachAnchor("scan")
    }
}

struct StatusFooter: View {
    let status: ScanStatus
    var log: ScanLog? = nil
    @State private var showSkipped = false
    var body: some View {
        switch status {
        case .finished(let d):
            HStack(spacing: 8) {
                if let log, log.count > 0 {
                    Button { showSkipped = true } label: { Label("pominięto \(log.count)", systemImage: "eye.slash") }
                        .buttonStyle(.borderless).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .popover(isPresented: $showSkipped) { SkippedList(log: log) }
                }
                Text("Sprawdzono \(d.formatted(date: .omitted, time: .shortened))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        case .failed(let e): Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.missing)
        default: EmptyView()
        }
    }
}
