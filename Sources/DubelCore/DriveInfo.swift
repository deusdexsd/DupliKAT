import Foundation
import IOKit

/// Co to za dysk i jak jest podłączony: model, złącze (USB / Thunderbolt / wewnętrzny / czytnik SD) i prędkość łącza.
/// Czytane z rejestru IOKit — tylko odczyt, trwa milisekundy.
public struct DriveInfo: Sendable, Equatable {
    public var model: String?
    public var vendor: String?
    /// „USB”, „PCI-Express”, „Apple Fabric”, „Thunderbolt”, „SD”…
    public var interconnect: String?
    public var isInternal = false
    /// Prędkość łącza w bitach na sekundę (dla USB).
    public var linkSpeed: Int64?

    /// „Samsung PSSD T7” — producent + model, bez powtórzeń.
    public var displayModel: String? {
        let m = model?.trimmingCharacters(in: .whitespaces), v = vendor?.trimmingCharacters(in: .whitespaces)
        guard let m, !m.isEmpty else { return v?.isEmpty == false ? v : nil }
        if let v, !v.isEmpty, !m.lowercased().contains(v.lowercased()) { return "\(v) \(m)" }
        return m
    }

    /// Nazwa standardu dla prędkości łącza USB.
    public var usbStandard: String? {
        guard let s = linkSpeed else { return nil }
        switch s {
        case ..<13_000_000: return "USB 1.1"
        case ..<500_000_000: return "USB 2.0"
        case ..<6_000_000_000: return "USB 3.2 Gen 1"
        case ..<15_000_000_000: return "USB 3.2 Gen 2"
        case ..<30_000_000_000: return "USB 3.2 Gen 2x2"
        default: return "USB4"
        }
    }

    /// Łącze wolniejsze niż 5 Gb/s dla dysku (nie karty) — zwykle zły kabel albo port USB 2.0.
    public var isSlowLink: Bool { (linkSpeed ?? .max) < 1_000_000_000 }

    /// Przybliżony realny transfer (ok. 80% łącza) w bajtach na sekundę.
    public var approxBytesPerSecond: Int64? { linkSpeed.map { $0 / 10 } }

    public static func formatBits(_ b: Int64) -> String {
        b >= 1_000_000_000 ? "\(String(format: b % 1_000_000_000 == 0 ? "%.0f" : "%.1f", Double(b) / 1e9)) Gb/s" : "\(b / 1_000_000) Mb/s"
    }

    /// Informacje o dysku, na którym leży wolumin `url`.
    public static func read(volume url: URL) -> DriveInfo? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let from = withUnsafePointer(to: &s.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        guard from.hasPrefix("/dev/") else { return nil }
        let bsd = String(from.dropFirst(5))
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return nil }
        var info = DriveInfo()
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(service) }
        for _ in 0..<40 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                info.interconnect = "USB"
                if info.linkSpeed == nil, let sp = prop(entry, "UsbLinkSpeed") as? NSNumber { info.linkSpeed = sp.int64Value }
                if info.model == nil { info.model = prop(entry, "USB Product Name") as? String ?? prop(entry, "kUSBProductString") as? String }
                if info.vendor == nil { info.vendor = prop(entry, "USB Vendor Name") as? String }
            }
            if IOObjectConformsTo(entry, "IOThunderboltPort") != 0 || IOObjectConformsTo(entry, "IOThunderboltSwitch") != 0, info.interconnect == nil || info.interconnect == "PCI-Express" {
                info.interconnect = "Thunderbolt"
            }
            if let pc = prop(entry, "Protocol Characteristics") as? [String: Any] {
                if info.interconnect == nil { info.interconnect = pc["Physical Interconnect"] as? String }
                if (pc["Physical Interconnect Location"] as? String) == "Internal" { info.isInternal = true }
            }
            if let dc = prop(entry, "Device Characteristics") as? [String: Any] {
                if info.model == nil { info.model = (dc["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) }
                if info.vendor == nil { info.vendor = (dc["Vendor Name"] as? String)?.trimmingCharacters(in: .whitespaces) }
            }
            var parent: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard r == KERN_SUCCESS, parent != 0 else { entry = 0; break }
            entry = parent
        }
        if entry != 0 { IOObjectRelease(entry) }
        if info.interconnect == "USB" { info.isInternal = false }
        return info
    }

    private static func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
