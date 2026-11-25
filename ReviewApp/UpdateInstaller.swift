import CryptoKit
import Darwin
import Foundation

enum UpdateInstaller {
    private static let bundleName = "매일의 기도 편집 검토.app"
    private static let bundleID = "local.daily-prayer.review"

    static func install(_ release: AvailableRelease, at destination: URL) async throws {
        let request = URLRequest(url: release.download, timeoutInterval: 60)
        let (image, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: image) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ReviewError("GitHub에서 설치 이미지를 내려받지 못했습니다.")
        }
        try replaceApp(from: image, release: release, at: destination)
    }

    static func replaceApp(from image: URL, release: AvailableRelease, at destination: URL) throws {
        let manager = FileManager.default
        guard try digest(of: image) == release.sha256 else {
            throw ReviewError("내려받은 설치 이미지의 SHA-256이 GitHub 릴리스와 일치하지 않습니다.")
        }
        guard Bundle(url: destination)?.bundleIdentifier == bundleID else {
            throw ReviewError("업데이트할 매일의 기도 앱을 찾지 못했습니다.")
        }

        let mount = manager.temporaryDirectory.appendingPathComponent("maeki-mount-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        defer { _ = rmdir(mount.path) }
        // Keep the mount and staging area separate so an unsuccessful detach
        // can never make cleanup traverse the mounted volume.
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                                    "-mountpoint", mount.path, image.path])
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])) == nil {
                try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            }
        }

        let source = mount.appendingPathComponent(bundleName, isDirectory: true)
        guard let bundle = Bundle(url: source), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw ReviewError("설치 이미지 안의 앱 버전이나 식별자가 릴리스 정보와 일치하지 않습니다.")
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".maeki-update-\(UUID())", isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw ReviewError("현재 앱 폴더에 설치할 권한이 없습니다. DMG를 내려받아 응용 프로그램 폴더에 설치해 주세요.")
        }
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent(bundleName, isDirectory: true)
        try run("/usr/bin/ditto", [source.path, candidate.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", candidate.path])

        // Exchange both names atomically so the installed app remains in place
        // if the operation fails. The paths are on the same volume.
        if renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw ReviewError("앱을 교체할 수 없습니다. \(error.localizedDescription)")
        }
    }

    private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReviewError(details.isEmpty ? "설치 도구 \(URL(fileURLWithPath: path).lastPathComponent)가 실패했습니다." : details)
        }
    }
}
