import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isBuffering = false
    var rate: Float = 1
    var onProgress: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onWatch: ((Double) -> Void)?
    var pip: AVPictureInPictureController?
    private var pendingWatch: Double = 0

    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcObs: NSKeyValueObservation?
    private var lastSave: Double = -10

    init() {
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self else { return }
            let s = t.seconds
            if s.isFinite { self.current = s }
            if abs(s - self.lastSave) >= 3 { self.lastSave = s; self.flush() }
            if self.isPlaying {
                self.pendingWatch += 0.5
                if self.pendingWatch >= 10 { self.onWatch?(self.pendingWatch); self.pendingWatch = 0 }
            }
        }
        tcObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.isPlaying = p.timeControlStatus != .paused
                self?.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    deinit {
        if let t = timeObs { player.removeTimeObserver(t) }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
    }

    func load(url: URL, startAt: Double) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        current = startAt
        duration = 0
        lastSave = startAt
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.onProgress?(self.duration, self.duration)
            self.onEnd?()
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .readyToPlay {
                let d = it.duration.seconds
                DispatchQueue.main.async { self?.duration = d.isFinite ? d : 0 }
            }
        }
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        player.rate = rate
    }

    func flush() {
        let pos = player.currentTime().seconds
        if pos.isFinite, duration > 0 { onProgress?(pos, duration) }
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            player.play(); player.rate = rate
        } else { player.pause() }
    }
    func seek(to s: Double) {
        let t = max(0, min(s, duration > 0 ? duration : s))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
    }
    func skip(_ d: Double) { seek(to: player.currentTime().seconds + d) }
    func setRate(_ r: Float) {
        rate = r
        if player.timeControlStatus != .paused { player.rate = r }
    }
    func stop() {
        flush()
        if pendingWatch > 1 { onWatch?(pendingWatch) }
        pendingWatch = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let model: PlayerModel
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = model.player
        v.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let c = AVPictureInPictureController(playerLayer: v.playerLayer)
            c?.canStartPictureInPictureAutomaticallyFromInline = true
            model.pip = c
        }
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {}
}

private func setOrientation(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
}

struct LessonPlayerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pm = PlayerModel()
    @State private var lessonID: UUID
    @AppStorage("playbackRate") private var savedRate: Double = 1.0

    @State private var showControls = true
    @State private var isFullscreen = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var flash: String?
    @State private var showImporter = false
    @State private var showPhotos = false
    @State private var busy = false
    @State private var preview: IdentURL?
    @AppStorage("autoNext") private var autoNext = true
    @State private var toastText: String?
    @State private var sleepTask: Task<Void, Never>?
    @State private var sleepLabel: String?
    @State private var editingBookmark: Bookmark?
    @State private var bookmarkText = ""

    init(lessonID: UUID) { _lessonID = State(initialValue: lessonID) }

    private var lesson: Lesson? { store.lesson(lessonID) }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            if isFullscreen {
                videoArea.ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    videoArea.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    details
                }
            }
            if busy { BusyOverlay() }
        }
        .statusBarHidden(isFullscreen)
        .onAppear {
            pm.rate = Float(savedRate)
            pm.onProgress = { pos, dur in store.updateProgress(lessonID, position: pos, duration: dur) }
            pm.onWatch = { secs in store.addStudy(seconds: secs) }
            pm.onEnd = {
                if autoNext, let n = store.nextLesson(after: lessonID) { play(n.id) }
                else { showControls = true }
            }
            play(lessonID)
        }
        .onDisappear {
            pm.stop()
            hideTask?.cancel()
            sleepTask?.cancel()
            setOrientation(.portrait)
        }
        .attachSources(showFiles: $showImporter, showPhotos: $showPhotos, busy: $busy,
                       subjectID: lesson?.subjectID ?? UUID(), lessonID: lessonID) { toastText = $0 }
        .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
        .alert("ملاحظة العلامة", isPresented: Binding(get: { editingBookmark != nil }, set: { if !$0 { editingBookmark = nil } })) {
            TextField("اكتب ملاحظة", text: $bookmarkText)
            Button("حفظ") { if let b = editingBookmark { store.updateBookmark(b, note: bookmarkText) }; editingBookmark = nil }
            Button("إلغاء", role: .cancel) { editingBookmark = nil }
        }
        .toast($toastText)
    }

    // MARK: video
    private var videoArea: some View {
        ZStack {
            Color.black
            PlayerLayerView(model: pm)

            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { pm.skip(-10); flashText("-10") }
                    .onTapGesture { toggleControls() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { pm.skip(10); flashText("+10") }
                    .onTapGesture { toggleControls() }
            }

            if pm.isBuffering { ProgressView().tint(.white).scaleEffect(1.4) }

            if let f = flash {
                Text(f).font(.title2.bold()).foregroundColor(.white)
                    .padding(14).background(Color.black.opacity(0.55), in: Capsule())
                    .transition(.opacity)
            }

            if showControls { controls.transition(.opacity) }
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipped()
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Button { dismiss() } label: { circleIcon("xmark") }
                    Spacer()
                    AirPlayButton().frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.45), in: Circle())
                    if pm.pip != nil {
                        Button { togglePiP() } label: { circleIcon("pip.enter") }
                    }
                    Menu {
                        Toggle("تشغيل الدرس التالي تلقائياً", isOn: $autoNext)
                        Divider()
                        Section("مؤقت النوم") {
                            Button { startSleep(0) } label: { Label("إيقاف المؤقت", systemImage: "moon.zzz") }
                            ForEach([15, 30, 45, 60], id: \.self) { m in
                                Button { startSleep(m) } label: { Label("\(m) دقيقة", systemImage: "moon") }
                            }
                        }
                    } label: {
                        ZStack {
                            circleIcon(sleepLabel == nil ? "gearshape.fill" : "moon.fill")
                        }
                    }
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                            Button {
                                savedRate = r; pm.setRate(Float(r)); pokeControls()
                            } label: {
                                Label(rateLabel(r), systemImage: abs(savedRate - r) < 0.01 ? "checkmark" : "speedometer")
                            }
                        }
                    } label: {
                        Text(rateLabel(savedRate)).font(.footnote.bold()).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(Color.black.opacity(0.45), in: Capsule())
                    }
                }
                .padding(.horizontal, 14).padding(.top, isFullscreen ? 18 : 10)

                Spacer()

                HStack(spacing: 34) {
                    Button { if let p = store.previousLesson(before: lessonID) { play(p.id) } } label: {
                        Image(systemName: "backward.end.fill").font(.title2)
                    }
                    .opacity(store.previousLesson(before: lessonID) == nil ? 0.35 : 1)
                    Button { pm.skip(-10); pokeControls() } label: { Image(systemName: "gobackward.10").font(.title) }
                    Button { pm.togglePlay(); pokeControls() } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 38))
                            .frame(width: 66, height: 66)
                    }
                    Button { pm.skip(10); pokeControls() } label: { Image(systemName: "goforward.10").font(.title) }
                    Button { if let n = store.nextLesson(after: lessonID) { play(n.id) } } label: {
                        Image(systemName: "forward.end.fill").font(.title2)
                    }
                    .opacity(store.nextLesson(after: lessonID) == nil ? 0.35 : 1)
                }
                .foregroundColor(.white)

                Spacer()

                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { scrubbing ? scrubValue : pm.current }, set: { scrubValue = $0 }),
                        in: 0...max(pm.duration, 1),
                        onEditingChanged: { editing in
                            if editing { scrubbing = true; scrubValue = pm.current }
                            else { pm.seek(to: scrubValue); scrubbing = false }
                            pokeControls()
                        })
                        .tint(.accentBlue)
                    HStack {
                        Text("\(formatTime(scrubbing ? scrubValue : pm.current)) / \(formatTime(pm.duration))")
                            .font(.caption.monospacedDigit()).foregroundColor(.white)
                        Spacer()
                        Button { addBookmark() } label: {
                            Image(systemName: "bookmark.fill").foregroundColor(.white)
                        }
                        .padding(.trailing, 14)
                        Button { toggleFullscreen() } label: {
                            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, isFullscreen ? 14 : 6)
            }
        }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name).font(.subheadline.bold()).foregroundColor(.white)
            .frame(width: 34, height: 34).background(Color.black.opacity(0.45), in: Circle())
    }

    private func rateLabel(_ r: Double) -> String {
        r == r.rounded() ? "\(Int(r))x" : String(format: "%gx", r)
    }

    // MARK: details
    private var details: some View {
        ScrollView {
            if let l = lesson {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l.title).font(.title3.bold()).foregroundColor(.white)
                        HStack(spacing: 10) {
                            if let u = store.unit(l.unitID) {
                                Text(u.title).font(.footnote).foregroundColor(.dim)
                            }
                            if pm.duration > 0 {
                                Text("• مدة الدرس \(formatTime(pm.duration))").font(.footnote).foregroundColor(.dim)
                            }
                        }
                        Button { store.toggleDone(l) ; haptic() } label: {
                            Label(l.isDone ? "تمت المشاهدة" : "تعليم كمكتمل", systemImage: l.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.footnote.bold())
                                .foregroundColor(l.isDone ? .doneGreen : .white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Color.cardBg2, in: Capsule())
                        }
                    }

                    // bookmarks
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("العلامات").font(.headline).foregroundColor(.white)
                            Spacer()
                            Button { addBookmark() } label: {
                                Label("علامة هنا", systemImage: "bookmark.fill").font(.footnote.bold())
                            }
                        }
                        let bms = store.bookmarks(of: l.id)
                        if bms.isEmpty {
                            Text("أضف علامات على اللحظات المهمة في الفيديو للرجوع لها بسرعة").font(.footnote).foregroundColor(.dim)
                        }
                        ForEach(bms) { b in
                            Button { pm.seek(to: b.time); pm.player.play(); pm.player.rate = pm.rate; pokeControls() } label: {
                                HStack(spacing: 12) {
                                    Text(formatTime(b.time)).font(.footnote.bold().monospacedDigit()).foregroundColor(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color.accentBlue, in: Capsule())
                                    Text(b.note.isEmpty ? "علامة" : b.note).font(.subheadline).foregroundColor(.white).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { bookmarkText = b.note; editingBookmark = b } label: { Label("تعديل الملاحظة", systemImage: "pencil") }
                                Button(role: .destructive) { store.deleteBookmark(b) } label: { Label("حذف", systemImage: "trash") }
                            }
                        }
                    }

                    // notes
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ملاحظاتي").font(.headline).foregroundColor(.white)
                        TextEditor(text: Binding(get: { store.note(for: l.id) }, set: { store.setNote($0, for: l.id) }))
                            .scrollContentBackground(.hidden)
                            .foregroundColor(.white)
                            .frame(minHeight: 110)
                            .padding(8)
                            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // lesson files
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("ملفات الدرس").font(.headline).foregroundColor(.white)
                            Spacer()
                            Menu {
                                Button { showImporter = true } label: { Label("من تطبيق الملفات", systemImage: "folder") }
                                Button { showPhotos = true } label: { Label("صورة من الاستوديو", systemImage: "photo") }
                            } label: {
                                Label("إرفاق", systemImage: "paperclip").font(.footnote.bold())
                            }
                        }
                        let atts = store.attachments(of: l.id)
                        if atts.isEmpty {
                            Text("ما فيه ملفات مرفقة بهذا الدرس").font(.footnote).foregroundColor(.dim)
                        }
                        ForEach(atts) { f in
                            FileRow(file: f)
                                .onTapGesture { preview = IdentURL(url: store.url(for: f.fileName)) }
                                .contextMenu {
                                    Button(role: .destructive) { store.deleteFile(f) } label: { Label("حذف", systemImage: "trash") }
                                }
                        }
                    }

                    // unit lessons
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.unit(l.unitID)?.title ?? "دروس الوحدة").font(.headline).foregroundColor(.white)
                        ForEach(store.lessons(in: l.unitID)) { x in lessonCard(x) }
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
        }
        .background(Color.appBg.opacity(0.0))
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
        lessonID = id
        guard let l = store.lesson(id) else { return }
        store.setLast(id)
        pm.load(url: store.url(for: l.fileName), startAt: l.isDone ? 0 : l.position)
        pokeControls()
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
            try? await Task.sleep(nanoseconds: 700_000_000)
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
        isFullscreen.toggle()
        setOrientation(isFullscreen ? .landscape : .portrait)
        pokeControls()
    }
}
