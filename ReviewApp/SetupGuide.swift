import AppKit
import Foundation

@MainActor
enum SetupGuide {
    static let palmierID = "io.palmier.pro"

    static var palmierInstalled: Bool {
        guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: palmierID) else { return false }
        return FileManager.default.fileExists(atPath: location.path)
    }

    @discardableResult
    static func open() -> Bool {
        guard let guide = Bundle.main.url(forResource: "설치 및 권한 안내", withExtension: "txt") else { return false }
        return NSWorkspace.shared.open(guide)
    }

    static func openOnceIfMissing() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let key = "setupGuide.lastShownVersion"
        guard !palmierInstalled, UserDefaults.standard.string(forKey: key) != version else { return }
        if open() { UserDefaults.standard.set(version, forKey: key) }
    }
}
