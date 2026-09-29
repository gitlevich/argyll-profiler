import Foundation
import CoreGraphics
import ColorSync

/// An ICC display profile the user could assign to a display.
public struct InstalledProfile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isFactory: Bool
    public let modified: Date?
    public var id: URL { url }

    public init(url: URL, name: String, isFactory: Bool, modified: Date? = nil) {
        self.url = url
        self.name = name
        self.isFactory = isFactory
        self.modified = modified
    }
}

/// Reads and sets display profile assignments through ColorSync, the same mechanism
/// System Settings > Displays > Color profile uses. No Argyll involved, so it is instant.
public enum DisplayProfiles {

    /// CoreGraphics display for an Argyll "-d" list entry, matched by position and size.
    public static func displayID(forArgyllName name: String) -> CGDirectDisplayID? {
        let regex = try! Regex("at (-?\\d+), (-?\\d+), width (\\d+), height (\\d+)")
        guard let m = name.firstMatch(of: regex),
              let x = Double(m[1].substring ?? ""), let y = Double(m[2].substring ?? ""),
              let w = Double(m[3].substring ?? ""), let h = Double(m[4].substring ?? "") else { return nil }
        return onlineDisplays().first { id in
            let b = CGDisplayBounds(id)
            return abs(b.origin.x - x) < 2 && abs(b.origin.y - y) < 2 && abs(b.width - w) < 2 && abs(b.height - h) < 2
        }
    }

    public static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// ColorSync's device record: CustomProfiles, FactoryProfiles, DeviceDescription…
    public static func deviceInfo(for id: CGDirectDisplayID) -> [String: Any]? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let uuid = u.takeRetainedValue()
        guard let raw = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid) else { return nil }
        return raw.takeRetainedValue() as? [String: Any]
    }

    /// The profile macOS generated for the panel; assigning "nothing" falls back to it.
    public static func factoryProfile(for id: CGDirectDisplayID) -> InstalledProfile? {
        guard let info = deviceInfo(for: id),
              let factory = info["FactoryProfiles"] as? [String: Any] else { return nil }
        let key = factory["DeviceDefaultProfileID"].map { "\($0)" } ?? "1"
        guard let entry = factory[key] as? [String: Any],
              let url = fileURL(entry["DeviceProfileURL"]) else { return nil }
        let name = (entry["DeviceModeDescription"] as? String)
            ?? (info["DeviceDescription"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledProfile(url: url, name: name, isFactory: true)
    }

    /// What the display is using right now.
    public static func currentProfileURL(for id: CGDirectDisplayID) -> URL? {
        guard let info = deviceInfo(for: id) else { return nil }
        if let custom = info["CustomProfiles"] as? [String: Any],
           let url = fileURL(custom["1"] ?? custom.values.first) {
            return url
        }
        return factoryProfile(for: id)?.url
    }

    /// Assigns a profile to the display for the current user; nil restores the factory profile.
    @discardableResult
    public static func setProfile(_ url: URL?, for id: CGDirectDisplayID) -> Bool {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id) else { return false }
        let uuid = u.takeRetainedValue()
        let key = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        let value: Any = url.map { $0 as CFURL } ?? (kCFNull as Any)
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, [key: value] as CFDictionary)
    }

    /// The factory profile plus every display-class profile in ~/Library/ColorSync/Profiles,
    /// newest first. Profiles for other displays are included too; ICC files don't say
    /// which panel they were made for.
    public static func availableProfiles(for id: CGDirectDisplayID) -> [InstalledProfile] {
        var list: [InstalledProfile] = []
        if let factory = factoryProfile(for: id) { list.append(factory) }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var own: [InstalledProfile] = []
        for url in files where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: url), data.count > 128,
                  String(decoding: data[12..<16], as: UTF8.self) == "mntr" else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            own.append(InstalledProfile(url: URL(fileURLWithPath: url.path),
                                        name: description(of: data) ?? url.deletingPathExtension().lastPathComponent,
                                        isFactory: false,
                                        modified: modified))
        }
        list += own.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return list
    }

    /// The ICC description tag, which is what System Settings shows in the profile menu.
    public static func description(of data: Data) -> String? {
        var error: Unmanaged<CFError>?
        guard let p = ColorSyncProfileCreate(data as CFData, &error) else { return nil }
        let profile = p.takeRetainedValue()
        return ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
    }

    /// ColorSync hands back CFURLs, sometimes strings, with percent-encoding; normalise to a plain file URL.
    private static func fileURL(_ any: Any?) -> URL? {
        if let u = any as? URL { return URL(fileURLWithPath: u.path) }
        if let s = any as? String, let u = URL(string: s) { return URL(fileURLWithPath: u.path) }
        return nil
    }
}
