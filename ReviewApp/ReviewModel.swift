import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Phrase: Codable, Identifiable, Equatable {
    struct AcousticBoundary: Codable, Equatable {
        let onset: Double
        let previousEnd: Double
    }

    var id = UUID()
    var text: String
    var sourceAt: Double
    var visible = true
    var acoustic: AcousticBoundary?

    enum CodingKeys: String, CodingKey { case text, sourceAt, visible, acoustic }
}

struct VoiceCut: Codable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var reason = ""

    enum CodingKeys: String, CodingKey { case start, end, reason }
}

struct CutCandidate: Decodable, Identifiable {
    var id = UUID()
    let start: Double
    let end: Double
    let category: String
    let reason: String
    let removed: String
    let before: String
    let after: String
    let tightBoundary: Bool

    enum CodingKeys: String, CodingKey { case start, end, category, reason, removed, before, after, tightBoundary }
}

struct CutAnalysis: Decodable {
    var summary: String
    var candidates: [CutCandidate]
    let unverifiedCount: Int
}

enum CandidateDecision {
    case pending, accepted, excluded
}

struct PreparedPrayer: Decodable {
    let start: Double
    let end: Double
    let amenEnd: Double
    let introEnd: Double?
    let phrases: [Phrase]
    let date: String?
    let background: String?
    let warnings: [String]
}

struct ReviewDraft: Codable {
    var name = ""
    var date = ""
    var recording = ""
    var background = ""
    var music = ""
    var musicEnd = 0.0
    var start = 0.0
    var end = 0.0
    var amenEnd = 0.0
    var introEnd: Double?
    var phrases: [Phrase] = []
    var cuts: [VoiceCut] = []
    var zoom = 1.0
    var cropX = 0.5
    var cropY = 0.5

    var sortedPhrases: [Phrase] { phrases.sorted { $0.sourceAt < $1.sourceAt } }

    func isCut(_ seconds: Double) -> Bool {
        cuts.contains { $0.start <= seconds && seconds < $0.end }
    }

    var visiblePhrases: [Phrase] {
        sortedPhrases.filter { $0.visible && !isCut($0.sourceAt) && $0.sourceAt >= start && $0.sourceAt < end }
    }

    var estimate: Double {
        guard end > start else { return 0 }
        var cursor = start
        var frames = 215 // Opening, last prayer hold and ending.
        for cut in cuts.sorted(by: { $0.start < $1.start }) where cut.start >= cursor && cut.end <= end && cut.end > cut.start {
            frames += Int(((cut.start - cursor) * 30).rounded(.toNearestOrEven))
            cursor = cut.end
        }
        frames += Int(((end - cursor) * 30).rounded(.toNearestOrEven))
        return Double(frames) / 30
    }
}

struct CropOptions: Hashable {
    let path: String
    let zoom: Double
    let x: Double
    let y: Double

    func jpeg(width: Int) throws -> Data {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path),
                                  options: [.applyOrientationProperty: true]),
              !image.extent.isEmpty else { throw ReviewError("사진을 열 수 없습니다.") }
        let extent = image.extent
        let ratio = 9.0 / 16.0
        let cropWidth = min(extent.width, extent.height * ratio) / zoom
        let cropHeight = cropWidth / ratio
        let crop = CGRect(x: extent.minX + (extent.width - cropWidth) * x,
                          y: extent.minY + (extent.height - cropHeight) * (1 - y),
                          width: cropWidth, height: cropHeight)
        let scale = CGFloat(width) / crop.width
        let target = CGRect(x: 0, y: 0, width: width, height: width * 16 / 9)
        let fitted = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent().cropped(to: target)
        guard let data = CIContext().jpegRepresentation(of: fitted,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                   options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.96]) else {
            throw ReviewError("크롭한 사진을 저장할 수 없습니다.")
        }
        return data
    }
}

struct ReviewError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SharedAssets: Codable, Equatable {
    var layout = ""
    var logo = ""
    var music = ""

    var configured: Bool { [layout, logo, music].allSatisfy { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } }
}

enum Runner {
    static let folder: URL = {
        if let path = ProcessInfo.processInfo.environment["MAEKI_WORKSPACE"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent("Documents/PalmierDailyPrayer", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("1206.json").path) {
            return legacy
        }
        return home.appendingPathComponent("Library/Application Support/MaekiMaker", isDirectory: true)
    }()
    static let resources = Bundle.main.resourceURL ?? folder
    static let outputFolder = folder.appendingPathComponent("검토 작업", isDirectory: true)
    static let bridge = resources.appendingPathComponent("ReviewApp/review_bridge.py")
    static let launcher = resources.appendingPathComponent("매일의 기도 자동편집.command")
    static let assetSettings = folder.appendingPathComponent("assets.json")

    static func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["MAEKI_WORKSPACE"] = folder.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReviewError(message.isEmpty ? "실행에 실패했습니다. (\(process.terminationStatus))" : message)
        }
        return data
    }

    static func call(_ args: [String]) throws -> Data {
        try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", bridge.path] + args)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func save(_ draft: ReviewDraft, to target: URL) throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temp) }
        let input = temp.appendingPathComponent("draft.json")
        try encoder().encode(draft).write(to: input, options: .atomic)
        let crop = CropOptions(path: draft.background, zoom: draft.zoom, x: draft.cropX, y: draft.cropY)
        let croppedBytes = try crop.jpeg(width: 1080)
        let assets = outputFolder.appendingPathComponent("배경", isDirectory: true)
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        let photo = assets.appendingPathComponent(UUID().uuidString + ".jpg")
        try croppedBytes.write(to: photo, options: .atomic)
        do {
            let compiled = try call(["compile", input.path, photo.path])
            let json = try JSONSerialization.jsonObject(with: compiled)
            let formatted = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try formatted.write(to: target, options: .atomic)
        } catch {
            try? manager.removeItem(at: photo)
            throw error
        }
    }
}

@MainActor
final class ReviewModel: ObservableObject {
    @Published var draft = ReviewDraft()
    @Published var busy = false
    @Published var analysisBusy = false
    @Published var status = ""
    @Published var error: String?
    @Published var savedURL: URL?
    @Published var documentURL: URL?
    @Published var analysis: CutAnalysis?
    @Published private var excludedCandidates: Set<UUID> = []
    @Published var preparationNotes: [String] = []
    @Published var sharedAssets = SharedAssets()
    let voicePlayer = AVPlayer()
    let musicPlayer = AVPlayer()
    private let splicePlayer = AVPlayer()
    private var previewID = UUID()
    private var presetMusic = ""
    private var presetMusicEnd = 0.0
    private var loadedRecording = ""
    private var loadedMusic = ""
    private var playbackBoundary: Any?

    func initialize() async {
        let sample = Runner.folder.appendingPathComponent("1206.json")
        if FileManager.default.fileExists(atPath: sample.path), draft.recording.isEmpty {
            await load(sample)
        }
        do {
            sharedAssets = try await Task.detached {
                try JSONDecoder().decode(SharedAssets.self, from: Runner.call(["asset-settings"]))
            }.value
            if !sharedAssets.music.isEmpty, sharedAssets.music != presetMusic {
                presetMusic = sharedAssets.music
                if draft.music.isEmpty {
                    await selectMusic(URL(fileURLWithPath: presetMusic))
                    presetMusicEnd = draft.musicEnd
                } else {
                    let duration = try await AVURLAsset(url: URL(fileURLWithPath: presetMusic)).load(.duration).seconds
                    if duration.isFinite { presetMusicEnd = duration }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func saveSharedAssets(_ assets: SharedAssets) async {
        guard assets.configured else {
            error = "레이아웃, 교회 로고, 기본 BGM 파일 세 개를 선택하세요."
            return
        }
        do {
            try FileManager.default.createDirectory(at: Runner.folder, withIntermediateDirectories: true)
            try Runner.encoder().encode(assets).write(to: Runner.assetSettings, options: .atomic)
            sharedAssets = assets
            presetMusic = assets.music
            await selectMusic(URL(fileURLWithPath: assets.music))
            presetMusicEnd = draft.musicEnd
            status = "공통 에셋을 저장했습니다."
        } catch { self.error = error.localizedDescription }
    }

    func load(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let loaded = try await Task.detached {
                try JSONDecoder().decode(ReviewDraft.self, from: Runner.call(["load", url.path]))
            }.value
            draft = loaded
            clearAnalysis()
            preparationNotes = []
            documentURL = url
            savedURL = nil
            if presetMusic.isEmpty {
                presetMusic = loaded.music
                presetMusicEnd = loaded.musicEnd
            }
            installRecording()
            installMusic()
            status = "\(url.lastPathComponent) 열림"
        } catch { self.error = error.localizedDescription }
    }

    func openFile(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func destination(_ title: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = title
        try? FileManager.default.createDirectory(at: Runner.outputFolder, withIntermediateDirectories: true)
        panel.directoryURL = Runner.outputFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    func newRecording(_ url: URL) async {
        var next = ReviewDraft()
        next.recording = url.path
        next.name = "매일의 기도 · " + url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        next.background = draft.background
        next.music = presetMusic.isEmpty ? draft.music : presetMusic
        next.musicEnd = presetMusic.isEmpty ? draft.musicEnd : presetMusicEnd
        draft = next
        clearAnalysis()
        documentURL = nil
        savedURL = nil
        installRecording()
        installMusic()
        await prepareRecording()
    }

    func prepareRecording() async {
        busy = true
        analysisBusy = true
        preparationNotes = []
        status = "원본을 전사해 기도 시작과 아멘 끝을 찾는 중…"
        defer { busy = false; analysisBusy = false }
        let path = draft.recording
        do {
            let prepared = try await Task.detached {
                try JSONDecoder().decode(PreparedPrayer.self, from: Runner.call(["prepare", path]))
            }.value
            draft.start = prepared.start
            draft.end = prepared.end
            draft.amenEnd = prepared.amenEnd
            draft.introEnd = prepared.introEnd
            draft.phrases = prepared.phrases
            if let date = prepared.date { draft.date = date }
            if let photo = prepared.background { draft.background = photo }
            preparationNotes = prepared.warnings
            seekToPrayerStart()
        } catch {
            status = "기도 구간 확인 필요"
            preparationNotes = [error.localizedDescription]
            return
        }
        status = "기도 구간과 자막 준비 완료 · 삭제 후보 분석 중…"
        do {
            let snapshot = draft
            analysis = try await Task.detached {
                try Self.runDraft(snapshot, command: "analyze", as: CutAnalysis.self)
            }.value
            status = "자동 준비 완료 · 자막 \(draft.phrases.count)개 · 삭제 후보 \(analysis?.candidates.count ?? 0)개"
        } catch {
            status = "기도 구간과 자막 준비 완료"
            preparationNotes.append(error.localizedDescription)
        }
    }

    func installRecording() {
        guard loadedRecording != draft.recording else { return }
        voicePlayer.pause()
        clearPlaybackBoundary()
        loadedRecording = draft.recording
        voicePlayer.replaceCurrentItem(with: loadedRecording.isEmpty ? nil : AVPlayerItem(url: URL(fileURLWithPath: loadedRecording)))
    }

    func installMusic() {
        guard loadedMusic != draft.music else { return }
        musicPlayer.pause()
        loadedMusic = draft.music
        musicPlayer.replaceCurrentItem(with: loadedMusic.isEmpty ? nil : AVPlayerItem(url: URL(fileURLWithPath: loadedMusic)))
    }

    func selectMusic(_ url: URL) async {
        draft.music = url.path
        installMusic()
        do {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard duration.isFinite && duration > 0 else { throw ReviewError("음악의 길이를 읽을 수 없습니다.") }
            if draft.music == url.path { draft.musicEnd = duration }
        } catch { self.error = error.localizedDescription }
    }

    func restoreMusic() async {
        guard !presetMusic.isEmpty else { return }
        await selectMusic(URL(fileURLWithPath: presetMusic))
    }

    func transcribe() async {
        busy = true
        analysisBusy = true
        status = "이 Mac에서 선택 구간을 전사 중…"
        defer { busy = false; analysisBusy = false }
        let snapshot = draft
        do {
            draft.phrases = try await Task.detached {
                try Self.runDraft(snapshot, command: "transcribe", as: [Phrase].self)
            }.value
            status = "전사 초안 \(draft.phrases.count)개 생성 · 원본과 대조해 주세요."
        } catch { self.error = error.localizedDescription }
    }

    nonisolated private static func runDraft<T: Decodable>(_ draft: ReviewDraft, command: String,
                                                            as type: T.Type) throws -> T {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Runner.encoder().encode(draft).write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try JSONDecoder().decode(type, from: Runner.call([command, temp.path]))
    }

    func analyzeCuts() async {
        busy = true
        analysisBusy = true
        clearAnalysis()
        status = "원본을 전사하고 로컬 AI로 맥락을 분석 중…"
        defer { busy = false; analysisBusy = false }
        let snapshot = draft
        do {
            analysis = try await Task.detached {
                try Self.runDraft(snapshot, command: "analyze", as: CutAnalysis.self)
            }.value
            status = "AI 분석 완료 · 검토 후보 \(analysis?.candidates.count ?? 0)개"
        } catch {
            status = "AI 분석 중단"
            self.error = error.localizedDescription
        }
    }

    func clearAnalysis() {
        stopSplice()
        analysis = nil
        excludedCandidates.removeAll()
    }

    func decision(for candidate: CutCandidate) -> CandidateDecision {
        if draft.cuts.contains(where: { $0.id == candidate.id }) { return .accepted }
        return excludedCandidates.contains(candidate.id) ? .excluded : .pending
    }

    func canAccept(_ candidate: CutCandidate) -> Bool {
        if decision(for: candidate) == .accepted { return true }
        return candidate.start > draft.start && candidate.end < draft.amenEnd
            && !draft.cuts.contains { candidate.start < $0.end && $0.start < candidate.end }
    }

    func toggleAcceptance(_ candidate: CutCandidate) {
        stopSplice()
        if decision(for: candidate) == .accepted {
            draft.cuts.removeAll { $0.id == candidate.id }
            status = "채택 취소 · 음성과 자막을 복원했습니다."
            return
        }
        guard canAccept(candidate) else {
            error = "이미 지정한 구간과 겹칩니다. 기존 음성 컷을 확인하세요."
            return
        }
        excludedCandidates.remove(candidate.id)
        draft.cuts.append(VoiceCut(id: candidate.id, start: candidate.start, end: candidate.end,
                                  reason: "\(candidate.category) · \(candidate.reason)"))
        status = "후보 채택 · 음성과 자막을 함께 뺍니다."
    }

    func toggleExclusion(_ candidate: CutCandidate) {
        stopSplice()
        if excludedCandidates.remove(candidate.id) != nil {
            status = "제외 취소 · 검토 대기로 돌아갔습니다."
        } else {
            draft.cuts.removeAll { $0.id == candidate.id }
            excludedCandidates.insert(candidate.id)
            status = "후보 제외 · 원본 음성과 자막을 유지합니다."
        }
    }

    func stopSplice() {
        previewID = UUID()
        splicePlayer.pause()
        splicePlayer.replaceCurrentItem(with: nil)
    }

    func auditionSplice(start: Double, end: Double) async {
        stopSplice()
        voicePlayer.pause()
        musicPlayer.pause()
        let ticket = previewID
        let snapshot = draft
        let previous = snapshot.cuts.filter { $0.end <= start }.map(\.end).max() ?? snapshot.start
        let following = snapshot.cuts.filter { $0.start >= end }.map(\.start).min() ?? snapshot.end
        let left = max(previous, start - 2.5)
        let right = min(following, end + 2.5)
        guard left < start, start < end, end < right else {
            error = "이 컷의 앞뒤에 연결해서 들을 음성이 필요합니다."
            return
        }
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: snapshot.recording))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ReviewError("원본에서 음성 트랙을 읽을 수 없습니다.")
            }
            let composition = AVMutableComposition()
            guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ReviewError("연결 미리듣기를 만들 수 없습니다.")
            }
            func time(_ seconds: Double) -> CMTime {
                CMTime(seconds: seconds, preferredTimescale: 60000)
            }
            let leading = CMTimeRange(start: time(left), end: time(start))
            let trailing = CMTimeRange(start: time(end), end: time(right))
            try target.insertTimeRange(leading, of: source, at: .zero)
            try target.insertTimeRange(trailing, of: source, at: leading.duration)
            guard ticket == previewID else { return }
            splicePlayer.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            splicePlayer.play()
        } catch {
            if ticket == previewID { self.error = error.localizedDescription }
        }
    }

    var playhead: Double {
        let seconds = voicePlayer.currentTime().seconds
        return seconds.isFinite ? (seconds * 1000).rounded() / 1000 : 0
    }

    private func seekToPrayerStart() {
        voicePlayer.seek(to: CMTime(seconds: draft.start, preferredTimescale: 60000),
                         toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func clearPlaybackBoundary() {
        if let playbackBoundary { voicePlayer.removeTimeObserver(playbackBoundary) }
        playbackBoundary = nil
    }

    func audition(from: Double, to: Double? = nil) {
        stopSplice()
        musicPlayer.pause()
        clearPlaybackBoundary()
        if let to, to > from {
            playbackBoundary = voicePlayer.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: to, preferredTimescale: 60000))], queue: .main
            ) { [weak voicePlayer] in voicePlayer?.pause() }
        }
        voicePlayer.seek(to: CMTime(seconds: max(0, from), preferredTimescale: 60000),
                         toleranceBefore: .zero, toleranceAfter: .zero) { [weak voicePlayer] completed in
            if completed { voicePlayer?.play() }
        }
    }

    func previewMusic() {
        stopSplice()
        voicePlayer.pause()
        if musicPlayer.rate > 0 { musicPlayer.pause(); return }
        let start = max(0, draft.musicEnd - draft.estimate)
        musicPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 60000))
        musicPlayer.play()
    }

    func store(_ target: URL, send: Bool, draftOnly: Bool = false) async {
        busy = true
        defer { busy = false }
        let snapshot = draft
        do {
            try await Task.detached {
                if draftOnly {
                    try Runner.encoder().encode(["review": snapshot]).write(to: target, options: .atomic)
                } else {
                    try Runner.save(snapshot, to: target)
                }
            }.value
            savedURL = target
            documentURL = target
            status = "\(target.lastPathComponent) 저장 완료"
            guard send else { return }
            status = "Palmier Pro에서 편집 프로젝트를 생성 중…"
            let output = try await Task.detached { try Runner.run(Runner.launcher, [target.path]) }.value
            status = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { self.error = error.localizedDescription }
    }

    func sendToPalmier() async {
        do {
            try FileManager.default.createDirectory(at: Runner.outputFolder, withIntermediateDirectories: true)
            let name = draft.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = (name.isEmpty ? "매일의 기도" : name) + " · 검토"
            var target = Runner.outputFolder.appendingPathComponent(stem + ".json")
            var index = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = Runner.outputFolder.appendingPathComponent("\(stem) (\(index)).json")
                index += 1
            }
            await store(target, send: true)
        } catch { self.error = error.localizedDescription }
    }
}
