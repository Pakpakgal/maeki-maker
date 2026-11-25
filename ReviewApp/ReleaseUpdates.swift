import AppKit
import Foundation
import SwiftUI

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let digest: String?
    }
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

struct AvailableRelease {
    let version: String
    let download: URL
    let sha256: String
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var release: AvailableRelease?
    var download: URL?
    var offersImport = false
}

@MainActor
final class ReleaseUpdates: ObservableObject {
    nonisolated static let repository = "Pakpakgal/maeki-maker"
    static let feed = URL(string: "https://api.github.com/repos/" + repository + "/releases/latest")!
    @Published var checking = false
    @Published var installing = false
    @Published var alert: UpdateNotice?
    private var checkedOnLaunch = false
    var canCheckManually: Bool { checkedOnLaunch && !checking && !installing }

    var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func check(manual: Bool = false) async {
        guard manual ? canCheckManually : !checking && !installing && !checkedOnLaunch else { return }
        if !manual { checkedOnLaunch = true }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: manual ? 12 : 5)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                alert = manual ? UpdateNotice(title: "공개 릴리스 없음", message: "게시된 업데이트가 없습니다.")
                    : Self.importNotice()
                return
            }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let latest = try decoder.decode(GitHubRelease.self, from: data)
            let release = try Self.available(latest, current: current)
            if !manual {
                alert = Self.importNotice(release)
                return
            }
            if let release {
                alert = UpdateNotice(title: "업데이트가 있습니다", message: "현재 \(current) · 최신 \(release.version)", release: release)
            } else {
                alert = UpdateNotice(title: "최신 버전입니다", message: "현재 버전은 \(current)입니다.")
            }
        } catch {
            if Task.isCancelled {
                if !manual { checkedOnLaunch = false }
                return
            }
            alert = manual ? UpdateNotice(title: "업데이트 확인 실패", message: error.localizedDescription)
                : Self.importNotice()
        }
    }

    private static func importNotice(_ release: AvailableRelease? = nil) -> UpdateNotice {
        var message = "한 번에 최대 \(ReviewModel.importLimit)개를 가져올 수 있습니다."
        if let release { message += "\n새 버전 v\(release.version)을 설치할 수 있습니다." }
        return UpdateNotice(title: "새 영상을 가져올까요?", message: message,
                            release: release, offersImport: true)
    }

    func install(_ release: AvailableRelease) async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        do {
            try await Task.detached { try await UpdateInstaller.install(release, at: destination) }.value
        } catch {
            alert = UpdateNotice(title: "업데이트 설치 실패",
                                  message: error.localizedDescription,
                                  download: release.download)
            return
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            NSApp.terminate(nil)
        } catch {
            alert = UpdateNotice(title: "업데이트 설치 완료",
                                  message: "버전 \(release.version)이 설치되었습니다. 앱을 종료한 뒤 다시 열어 주세요.")
        }
    }

    nonisolated static func available(_ release: GitHubRelease, current: String) throws -> AvailableRelease? {
        guard !release.draft, !release.prerelease,
              let old = numbers(current), let new = numbers(release.tagName),
              old.lexicographicallyPrecedes(new) else { return nil }
        let version = new.map(String.init).joined(separator: ".")
        let name = "MaekiMaker-v\(version).dmg"
        let expectedPath = "/\(repository)/releases/download/\(release.tagName)/\(name)"
        guard let asset = release.assets.first(where: { $0.name == name }),
              asset.browserDownloadUrl.scheme == "https", asset.browserDownloadUrl.host == "github.com",
              asset.browserDownloadUrl.path == expectedPath,
              let digest = asset.digest, digest.range(of: "^sha256:[0-9a-f]{64}$",
                                                        options: .regularExpression) != nil else {
            throw ReviewError("GitHub 릴리스에 올바른 설치 이미지가 없습니다.")
        }
        return AvailableRelease(version: version, download: asset.browserDownloadUrl,
                                sha256: String(digest.dropFirst("sha256:".count)))
    }

    nonisolated private static func numbers(_ value: String) -> [Int]? {
        let tag = value.hasPrefix("v") ? value.dropFirst() : Substring(value)
        let components = tag.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let digits = components.compactMap { Int($0) }
        guard digits.count == components.count else { return nil }
        return digits + Array(repeating: 0, count: 3 - digits.count)
    }
}
