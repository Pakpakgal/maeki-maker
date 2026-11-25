import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PrayerReviewApp: App {
    @StateObject private var updates = ReleaseUpdates()

    var body: some Scene {
        WindowGroup("매일의 기도 편집 검토") {
            ReviewView()
                .task { await updates.check() }
                .alert(item: $updates.alert) { notice in
                    if let release = notice.release {
                        return Alert(title: Text(notice.title), message: Text(notice.message),
                                     primaryButton: .default(Text("다운로드")) { NSWorkspace.shared.open(release.download) },
                                     secondaryButton: .cancel(Text("나중에")))
                    }
                    return Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("확인")))
                }
                .frame(minWidth: 1100, idealWidth: 1320, maxWidth: 1600,
                       minHeight: 760, idealHeight: 870, maxHeight: 1000)
        }
        .defaultSize(width: 1320, height: 880)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
                Button("설치 및 권한 안내…") { SetupGuide.open() }
            }
        }
    }
}

private let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
private let accent = Color(red: 0.06, green: 0.52, blue: 0.48)

struct SourcePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct ReviewView: View {
    @StateObject private var model = ReviewModel()
    @State private var page = 0
    @State private var showCropGuides = false
    @State private var showLargePreview = false
    @State private var showAssets = false
    @State private var pendingAssets = SharedAssets()
    @State private var preset: PreviewPreset?
    @State private var previewCards: [PreviewCard] = []
    @State private var previewIssue: String?
    @State private var selection: UUID?
    @State private var section = 0

    var draft: ReviewDraft { model.draft }
    var selectedCard: PreviewCard? { previewCards.isEmpty ? nil : previewCards[min(page, previewCards.count - 1)] }
    var crop: CropOptions {
        CropOptions(path: draft.background, zoom: draft.zoom, x: draft.cropX, y: draft.cropY)
    }
    var previewRequest: PreviewRequest? {
        guard let preset, !preset.layout.isEmpty, !preset.logo.isEmpty, !crop.path.isEmpty else { return nil }
        return PreviewRequest(crop: crop, date: draft.date, texts: draft.visiblePhrases.map(\.text),
                              assets: preset.layout + "\n" + preset.logo)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                HSplitView {
                    backgroundPanel.frame(minWidth: 275, idealWidth: 320, maxWidth: 365)
                    transcriptPanel.frame(minWidth: 465, idealWidth: 560)
                    sourcePanel.frame(minWidth: 290, idealWidth: 335, maxWidth: 390)
                }
                Divider()
                footer
            }
            .accessibilityHidden(model.analysisBusy)
            .disabled(model.analysisBusy)
            if model.analysisBusy {
                analysisOverlay
            }
        }
        .tint(accent)
        .background(.background)
        .task {
            SetupGuide.openOnceIfMissing()
            await model.initialize()
        }
        .task(id: model.sharedAssets) {
            do {
                preset = try await Task.detached {
                    try JSONDecoder().decode(PreviewPreset.self, from: Runner.call(["preview-style"]))
                }.value
            } catch { previewIssue = error.localizedDescription }
        }
        .task(id: previewRequest) {
            guard let request = previewRequest, let preset else { previewCards = []; return }
            do {
                try await Task.sleep(for: .milliseconds(125))
                let cards = try await Task.detached { try PrayerPreview.render(request, preset: preset) }.value
                if !Task.isCancelled {
                    let wasEnding = selectedCard?.title == "엔딩"
                    previewCards = cards
                    page = wasEnding ? cards.count - 1 : min(page, max(0, cards.count - 2))
                    previewIssue = nil
                }
            } catch {
                if !Task.isCancelled { previewCards = []; previewIssue = error.localizedDescription }
            }
        }
        .onChange(of: draft.recording) { selection = nil; page = 0 }
        .onChange(of: draft.phrases) { if !model.busy { model.clearAnalysis() } }
        .onChange(of: [draft.start, draft.end, draft.amenEnd]) { if !model.busy { model.clearAnalysis() } }
        .alert("작업을 확인해 주세요", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("확인", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showLargePreview) {
            VStack(spacing: 12) {
                HStack {
                    Text(selectedCard?.title ?? "미리보기").font(.headline)
                    Spacer()
                    Button("닫기") { showLargePreview = false }.keyboardShortcut(.cancelAction)
                }
                portraitPreview.frame(width: 360, height: 640)
                pagePicker
            }.padding(20).frame(width: 415)
        }
        .sheet(isPresented: $showAssets) {
            VStack(alignment: .leading, spacing: 14) {
                Text("공통 에셋").font(.title2.bold())
                assetPicker("레이아웃 이미지", value: $pendingAssets.layout, types: [.image])
                assetPicker("교회 로고", value: $pendingAssets.logo, types: [.image])
                assetPicker("기본 배경음악", value: $pendingAssets.music, types: [.audio])
                HStack {
                    Spacer()
                    Button("취소") { showAssets = false }.keyboardShortcut(.cancelAction)
                    Button("저장") {
                        showAssets = false
                        Task { await model.saveSharedAssets(pendingAssets) }
                    }.buttonStyle(.borderedProminent).disabled(!pendingAssets.configured)
                }.padding(.top, 4)
            }.padding(23).frame(width: 520)
        }
    }

    var analysisOverlay: some View {
        ZStack {
            Color.black.opacity(0.60)
                .ignoresSafeArea()
                .onTapGesture {}
            VStack(spacing: 12) {
                Text("분석 진행 중").font(.title2.bold())
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: model.analysisProgress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("처리 단계 진행률")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(model.analysisLogs) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(event.time).monospacedDigit().foregroundStyle(.secondary)
                                    Text(event.text).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.id(event.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.analysisLogs.count) {
                        if let last = model.analysisLogs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .font(.caption)
                    .frame(height: 63)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("분석 로그")
                }
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 30)
            .frame(width: 490)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.16)) }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .accessibilityElement(children: .combine)
            .accessibilitySortPriority(2)
        }
    }

    var header: some View {
        HStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .padding(10)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("매일의 기도").font(.title2.bold())
                Text("Palmier Pro에 보내기 전 편집안 검토").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("공통 에셋", systemImage: "square.stack") {
                pendingAssets = model.sharedAssets
                showAssets = true
            }
            Button("새 영상…", systemImage: "plus.rectangle") {
                if let url = model.openFile([.movie, .audio]) {
                    section = 0
                    Task {
                        await model.newRecording(url)
                        if !(model.analysis?.candidates.isEmpty ?? true) { section = 2 }
                    }
                }
            }.keyboardShortcut("n")
            Button("검토안 열기…", systemImage: "folder") {
                if let url = model.openFile([.json]) { Task { await model.load(url) } }
            }.keyboardShortcut("o")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .disabled(model.busy)
    }

    var backgroundPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("배경과 화면", systemImage: "photo").font(.headline)
                    Spacer()
                    Button("사진 변경…") {
                        if let url = model.openFile([.image]) {
                            model.draft.background = url.path
                            resetCrop()
                        }
                    }
                }
                portraitPreview
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxHeight: 396)
                pagePicker
                Button("확대 미리보기", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showLargePreview = true
                }
                .disabled(selectedCard == nil)
                Text(fileTitle(draft.background)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(draft.background)
                if let previewIssue { Text(previewIssue).foregroundStyle(.red).font(.caption) }
                if !model.sharedAssets.configured {
                    Text("공통 에셋에서 레이아웃, 로고, 기본 BGM을 지정하세요.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("9:16 크롭").font(.headline)
                    Spacer()
                    Button("가운데로 초기화", action: resetCrop)
                }
                cropSlider("크기", value: $model.draft.zoom, range: 1...4,
                           display: "\(draft.zoom.formatted(.number.precision(.fractionLength(2))))×")
                cropSlider("좌우", value: $model.draft.cropX, range: 0...1)
                cropSlider("상하", value: $model.draft.cropY, range: 0...1)
                Toggle("크롭 가이드", isOn: $showCropGuides).font(.callout)
            }.padding(17)
        }
        .disabled(model.busy)
    }

    var pagePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(previewCards) { card in
                    Button {
                        page = card.id
                    } label: {
                        VStack(spacing: 4) {
                            Image(decorative: card.image, scale: 1, orientation: .up)
                                .resizable()
                                .frame(width: 44, height: 78)
                                .clipShape(.rect(cornerRadius: 5))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5).strokeBorder(
                                        card.id == selectedCard?.id ? accent : .white.opacity(0.18),
                                        lineWidth: card.id == selectedCard?.id ? 2 : 1
                                    )
                                }
                            Text(card.title).font(.caption2)
                                .foregroundStyle(card.id == selectedCard?.id ? accent : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(card.title)
                    .accessibilityAddTraits(card.id == selectedCard?.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("자막 전체 페이지와 엔딩")
    }

    var portraitPreview: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, geo.size.height * 9 / 16)
            let height = width * 16 / 9
            ZStack {
                Color.black
                if let selectedCard {
                    Image(decorative: selectedCard.image, scale: 1, orientation: .up)
                        .resizable()
                } else {
                    Text(previewIssue == nil ? "미리보기" : "미리보기 확인 필요")
                        .foregroundStyle(.white.opacity(0.7))
                }
                if showCropGuides {
                    Path { path in
                        for i in 1...2 {
                            let x = width * CGFloat(i) / 3, y = height * CGFloat(i) / 3
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y))
                        }
                    }.stroke(.white.opacity(0.35), lineWidth: 0.5)
                }
            }
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.2)) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(selectedCard?.title ?? "9 대 16 영상 미리보기")
    }

    var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("기도문 편집", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Text("\(draft.visiblePhrases.count)개 구절").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Picker("기도문 편집 방식", selection: $section) {
                Text("자막 문구").tag(0)
                Text("음성 삭제 구간 \(draft.cuts.count)").tag(1)
                Text("AI 삭제 검토").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            switch section {
            case 0: phrasePanel
            case 1: cutsPanel
            default: analysisPanel
            }
        }
        .padding(16)
        .disabled(model.busy)
    }

    var phrasePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("문구 편집은 자막에 적용됩니다. 발화도 빼려면 음성 삭제 구간을 추가하세요.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(draft.sortedPhrases) { phrase in
                    if let index = draft.phrases.firstIndex(where: { $0.id == phrase.id }) {
                        phraseRow($model.draft.phrases[index]).tag(phrase.id)
                    }
                }
            }.listStyle(.inset)
                .overlay {
                    if draft.phrases.isEmpty {
                        ContentUnavailableView("기도문을 추가하세요", systemImage: "captions.bubble",
                                               description: Text("원본을 재생해 발화 위치를 확인하고 아래 버튼을 누르세요."))
                    }
                }
            HStack {
                if draft.phrases.isEmpty {
                    Button("자동 전사 초안", systemImage: "waveform") { Task { await model.transcribe() } }
                        .disabled(draft.end <= draft.start)
                }
                Button("현재 위치에 자막 추가", systemImage: "plus") { addPhrase() }
                Button("자막 행 삭제", systemImage: "minus") {
                    model.draft.phrases.removeAll { $0.id == selection }
                    selection = nil
                }.disabled(selection == nil)
                Spacer()
            }
        }
    }

    func phraseRow(_ phrase: Binding<Phrase>) -> some View {
        let row = phrase.wrappedValue
        let removed = draft.isCut(row.sourceAt)
        return HStack(spacing: 10) {
            Toggle("자막 표시", isOn: phrase.visible).labelsHidden()
                .disabled(removed)
                .help("화면에서만 표시하거나 숨깁니다.")
            TextField("원본 초", value: phrase.sourceAt, format: number).monospacedDigit().frame(width: 71)
                .accessibilityLabel("자막 원본 시각(초)")
            TextField("기도 문구", text: phrase.text)
                .strikethrough(removed || !row.visible)
                .foregroundStyle(removed ? .secondary : .primary)
            Button {
                let end = draft.sortedPhrases.first(where: { $0.sourceAt > row.sourceAt })?.sourceAt
                model.audition(from: row.sourceAt, to: end)
            } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("이 구절 원본 재생")
            Menu {
                Button("원본 재생 위치로 시각 변경") { phrase.sourceAt.wrappedValue = model.playhead }
                Button("이 구절의 음성 삭제 구간 추가") { cutPhrase(row) }
                    .disabled(!mayCut(row))
            } label: { Image(systemName: "ellipsis.circle") }.menuIndicator(.hidden).fixedSize()
        }.padding(.vertical, 4)
    }

    var cutsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("원본 시작·끝 시각을 초로 입력하세요. 구간 안의 음성과 자막이 함께 빠집니다.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($model.draft.cuts) { $cut in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("시작 초", value: $cut.start, format: number).monospacedDigit()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("끝 초", value: $cut.end, format: number).monospacedDigit()
                            Button { model.audition(from: cut.start, to: cut.end) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless).help("삭제할 원본 구간 재생")
                            Button {
                                Task { await model.auditionSplice(start: cut.start, end: cut.end) }
                            } label: { Image(systemName: "waveform") }
                                .buttonStyle(.borderless).help("삭제 후 앞뒤 연결 듣기")
                            Button {
                                model.draft.cuts.removeAll { $0.id == cut.id }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("삭제 취소")
                        }
                        TextField("삭제 이유", text: $cut.reason)
                    }.padding(.vertical, 4)
                }
            }.listStyle(.inset)
                .overlay {
                    if draft.cuts.isEmpty {
                        ContentUnavailableView("삭제할 음성 구간 없음", systemImage: "scissors",
                                               description: Text("말실수나 맥락이 빠진 문장이 있으면 구간을 추가하세요."))
                    }
                }
            Button("현재 위치에서 구간 추가", systemImage: "scissors") {
                let start = model.playhead
                model.draft.cuts.append(VoiceCut(start: start, end: start + 1))
            }
        }
    }

    var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("AI로 맥락 분석", systemImage: "sparkles") { Task { await model.analyzeCuts() } }
                    .disabled(draft.phrases.count < 3 || draft.end <= draft.start)
                Spacer()
                Button("듣기 정지", systemImage: "stop") { model.stopSplice(); model.voicePlayer.pause() }
            }
            Text("채택하면 음성과 자막을 함께 뺍니다. 선택한 버튼을 다시 누르면 취소됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let report = model.analysis {
                if !report.summary.isEmpty {
                    Text(report.summary).font(.callout).textSelection(.enabled)
                }
                if report.unverifiedCount > 0 {
                    Text("컷 경계 또는 보호 구간을 확인하지 못한 제안 \(report.unverifiedCount)개는 제외했습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if report.candidates.isEmpty {
                    ContentUnavailableView("검토할 후보가 없습니다", systemImage: "checkmark.bubble")
                        .frame(maxHeight: .infinity)
                } else {
                    List(report.candidates) { candidate in candidateRow(candidate) }.listStyle(.inset)
                }
            } else {
                ContentUnavailableView("설교와 기도문 맥락 분석", systemImage: "text.magnifyingglass",
                                       description: Text("설교를 들어야 이해되는 구절, 말실수나 의미 중복을 찾습니다."))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    func candidateRow(_ candidate: CutCandidate) -> some View {
        let decision = model.decision(for: candidate)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(candidate.category).font(.subheadline.bold()).foregroundStyle(accent)
                Spacer()
                if decision != .pending {
                    Text(decision == .accepted ? "채택됨" : "제외됨")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(decision == .accepted ? accent : .orange)
                }
                Text("−\((candidate.end - candidate.start).formatted(.number.precision(.fractionLength(2))))초")
                    .font(.caption.monospacedDigit())
            }
            Text("\(stamp(candidate.start)) – \(stamp(candidate.end)) · 원본")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(candidate.removed).font(.callout).textSelection(.enabled)
            Text(candidate.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("연결  “\(candidate.before)” → “\(candidate.after)”")
                .font(.caption).textSelection(.enabled)
            if candidate.tightBoundary {
                Label("경계에 쉼이 짧습니다. 말끝과 첫소리를 들어 보세요.", systemImage: "ear")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("원본 듣기", systemImage: "play") {
                    model.audition(from: max(draft.start, candidate.start - 1.5),
                                   to: min(draft.end, candidate.end + 1.5))
                }
                Button("컷 후 듣기", systemImage: "waveform") {
                    Task { await model.auditionSplice(start: candidate.start, end: candidate.end) }
                }
                Spacer()
                Button {
                    model.toggleExclusion(candidate)
                } label: {
                    Label("제외", systemImage: decision == .excluded ? "xmark.circle.fill" : "xmark.circle")
                }
                .tint(decision == .excluded ? .orange : .secondary)
                .accessibilityAddTraits(decision == .excluded ? .isSelected : [])
                Button {
                    model.toggleAcceptance(candidate)
                } label: {
                    Label("채택", systemImage: decision == .accepted ? "checkmark.circle.fill" : "checkmark.circle")
                }
                    .tint(decision == .accepted ? accent : .secondary)
                    .accessibilityAddTraits(decision == .accepted ? .isSelected : [])
                    .disabled(!model.canAccept(candidate))
            }.buttonStyle(.bordered)
        }.padding(.vertical, 7)
    }

    var sourcePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Label("원본과 날짜", systemImage: "calendar").font(.headline)
                TextField("프로젝트 이름", text: $model.draft.name)
                TextField("표시 날짜 (예: 2026년 12월 6일)", text: $model.draft.date)
                Text(fileTitle(draft.recording)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(draft.recording)
                if !model.preparationNotes.isEmpty {
                    ForEach(model.preparationNotes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if !draft.recording.isEmpty && draft.phrases.isEmpty {
                    Button("기도 구간 자동 판별", systemImage: "sparkles") {
                        Task { await model.prepareRecording() }
                    }
                }
                SourcePlayer(player: model.voicePlayer)
                    .aspectRatio(2, contentMode: .fit)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("기도 시작 듣기", systemImage: "ear") {
                        model.audition(from: max(0, (draft.introEnd ?? draft.start) - 0.7),
                                       to: draft.start + 3)
                    }
                    Spacer()
                }
                timeField("첫 단어", value: $model.draft.start)
                timeField("아멘 끝", value: $model.draft.amenEnd)
                timeField("기도 구간 끝", value: $model.draft.end)
                Toggle("앞에 안내 멘트 있음", isOn: Binding(
                    get: { draft.introEnd != nil }, set: { model.draft.introEnd = $0 ? model.playhead : nil }
                ))
                if draft.introEnd != nil {
                    timeField("안내 멘트 끝", value: Binding(
                        get: { draft.introEnd ?? 0 }, set: { model.draft.introEnd = $0 }
                    ))
                }
                Divider()
                Label("배경음악", systemImage: "music.note").font(.headline)
                Text(fileTitle(draft.music)).font(.callout).lineLimit(1).help(draft.music)
                HStack {
                    Button("파일 변경…") {
                        if let url = model.openFile([.audio]) { Task { await model.selectMusic(url) } }
                    }
                    Button("기본곡") { Task { await model.restoreMusic() } }
                    Button { model.previewMusic() } label: { Image(systemName: "playpause") }.help("BGM 원본 미리 듣기")
                }
                HStack {
                    Text("음악 끝 위치").font(.caption)
                    TextField("음악 끝", value: $model.draft.musicEnd, format: number).monospacedDigit()
                    Text("초").foregroundStyle(.secondary).font(.caption)
                }
                Text("고정 믹스 · 기도 중 −23 dB · 아멘 뒤 1초에 걸쳐 0 dB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(17)
            .textFieldStyle(.roundedBorder)
        }.disabled(model.busy)
    }

    var footer: some View {
        HStack(spacing: 12) {
            let over = draft.estimate > 89
            Label("\(stamp(draft.estimate)) / 1:29", systemImage: "timer")
                .font(.headline.monospacedDigit())
                .foregroundStyle(over ? .red : .primary)
            if over {
                Text("\((draft.estimate - 89).formatted(.number.precision(.fractionLength(2))))초 초과")
                    .foregroundStyle(.red).font(.callout)
            } else if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button("초안 저장…") { save(draftOnly: true) }
                .disabled(model.busy || draft.recording.isEmpty)
            Button("검토본 저장…") { save() }
                .keyboardShortcut("s")
                .disabled(model.busy || over || draft.recording.isEmpty)
            Button("Palmier로 보내기", systemImage: "arrow.up.right") { Task { await model.sendToPalmier() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || over || draft.visiblePhrases.isEmpty || draft.date.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    func cropSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, display: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 34, alignment: .leading)
            Slider(value: value, in: range).labelsHidden().accessibilityLabel(label)
            Text(display ?? "\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().frame(width: 48, alignment: .trailing)
        }.font(.caption)
    }

    func timeField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 78, alignment: .leading)
            TextField(label, value: value, format: number).monospacedDigit()
            Button("지정") { value.wrappedValue = model.playhead }.help("원본 플레이어의 현재 시각을 입력")
        }
    }

    func resetCrop() {
        model.draft.zoom = 1
        model.draft.cropX = 0.5
        model.draft.cropY = 0.5
    }

    func assetPicker(_ title: String, value: Binding<String>, types: [UTType]) -> some View {
        HStack {
            Text(title).frame(width: 105, alignment: .leading)
            Text(fileTitle(value.wrappedValue)).lineLimit(1).foregroundStyle(.secondary)
            Spacer()
            Button("선택…") {
                if let file = model.openFile(types) { value.wrappedValue = file.path }
            }
        }
    }

    func addPhrase() {
        let phrase = Phrase(text: "", sourceAt: max(model.playhead, draft.start))
        model.draft.phrases.append(phrase)
        selection = phrase.id
    }

    func mayCut(_ row: Phrase) -> Bool {
        row.sourceAt > draft.start && draft.sortedPhrases.contains { $0.sourceAt > row.sourceAt && $0.sourceAt < draft.amenEnd }
    }

    func cutPhrase(_ row: Phrase) {
        guard let next = draft.sortedPhrases.first(where: { $0.sourceAt > row.sourceAt }) else { return }
        model.draft.cuts.append(VoiceCut(start: row.sourceAt, end: next.sourceAt, reason: "구절 삭제 · \(row.text)"))
        section = 1
    }

    func save(draftOnly: Bool = false) {
        let safeName = draft.name.replacingOccurrences(of: "/", with: "-")
        let suffix = draftOnly ? " · 초안.json" : " · 검토.json"
        guard let target = model.destination(safeName + suffix) else { return }
        Task { await model.store(target, send: false, draftOnly: draftOnly) }
    }

    func fileTitle(_ path: String) -> String {
        path.isEmpty ? "선택한 파일 없음" : URL(fileURLWithPath: path).lastPathComponent
    }

    func stamp(_ seconds: Double) -> String {
        let centiseconds = Int((seconds * 100).rounded())
        return String(format: "%d:%02d.%02d", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
    }
}
