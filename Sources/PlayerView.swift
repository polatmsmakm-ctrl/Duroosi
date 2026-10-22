import SwiftUI
import AVFoundation
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
    func stop() { flush(); player.pause(); player.replaceCurrentItem(with: nil) }
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
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
    @State private var busy = false
    @State private var preview: IdentURL?

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
            pm.onEnd = {
                if let n = store.nextLesson(after: lessonID) { play(n.id) }
                else { showControls = true }
            }
            play(lessonID)
        }
        .onDisappear {
            pm.stop()
            hideTask?.cancel()
            setOrientation(.portrait)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty, let l = lesson else { return }
            Task { busy = true; await store.importFiles(urls, subjectID: l.subjectID, lessonID: l.id); busy = false }
        }
        .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
    }

    // MARK: video
    private var videoArea: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: pm.player)

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

                    // lesson files
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("ملفات الدرس").font(.headline).foregroundColor(.white)
                            Spacer()
                            Button { showImporter = true } label: {
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

    private func toggleFullscreen() {
        isFullscreen.toggle()
        setOrientation(isFullscreen ? .landscape : .portrait)
        pokeControls()
    }
}
