import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

private enum DragMode { case none, seek, brightness, volume, pan }
private struct HUDInfo { let icon: String; let text: String; let progress: Double? }

private func playerTime(_ s: Double) -> String {
    let t = Int(s.isFinite ? max(s, 0) : 0)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

struct VideoScrubber: View {
    var value: Double
    var duration: Double
    var buffered: Double
    var markers: [Double]
    var onBegan: () -> Void
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let inset: CGFloat = 14
            let w = max(g.size.width - inset * 2, 1)
            let frac = duration > 0 ? CGFloat(min(max(value / duration, 0), 1)) : 0
            let bf = duration > 0 ? CGFloat(min(max(buffered / duration, 0), 1)) : 0
            let d: CGFloat = dragging ? 28 : 22
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(width: w, height: 4).offset(x: inset)
                Capsule().fill(Color.white.opacity(0.6)).frame(width: w * bf, height: 4).offset(x: inset)
                Capsule().fill(Color.accentBlue).frame(width: w * frac, height: 4).offset(x: inset)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    if duration > 0 {
                        Capsule().fill(Color.yellow).frame(width: 3, height: 12)
                            .offset(x: inset + w * CGFloat(min(m / duration, 1)) - 1.5)
                    }
                }
                Circle().fill(Color.accentBlue)
                    .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 2.5))
                    .frame(width: d, height: d)
                    .offset(x: inset + w * frac - d / 2)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; onBegan() }
                        let f = min(max((v.location.x - inset) / w, 0), 1)
                        onChanged(Double(f) * duration)
                    }
                    .onEnded { v in
                        let f = min(max((v.location.x - inset) / w, 0), 1)
                        dragging = false
                        onEnded(Double(f) * duration)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 36)
    }
}

struct LessonPlayerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.horizontalSizeClass) private var hSize
    @ObservedObject private var pm = PlayerModel.shared
    @State private var startOverride: Double?
    @State private var lessonID: UUID
    @AppStorage("playbackRate") private var savedRate: Double = 1.0
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("loopLesson") private var loopLesson = false

    @State private var showControls = true
    @State private var isFullscreen = false
    @State private var locked = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var flash: String?
    @State private var skipAccum = 0
    @State private var lastSkip = Date.distantPast
    @State private var dragMode: DragMode = .none
    @State private var dragStart: Double = 0
    @State private var hud: HUDInfo?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var countdown: Int?
    @State private var countTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var showPhotos = false
    @State private var busy = false
    @State private var preview: IdentURL?
    @State private var toastText: String?
    @State private var sleepTask: Task<Void, Never>?
    @State private var sleepLabel: String?
    @State private var editingBookmark: Bookmark?
    @State private var detailTab: DetailTab = .lessons
    @State private var renamingTitle = false
    @State private var titleText = ""
    @FocusState private var notesFocused: Bool
    @State private var bookmarkText = ""

    init(lessonID: UUID, startAt: Double? = nil) {
        _lessonID = State(initialValue: lessonID)
        _startOverride = State(initialValue: startAt)
    }

    private var lesson: Lesson? { store.lesson(lessonID) }
    private var full: Bool { isFullscreen || vSize == .compact }

    var body: some View {
        GeometryReader { root in
            let aspect = pm.videoAspect
            let inlineH: CGFloat = {
                let w = root.size.width
                guard aspect > 0 else { return w * 9 / 16 }
                return max(w * 9 / 16, min(w / aspect, root.size.height * 0.6))
            }()
            ZStack {
                Color.appBg.ignoresSafeArea()
                if full {
                    videoArea(insets: root.safeAreaInsets).ignoresSafeArea()
                } else if hSize == .regular {
                    let panelW = min(420, root.size.width * 0.38)
                    let vw = root.size.width - panelW
                    let ar: CGFloat = aspect > 0 ? aspect : 16.0 / 9.0
                    let vh = min(root.size.height - root.safeAreaInsets.top, vw / ar)
                    HStack(spacing: 0) {
                        details.frame(width: panelW)
                        ZStack {
                            Color.black.ignoresSafeArea()
                            videoArea(insets: root.safeAreaInsets).frame(height: vh)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        videoArea(insets: root.safeAreaInsets).frame(height: inlineH)
                        details
                    }
                }
                if busy { BusyOverlay() }
            }
        }
        .statusBarHidden(full)
        .persistentSystemOverlays(full ? .hidden : .automatic)
        .onAppear {
            pm.rate = Float(savedRate)
            pm.onProgress = { pos, dur in store.updateProgress(lessonID, position: pos, duration: dur) }
            pm.onWatch = { secs in store.addStudy(seconds: secs) }
            pm.onEnd = { handleEnd() }
            pm.onNext = { if let n = store.nextLesson(after: lessonID) { play(n.id) } }
            pm.onPrev = { if let p = store.previousLesson(before: lessonID) { play(p.id) } }
            pm.setupRemote()
            _ = pm.hostView
            pm.viewVisible = true
            pm.onPiPStart = { dismiss() }
            let pipWasActive = pm.pip?.isPictureInPictureActive ?? false
            if pipWasActive { pm.pip?.stopPictureInPicture() }
            if pm.currentLessonID == lessonID, pm.player.currentItem != nil, startOverride == nil {
                if let l = store.lesson(lessonID) { pm.nowTitle = l.title; pm.nowSub = store.unit(l.unitID)?.title ?? "" }
                loadSubtitles()
                pokeControls()
            } else {
                play(lessonID)
            }
        }
        .onDisappear {
            pm.viewVisible = false
            pm.onPiPStart = nil
            if !(pm.pip?.isPictureInPictureActive ?? false) { pm.stop() }
            hideTask?.cancel()
            sleepTask?.cancel()
            countTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            setOrientation(.portrait)
        }
        .onChange(of: pm.isPlaying) { playing in
            UIApplication.shared.isIdleTimerDisabled = playing
            pm.updateNowPlaying()
        }
        .onChange(of: store.files.count) { _ in loadSubtitles() }
        .attachSources(showFiles: $showImporter, showPhotos: $showPhotos, busy: $busy,
                       subjectID: lesson?.subjectID ?? UUID(), lessonID: lessonID) { toastText = $0 }
        .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
        .alert("تعديل عنوان الفيديو", isPresented: $renamingTitle) {
            TextField("العنوان", text: $titleText)
            Button("حفظ") {
                let t = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, let l = lesson { store.renameLesson(l, to: t); pm.nowTitle = t }
            }
            Button("إلغاء", role: .cancel) {}
        }
        .alert("ملاحظة العلامة", isPresented: Binding(get: { editingBookmark != nil }, set: { if !$0 { editingBookmark = nil } })) {
            TextField("اكتب ملاحظة", text: $bookmarkText)
            Button("حفظ") { if let b = editingBookmark { store.updateBookmark(b, note: bookmarkText) }; editingBookmark = nil }
            Button("إلغاء", role: .cancel) { editingBookmark = nil }
        }
        .toast($toastText)
    }

    // MARK: video
    private func videoArea(insets: EdgeInsets) -> some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlayerLayerView(model: pm, fill: pm.fill)
                    .scaleEffect(zoom)
                    .offset(pan)
                VolumeHost().frame(width: 10, height: 10).opacity(0.01).allowsHitTesting(false)

                if locked {
                    Color.clear.contentShape(Rectangle())
                } else {
                    gestureLayer(size: geo.size)
                }

                if pm.subtitlesOn, !pm.subtitleText.isEmpty {
                    VStack {
                        Spacer()
                        Text(pm.subtitleText)
                            .font(.system(size: full ? 20 : 15, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 24)
                            .padding(.bottom, showControls && !locked ? 96 : 20)
                    }
                    .allowsHitTesting(false)
                }

                if pm.isBuffering { ProgressView().tint(.white).scaleEffect(1.4) }

                if let f = flash {
                    Text(f).font(.title2.bold()).foregroundColor(.white)
                        .padding(14).background(Color.black.opacity(0.55), in: Capsule())
                        .transition(.opacity)
                }

                if let h = hud {
                    VStack {
                        HStack(spacing: 10) {
                            Image(systemName: h.icon)
                            Text(h.text).monospacedDigit()
                            if let p = h.progress {
                                ProgressView(value: p).frame(width: 80).tint(.white)
                            }
                        }
                        .font(.subheadline.bold()).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(.top, full ? max(insets.top, 14) + 50 : 54)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if pm.holdBoost {
                    VStack {
                        Label("2x", systemImage: "forward.fill").font(.footnote.bold()).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .padding(.top, full ? max(insets.top, 14) + 8 : 14)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if let c = countdown, let n = store.nextLesson(after: lessonID) {
                    VStack(spacing: 10) {
                        Text("الدرس التالي خلال \(c)").font(.footnote).foregroundColor(.white.opacity(0.8))
                        Text(n.title).font(.headline).foregroundColor(.white).lineLimit(2).multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button { countTask?.cancel(); countdown = nil; play(n.id) } label: {
                                Text("تشغيل الآن").font(.subheadline.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 8).background(Color.accentBlue, in: Capsule())
                            }
                            Button { countTask?.cancel(); countdown = nil } label: {
                                Text("إلغاء").font(.subheadline.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 8).background(Color.white.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    .padding(18)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                    .padding(24)
                }

                if showControls && !locked { controls(insets: insets).transition(.opacity) }

                if locked {
                    HStack {
                        Button { locked = false; pokeControls() } label: {
                            Image(systemName: "lock.fill").foregroundColor(.white)
                                .frame(width: 44, height: 44).background(Color.black.opacity(0.55), in: Circle())
                        }
                        .padding(.leading, full ? max(insets.leading, 16) + 8 : 16)
                        Spacer()
                    }
                    .opacity(0.75)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .clipped()
        }
    }

    // MARK: gestures
    private func gestureLayer(size: CGSize) -> some View {
        HStack(spacing: 0) {
            tapZone(forward: false)
            tapZone(forward: true)
        }
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { dragChanged($0, size: size) }
                .onEnded { _ in dragEnded() }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { s in zoom = min(max(lastZoom * s, 1), 4) }
                .onEnded { _ in
                    lastZoom = zoom
                    if zoom < 1.05 {
                        withAnimation(.easeOut(duration: 0.2)) { zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero }
                    } else {
                        flashText(String(format: "تكبير %.1fx", Double(zoom)))
                    }
                }
        )
    }

    private func tapZone(forward: Bool) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapSkip(forward) }
            .onTapGesture { toggleControls() }
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 40, pressing: { pressing in
                if !pressing { pm.setHold(false) }
            }, perform: { pm.setHold(true); haptic() })
    }

    private func doubleTapSkip(_ forward: Bool) {
        let now = Date()
        let step = forward ? 10 : -10
        if now.timeIntervalSince(lastSkip) < 1.0, (skipAccum > 0) == forward { skipAccum += step } else { skipAccum = step }
        lastSkip = now
        pm.skip(Double(step))
        flashText(skipAccum > 0 ? "+\(skipAccum)" : "\(skipAccum)")
    }

    private func dragChanged(_ v: DragGesture.Value, size: CGSize) {
        if dragMode == .none {
            if zoom > 1.05 {
                dragMode = .pan
            } else if abs(v.translation.width) > abs(v.translation.height) {
                dragMode = .seek; dragStart = pm.current; scrubbing = true
            } else if v.startLocation.x < size.width / 2 {
                dragMode = .brightness; dragStart = Double(UIScreen.main.brightness)
            } else {
                dragMode = .volume; dragStart = Double(SystemVolume.current)
            }
        }
        switch dragMode {
        case .pan:
            let maxX = size.width * (zoom - 1) / 2
            let maxY = size.height * (zoom - 1) / 2
            pan = CGSize(width: min(max(lastPan.width + v.translation.width, -maxX), maxX),
                         height: min(max(lastPan.height + v.translation.height, -maxY), maxY))
        case .seek:
            let span = min(max(pm.duration, 60), 240)
            let t = max(0, min(dragStart + Double(v.translation.width / max(size.width, 1)) * span, max(pm.duration, 0)))
            scrubValue = t
            let delta = Int(t - dragStart)
            hud = HUDInfo(icon: delta >= 0 ? "goforward" : "gobackward",
                          text: "\(playerTime(t))  (\(delta >= 0 ? "+" : "-")\(abs(delta))ث)", progress: nil)
        case .brightness:
            let val = max(0, min(dragStart - Double(v.translation.height / max(size.height * 0.8, 1)), 1))
            UIScreen.main.brightness = CGFloat(val)
            hud = HUDInfo(icon: "sun.max.fill", text: "\(Int(val * 100))%", progress: val)
        case .volume:
            let val = max(0, min(dragStart - Double(v.translation.height / max(size.height * 0.8, 1)), 1))
            SystemVolume.set(Float(val))
            hud = HUDInfo(icon: val == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", text: "\(Int(val * 100))%", progress: val)
        case .none: break
        }
    }

    private func dragEnded() {
        if dragMode == .seek { pm.seek(to: scrubValue); scrubbing = false }
        if dragMode == .pan { lastPan = pan }
        dragMode = .none
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if dragMode == .none { withAnimation { hud = nil } }
        }
    }

    // MARK: controls
    private var hasTracks: Bool { !pm.cues.isEmpty || !pm.legibleOptions.isEmpty || pm.audioOptions.count > 1 }

    private func controls(insets: EdgeInsets) -> some View {
        let iconS: CGFloat = full ? 28 : 24
        let topPad: CGFloat = full ? max(insets.top, 14) + 4 : 10
        let bottomPad: CGFloat = full ? max(insets.bottom, 10) + 4 : 2
        let sidePad: CGFloat = full ? max(max(insets.leading, insets.trailing), 16) + 8 : 16
        return ZStack {
            Color.black.opacity(0.32).allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    HStack(spacing: full ? 26 : 18) {
                        if pm.pip != nil {
                            Button { togglePiP() } label: { Image(systemName: "pip.enter").font(.system(size: iconS - 2)) }
                        }
                        AirPlayButton().frame(width: iconS + 6, height: iconS + 6)
                        if hasTracks { tracksMenu(iconS) }
                        gearMenu(iconS)
                    }
                    .foregroundColor(.white)
                    if full, let l = lesson {
                        Text(l.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.leading, 18)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: iconS * 0.6, weight: .bold)).foregroundColor(.white)
                            .frame(width: iconS + 16, height: iconS + 16)
                            .background(Color.white.opacity(0.25), in: Circle())
                    }
                }
                .padding(.top, topPad)

                Spacer()

                HStack(spacing: full ? 96 : 66) {
                    Button { if let p = store.previousLesson(before: lessonID) { play(p.id) } } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: full ? 40 : 32))
                    }
                    .opacity(store.previousLesson(before: lessonID) == nil ? 0.35 : 1)
                    Button { pm.togglePlay(); pokeControls() } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: full ? 66 : 50))
                            .frame(width: full ? 84 : 64, height: full ? 84 : 64)
                    }
                    Button { if let n = store.nextLesson(after: lessonID) { play(n.id) } } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: full ? 40 : 32))
                    }
                    .opacity(store.nextLesson(after: lessonID) == nil ? 0.35 : 1)
                }
                .foregroundColor(.white)

                Spacer()

                HStack(alignment: .center) {
                    Text("\(playerTime(scrubbing ? scrubValue : pm.current)) / \(playerTime(pm.duration))")
                        .font(.system(size: full ? 21 : 16, weight: .medium)).monospacedDigit()
                        .foregroundColor(.white)
                    Spacer()
                    HStack(spacing: full ? 34 : 24) {
                        Button { addBookmark() } label: { Image(systemName: "bookmark").font(.system(size: iconS)) }
                        speedMenu(iconS)
                        Button { toggleFullscreen() } label: {
                            Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: iconS))
                        }
                    }
                    .foregroundColor(.white)
                }
                VideoScrubber(
                    value: scrubbing ? scrubValue : pm.current,
                    duration: pm.duration,
                    buffered: pm.buffered,
                    markers: store.bookmarks(of: lessonID).map { $0.time },
                    onBegan: { scrubbing = true; scrubValue = pm.current; hideTask?.cancel() },
                    onChanged: { scrubValue = $0 },
                    onEnded: { pm.seek(to: $0); scrubbing = false; pokeControls() }
                )
                .padding(.horizontal, -sidePad)
                .padding(.bottom, -4)
            }
            .padding(.horizontal, sidePad)
            .padding(.bottom, bottomPad)
        }
    }

    private func tracksMenu(_ s: CGFloat) -> some View {
        Menu {
            Button { pm.disableSubtitles() } label: {
                Label("بدون ترجمة", systemImage: (!pm.subtitlesOn && pm.selectedLegible == nil) ? "checkmark" : "text.bubble")
            }
            if !pm.cues.isEmpty {
                Button { pm.useFileSubtitles() } label: {
                    Label("ترجمة الملف المرفق", systemImage: pm.subtitlesOn ? "checkmark" : "doc.text")
                }
            }
            ForEach(Array(pm.legibleOptions.enumerated()), id: \.offset) { _, o in
                Button { pm.selectLegible(o) } label: {
                    Label(o.displayName, systemImage: pm.selectedLegible == o ? "checkmark" : "captions.bubble")
                }
            }
            if pm.audioOptions.count > 1 {
                Section("الصوت") {
                    ForEach(Array(pm.audioOptions.enumerated()), id: \.offset) { _, o in
                        Button { pm.selectAudio(o) } label: {
                            Label(o.displayName, systemImage: pm.selectedAudio == o ? "checkmark" : "speaker.wave.2")
                        }
                    }
                }
            }
        } label: { Image(systemName: "captions.bubble").font(.system(size: s - 2)).foregroundColor(.white) }
    }

    private func gearMenu(_ s: CGFloat) -> some View {
        Menu {
            Toggle("تشغيل الدرس التالي تلقائياً", isOn: $autoNext)
            Toggle("تكرار الدرس", isOn: $loopLesson)
            Button {
                withAnimation { pm.fill.toggle() }
                if let sid = lesson?.subjectID { store.setFill(pm.fill, subjectID: sid) }
            } label: {
                Label(pm.fill ? "احتواء الفيديو" : "ملء الشاشة بالفيديو", systemImage: "aspectratio")
            }
            if vSize != .compact {
                Button { withAnimation { isFullscreen.toggle() }; pokeControls() } label: {
                    Label(isFullscreen ? "تصغير الفيديو" : "تكبير الفيديو (وضع طولي)", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            if zoom > 1.01 {
                Button {
                    withAnimation { zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero }
                } label: { Label("إعادة التكبير", systemImage: "arrow.down.right.and.arrow.up.left") }
            }
            Button { locked = true; withAnimation { showControls = false } } label: {
                Label("قفل الشاشة", systemImage: "lock.fill")
            }
            Divider()
            Section("مؤقت النوم") {
                Button { startSleep(0) } label: { Label("إيقاف المؤقت", systemImage: "moon.zzz") }
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    Button { startSleep(m) } label: { Label("\(m) دقيقة", systemImage: "moon") }
                }
            }
        } label: { Image(systemName: sleepLabel == nil ? "gearshape.fill" : "moon.fill").font(.system(size: s - 2)).foregroundColor(.white) }
    }

    private func speedMenu(_ s: CGFloat) -> some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { r in
                Button {
                    savedRate = r; pm.setRate(Float(r)); pokeControls()
                    if let sid = lesson?.subjectID { store.setRate(r, subjectID: sid) }
                } label: {
                    Label(rateLabel(r), systemImage: abs(savedRate - r) < 0.01 ? "checkmark" : "speedometer")
                }
            }
        } label: {
            ZStack {
                Image(systemName: "play.circle").font(.system(size: s))
                if abs(savedRate - 1) > 0.01 {
                    Text(rateLabel(savedRate)).font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 3).background(Color.accentBlue, in: Capsule())
                        .offset(x: 10, y: -12)
                }
            }
            .foregroundColor(.white)
        }
    }

    private func rateLabel(_ r: Double) -> String {
        r == r.rounded() ? "\(Int(r))x" : String(format: "%gx", r)
    }

    // MARK: details
    private enum DetailTab: String, CaseIterable {
        case lessons = "الدروس", notes = "ملاحظاتي", marks = "العلامات", files = "الملفات"
        var icon: String {
            switch self {
            case .lessons: return "list.bullet.rectangle.portrait.fill"
            case .notes: return "note.text"
            case .marks: return "bookmark.fill"
            case .files: return "paperclip"
            }
        }
    }

    private func tabCount(_ t: DetailTab, _ l: Lesson) -> Int {
        switch t {
        case .lessons: return store.lessons(in: l.unitID).count
        case .notes: return store.note(for: l.id).isEmpty ? 0 : 1
        case .marks: return store.bookmarks(of: l.id).count
        case .files: return store.attachments(of: l.id).count
        }
    }

    private var details: some View {
        ScrollView {
            if let l = lesson {
                VStack(alignment: .leading, spacing: 16) {
                    // header card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(l.title).font(.title3.bold()).foregroundColor(.white)
                            Spacer(minLength: 0)
                            Button { titleText = l.title; renamingTitle = true } label: {
                                Image(systemName: "pencil").font(.footnote.bold()).foregroundColor(.dim)
                                    .frame(width: 32, height: 32).background(Color.white.opacity(0.08), in: Circle())
                            }
                        }
                        HStack(spacing: 8) {
                            if let u = store.unit(l.unitID) {
                                chip(u.title, icon: "rectangle.stack.fill")
                            }
                            if pm.duration > 0 { chip(formatTime(pm.duration), icon: "clock.fill") }
                            Spacer(minLength: 0)
                            Button { store.toggleDone(l); haptic() } label: {
                                Label(l.isDone ? "تمت المشاهدة" : "تعليم كمكتمل", systemImage: l.isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.caption.bold())
                                    .foregroundColor(l.isDone ? .doneGreen : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background((l.isDone ? Color.doneGreen.opacity(0.18) : Color.white.opacity(0.1)), in: Capsule())
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))

                    // tab bar
                    HStack(spacing: 6) {
                        ForEach(DetailTab.allCases, id: \.self) { t in
                            let on = detailTab == t
                            let n = tabCount(t, l)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { detailTab = t }
                                if t != .notes { notesFocused = false }
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: t.icon).font(.subheadline.weight(.semibold))
                                    Text(n > 0 && t != .notes ? "\(t.rawValue) \(n)" : t.rawValue).font(.caption2.bold()).lineLimit(1)
                                }
                                .foregroundColor(on ? .white : .dim)
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(on ? AnyShapeStyle(Color.accentBlue) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Group {
                        switch detailTab {
                        case .lessons: lessonsTab(l)
                        case .notes: notesTab(l)
                        case .marks: marksTab(l)
                        case .files: filesTab(l)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.appBg.opacity(0.0))
    }

    private func chip(_ t: String, icon: String) -> some View {
        Label(t, systemImage: icon)
            .font(.caption).foregroundColor(.dim).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func emptyHint(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title).foregroundColor(.white.opacity(0.25))
            Text(text).font(.footnote).foregroundColor(.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private func lessonsTab(_ l: Lesson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.lessons(in: l.unitID)) { x in lessonCard(x) }
        }
    }

    private func notesTab(_ l: Lesson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.note(for: l.id) }, set: { store.setNote($0, for: l.id) }))
                    .focused($notesFocused)
                    .scrollContentBackground(.hidden)
                    .foregroundColor(.white)
                    .frame(minHeight: 170)
                    .padding(8)
                if store.note(for: l.id).isEmpty && !notesFocused {
                    Text("اكتب ملاحظاتك عن هذا الدرس…").font(.subheadline).foregroundColor(.dim)
                        .padding(.horizontal, 14).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(notesFocused ? Color.accentBlue.opacity(0.8) : Color.white.opacity(0.06), lineWidth: 1.5))
            if notesFocused {
                Button { notesFocused = false } label: {
                    Label("إخفاء الكيبورد", systemImage: "keyboard.chevron.compact.down")
                        .font(.subheadline.bold()).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.accentBlue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func marksTab(_ l: Lesson) -> some View {
        let bms = store.bookmarks(of: l.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button { addBookmark() } label: {
                Label("إضافة علامة عند \(formatTime(pm.current))", systemImage: "bookmark.fill")
                    .font(.subheadline.bold()).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.accentBlue.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if bms.isEmpty { emptyHint("bookmark", "أضف علامات على اللحظات المهمة في الفيديو للرجوع لها بسرعة") }
            ForEach(bms) { b in
                HStack(spacing: 10) {
                    Button { pm.seek(to: b.time); pm.player.play(); pm.player.rate = pm.rate; pokeControls() } label: {
                        HStack(spacing: 12) {
                            Text(formatTime(b.time)).font(.footnote.bold().monospacedDigit()).foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.accentBlue, in: Capsule())
                            Text(b.note.isEmpty ? "علامة" : b.note).font(.subheadline).foregroundColor(.white).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { bookmarkText = b.note; editingBookmark = b } label: {
                        Image(systemName: "pencil").font(.footnote).foregroundColor(.dim)
                            .frame(width: 34, height: 34).background(Color.white.opacity(0.07), in: Circle())
                    }
                    Button { withAnimation { store.deleteBookmark(b) }; haptic() } label: {
                        Image(systemName: "trash").font(.footnote).foregroundColor(.red.opacity(0.9))
                            .frame(width: 34, height: 34).background(Color.red.opacity(0.14), in: Circle())
                    }
                }
                .padding(10)
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func filesTab(_ l: Lesson) -> some View {
        let atts = store.attachments(of: l.id)
        return VStack(alignment: .leading, spacing: 10) {
            Menu {
                Button { showImporter = true } label: { Label("من تطبيق الملفات", systemImage: "folder") }
                Button { showPhotos = true } label: { Label("صورة من الاستوديو", systemImage: "photo") }
            } label: {
                Label("إرفاق ملف", systemImage: "paperclip")
                    .font(.subheadline.bold()).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.accentBlue.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if atts.isEmpty { emptyHint("doc.on.doc", "ما فيه ملفات مرفقة بهذا الدرس") }
            ForEach(atts) { f in
                FileRow(file: f)
                    .onTapGesture { preview = IdentURL(url: store.url(for: f.fileName)) }
                    .contextMenu {
                        Button(role: .destructive) { store.deleteFile(f) } label: { Label("حذف", systemImage: "trash") }
                    }
            }
        }
    }

    private func lessonCard(_ x: Lesson) -> some View {
        let isCurrent = x.id == lessonID
        return Button { if !isCurrent { play(x.id) } } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    LessonThumb(url: store.url(for: x.fileName))
                    if isCurrent {
                        Color.black.opacity(0.45)
                        Image(systemName: "waveform").foregroundColor(.white).frame(maxHeight: .infinity)
                    }
                    if x.progress > 0 {
                        GeometryReader { g in
                            Rectangle().fill(Color.accentBlue)
                                .frame(width: g.size.width * CGFloat(x.progress), height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(x.title).font(.subheadline.weight(.semibold)).foregroundColor(.white).multilineTextAlignment(.leading).lineLimit(2)
                    if x.isDone {
                        Text("مكتمل").font(.caption2.bold()).foregroundColor(.doneGreen)
                    } else if x.duration > 0 {
                        Text(formatTime(x.duration)).font(.caption).foregroundColor(.dim)
                    }
                }
                Spacer(minLength: 0)
                ProgressRing(progress: x.progress, size: 24)
            }
            .padding(10)
            .background(isCurrent ? Color.cardBg2 : Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isCurrent ? Color.accentBlue : Color.white.opacity(0.05), lineWidth: isCurrent ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: actions
    private func play(_ id: UUID) {
        pm.flush()
        countTask?.cancel(); countdown = nil
        lessonID = id
        guard let l = store.lesson(id) else { return }
        store.setLast(id)
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
        let pr = store.prefs(for: l.subjectID)
        if let r = pr.rate { savedRate = r }
        pm.rate = Float(savedRate)
        if let f = pr.fill { pm.fill = f }
        pm.nowTitle = l.title
        pm.nowSub = store.unit(l.unitID)?.title ?? ""
        loadSubtitles()
        pm.currentLessonID = id
        let start = startOverride ?? (l.isDone ? 0 : l.position)
        startOverride = nil
        pm.load(url: store.url(for: l.fileName), startAt: start)
        pokeControls()
    }

    private func loadSubtitles() {
        guard let l = lesson else { return }
        let att = store.attachments(of: l.id).first {
            ["srt", "vtt"].contains(($0.fileName as NSString).pathExtension.lowercased())
        }
        guard let a = att, let data = try? Data(contentsOf: store.url(for: a.fileName)) else {
            pm.setCues([]); return
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))))
            ?? String(decoding: data, as: UTF8.self)
        pm.setCues(SRT.parse(text))
    }

    private func handleEnd() {
        if loopLesson {
            pm.seek(to: 0); pm.player.play(); pm.player.rate = pm.rate
            return
        }
        showControls = true
        startCountdown()
    }

    private func startCountdown() {
        guard autoNext, let n = store.nextLesson(after: lessonID) else { return }
        countdown = 5
        countTask?.cancel()
        countTask = Task {
            while let c = countdown, c > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown = c - 1
            }
            if !Task.isCancelled { countdown = nil; play(n.id) }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { pokeControls() }
    }

    private func pokeControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled && pm.isPlaying && !scrubbing {
                withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
            }
        }
    }

    private func flashText(_ s: String) {
        withAnimation { flash = s }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            withAnimation { flash = nil }
        }
    }

    private func addBookmark() {
        guard let l = lesson else { return }
        store.addBookmark(lessonID: l.id, time: pm.current, note: "")
        haptic(.medium)
        toastText = "تمت إضافة علامة عند \(formatTime(pm.current)) ✓"
    }

    private func togglePiP() {
        guard let c = pm.pip else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    private func startSleep(_ minutes: Int) {
        sleepTask?.cancel()
        guard minutes > 0 else { sleepLabel = nil; toastText = "تم إيقاف مؤقت النوم"; return }
        sleepLabel = "\(minutes)"
        toastText = "سيتوقف الفيديو بعد \(minutes) دقيقة"
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            if !Task.isCancelled {
                pm.player.pause()
                sleepLabel = nil
                toastText = "انتهى مؤقت النوم"
            }
        }
    }

    private func toggleFullscreen() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if full {
            isFullscreen = false
            if !isPad { setOrientation(.portrait) }
        } else if isPad {
            isFullscreen = true
        } else {
            // rotate the whole screen; the layout switches by itself when the size class changes
            setOrientation(.landscape)
        }
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
        pokeControls()
    }
}
