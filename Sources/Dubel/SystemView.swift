import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

struct SystemScreen: View {
    @ObservedObject var model: SystemModel
    @EnvironmentObject var prefs: Prefs
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ModeHeader(mode: .system) { StatusFooter(status: model.status) }
                HStack(spacing: 12) {
                    if let c = model.current {
                        Label(T("Lokalne migawki Time Machine: %@", "\(c.localSnapshots)"), systemImage: "clock.arrow.circlepath").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .help(T("Migawki potrafią zajmować dziesiątki GB jako „Dane systemowe”. macOS usuwa je sam, gdy brakuje miejsca."))
                    }
                    Spacer()
                    Toggle(T("Pilnuj automatycznie"), isOn: Binding(get: { prefs.auto.systemWatchEnabled }, set: { prefs.auto.systemWatchEnabled = $0; if $0 { Notifier.request() } }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                        .help(T("Pomiar w tle co %@ h. Powiadomienie, gdy coś urośnie o %@ GB albo pojawi się plik większy niż %@ GB.", "\(Int(prefs.auto.systemWatchIntervalHours))", "\(Int(prefs.auto.systemWatchGrowthGB))", "\(Int(prefs.auto.systemWatchBigFileGB))"))
                    ScanButton(title: T("Zmierz teraz"), enabled: !model.status.isRunning) { model.measure() }
                }
                .controlSize(.small)
                if case .running(let p) = model.status { ProgressCard(progress: p) { model.cancel() } }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider()
            if model.changes.isEmpty {
                EmptyHint(symbol: "gauge.with.dots.needle.67percent", title: T("Co zjada miejsce?"),
                          text: T("Zmierzę cache, symulatory, kopie iPhone'a, logi i inne miejsca, które macOS pokazuje jako „Dane systemowe”. Pierwszy pomiar trwa kilka minut. Kolejne pokażą, co urosło od ostatniego razu."))
            } else { list }
        }
    }

    var list: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 24) {
                    HeroNumber(caption: T("Pod lupą"), value: Fmt.bytes(model.total),
                               sub: model.totalDelta.map { d in T("od poprzedniego pomiaru: %@%@", "\(d >= 0 ? "+" : "−")", "\(Fmt.bytes(abs(d)))") } ?? T("pierwszy pomiar — zmiany zobaczysz przy następnym"))
                    Spacer()
                    if let c = model.current {
                        VStack(alignment: .trailing, spacing: 2) {
                            Caption(T("Wolne na dysku startowym"))
                            Text(Fmt.bytes(c.freeBytes)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(T("stan z %@", "\(c.date.formatted(date: .abbreviated, time: .shortened))")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                HStack(alignment: .top, spacing: 12) {
                    IconCircle(symbol: "exclamationmark.shield.fill", color: Theme.warn, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(T("To tylko podgląd — DupliKAT niczego tu nie usuwa")).font(.system(size: 12.5, weight: .semibold))
                        Text(T("Te foldery należą do macOS i innych aplikacji. Jeśli chcesz coś wyczyścić, rób to z poziomu aplikacji, do której to należy, przy zamkniętym programie. Nie masz pewności, co to jest? Nie ruszaj. „Program odtworzy” znaczy tylko tyle, że dane da się odtworzyć — nie, że usunięcie jest bez ryzyka."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warn.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warn.opacity(0.3)))
            }
            ForEach(model.changes) { c in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(c.id) }, set: { if $0 { expanded.insert(c.id) } else { expanded.remove(c.id) } })) {
                    detail(c)
                } label: { row(c) }
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
    }

    func row(_ c: WatchChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.spot.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.spot.title).font(.system(size: 12.5, weight: .semibold))
                    SafetyBadge(safety: c.spot.safety)
                    if !c.newBigFiles.isEmpty { Text(T("nowy duży plik")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.missing) }
                }
                Text(c.noAccess ? T("Brak dostępu — macOS chroni ten folder (Pełny dostęp do dysku w Ustawieniach systemowych).") : c.spot.explanation)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            DeltaText(delta: c.delta)
            Text(c.noAccess ? T("—") : Fmt.bytes(c.size)).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    func detail(_ c: WatchChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(c.newBigFiles.prefix(10), id: \.path) { f in
                HStack {
                    Label(Fmt.path(f.path), systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.missing).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.bytes(f.size)).font(.system(size: 11)).monospacedDigit()
                    Button { FileActions.reveal([URL(fileURLWithPath: f.path)]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(T("Pokaż w Finderze"))
                }
            }
            ForEach(c.children, id: \.name) { ch in
                HStack {
                    Text(ch.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    DeltaText(delta: ch.delta)
                    Text(Fmt.bytes(ch.size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    Button { FileActions.reveal([URL(fileURLWithPath: c.spot.path).appendingPathComponent(ch.name)]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help(T("Pokaż w Finderze")).accessibilityLabel(T("Pokaż %@ w Finderze", "\(ch.name)"))
                }
            }
            Text(c.spot.safety == .keep ? T("Nie usuwaj tego ręcznie — czyść wyłącznie z poziomu aplikacji, do której należy.") : T("DupliKAT niczego tu nie usuwa. Jeśli już sprzątasz — z poziomu aplikacji, do której to należy, przy zamkniętym programie."))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.leading, 28).padding(.vertical, 4)
    }
}

struct SafetyBadge: View {
    let safety: Hotspot.Safety
    var color: Color { safety == .safe ? Color.secondary : safety == .careful ? Theme.warn : Theme.missing }
    var body: some View {
        Text(T(safety.rawValue)).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct DeltaText: View {
    let delta: Int64?
    var body: some View {
        if let d = delta, abs(d) >= 10_000_000 {
            Text((d > 0 ? "+" : "−") + Fmt.bytes(abs(d))).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(d > 0 ? Theme.missing : Theme.safe)
        }
    }
}
