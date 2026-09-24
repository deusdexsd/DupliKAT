import AppKit

// Cykl życia w AppKit (nie SwiftUI App): potrzebny do ikony w pasku menu, działania w tle i kilku niezależnych okien.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
