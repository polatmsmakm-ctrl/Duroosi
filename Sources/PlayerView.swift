import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

private enum DragMode { case none, seek, brightness, volume }
private struct HUDInfo { let icon: String; let text: String; let progress: Double? }

struct LessonPlayerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var vSize
    @StateObject private var pm = PlayerModel()
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
    @State private var bookmarkText = ""

    init(lessonID: UUID) { _lessonID = State(initialValue: lessonID) }

    private var lesson: Lesson? { store.lesson(lessonID) }
    private var full: Bool { isFullscreen || vSize == .compact }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            if full {
                videoArea.ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    videoArea.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    details
                }
            }
            if busy { BusyOverlay() }
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
            play(lessonID)
        }
        .onDisappear {
            pm.stop()
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
        .alert("ملاحظة العلامة", isPresented: Binding(get: { editingBookmark != nil }, set: { if !$0 { editingBookmark = nil } })) {
            TextField("اكتب ملاحظة", text: $bookmarkText)
            Button("حفظ") { if let b = editingBookmark { store.updateBookmark(b, note: bookmarkText) }; editingBookmark = nil }
            Button("إلغاء", role: .cancel) { editingBookmark = nil }
        }
        .toast($toastText)
    }

    // MARK: video
    private var videoArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlayerLayerView(model: pm, fill: pm.fill)
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
                            .padding(.bottom, showControls && !locked ? 70 : 16)
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
                        .padding(.top, 54)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if pm.holdBoost {
                    VStack {
                        Label("2x", systemImage: "forward.fill").font(.footnote.bold()).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .padding(.top, 14)
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

                if showControls && !locked { controls.transition(.opacity) }

                if locked {
                    HStack {
                        Button { locked = false; pokeControls() } label: {
                            Image(systemName: "lock.fill").foregroundColor(.white)
                                .frame(width: 42, height: 42).background(Color.black.opacity(0.55), in: Circle())
                        }
                        .padding(.leading, 16)
                        Spacer()
                    }
                    .opacity(0.7)
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
            MagnificationGesture().onEnded { s in
                withAnimation { pm.fill = s > 1 }
                flashText(s > 1 ? "ملء الشاشة" : "الحجم الأصلي")
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
            if abs(v.translation.width) > abs(v.translation.height) {
                dragMode = .seek; dragStart = pm.current; scrubbing = true
            } else if v.startLocation.x < size.width / 2 {
                dragMode = .brightness; dragStart = Double(UIScreen.main.brightness)
            } else {
                dragMode = .volume; dragStart = Double(SystemVolume.current)
            }
        }
        switch dragMode {
        case .seek:
            let span = min(max(pm.duration, 60), 240)
            let t = max(0, min(dragStart + Double(v.translation.width / max(size.width, 1)) * span, max(pm.duration, 0)))
            scrubValue = t
            let delta = Int(t - dragStart)
            hud = HUDInfo(icon: delta >= 0 ? "goforward" : "gobackward",
                          text: "\(formatTime(t))  (\(delta >= 0 ? "+" : "-")\(abs(delta))ث)", progress: nil)
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
        dragMode = .none
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if dragMode == .none { withAnimation { hud = nil } }
        }
    }

    // MARK: controls
    private var hasTracks: Bool { !pm.cues.isEmpty || !pm.legibleOptions.isEmpty || pm.audioOptions.count > 1 }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack(spacing: 8) {
                    Button { dismiss() } label: { circleIcon("xmark") }
                    if full, let l = lesson {
                        Text(l.title).font(.footnote.bold()).foregroundColor(.white).lineLimit(1)
                    }
                    Spacer()
                    AirPlayButton().frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.45), in: Circle())
                    if pm.pip != nil {
                        Button { togglePiP() } label: { circleIcon("pip.enter") }
                    }
                    if hasTracks { tracksMenu }
                    gearMenu
                    speedMenu
                }
                .padding(.horizontal, 14).padding(.top, full ? 18 : 10)

                Spacer()

                HStack(spacing: full ? 44 : 30) {
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
                    ZStack {
                        GeometryReader { g in
                            ForEach(store.bookmarks(of: lessonID)) { b in
                                if pm.duration > 0 {
                                    Capsule().fill(Color.yellow)
                                        .frame(width: 3, height: 12)
                                        .position(x: 14 + (g.size.width - 28) * CGFloat(min(b.time / pm.duration, 1)), y: g.size.height / 2)
                                }
                            }
                        }
                        .allowsHitTesting(false)
                        Slider(
                            value: Binding(get: { scrubbing ? scrubValue : pm.current }, set: { scrubValue = $0 }),
                            in: 0...max(pm.duration, 1),
                            onEditingChanged: { editing in
                                if editing { scrubbing = true; scrubValue = pm.current }
                                else { pm.seek(to: scrubValue); scrubbing = false }
                                pokeControls()
                            })
                            .tint(.accentBlue)
                    }
                    .frame(height: 28)
                    HStack(spacing: 20) {
                        Text("\(formatTime(scrubbing ? scrubValue : pm.current)) / \(formatTime(pm.duration))")
                            .font(.caption.monospacedDigit()).foregroundColor(.white)
                        Spacer()
                        Button { locked = true; withAnimation { showControls = false } } label: {
                            Image(systemName: "lock.open.fill").foregroundColor(.white)
                        }
                        Button { withAnimation { pm.fill.toggle() }; pokeControls() } label: {
                            Image(systemName: pm.fill ? "arrow.down.right.and.arrow.up.left.circle" : "aspectratio").foregroundColor(.white)
                        }
                        Button { addBookmark() } label: { Image(systemName: "bookmark.fill").foregroundColor(.white) }
                        Button { toggleFullscreen() } label: {
                            Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, full ? 14 : 6)
            }
        }
    }

    private var tracksMenu: some View {
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
        } label: { circleIcon("captions.bubble.fill") }
    }

    private var gearMenu: some View {
        Menu {
            Toggle("تشغيل الدرس التالي تلقائياً", isOn: $autoNext)
            Toggle("تكرار الدرس", isOn: $loopLesson)
            Button { withAnimation { pm.fill.toggle() } } label: {
                Label(pm.fill ? "احتواء الفيديو" : "ملء الشاشة", systemImage: "aspectratio")
            }
            Divider()
            Section("مؤقت النوم") {
                Button { startSleep(0) } label: { Label("إيقاف المؤقت", systemImage: "moon.zzz") }
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    Button { startSleep(m) } label: { Label("\(m) دقيقة", systemImage: "moon") }
                }
            }
        } label: { circleIcon(sleepLabel == nil ? "gearshape.fill" : "moon.fill") }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { r in
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
        countTask?.cancel(); countdown = nil
        lessonID = id
        guard let l = store.lesson(id) else { return }
        store.setLast(id)
        pm.nowTitle = l.title
        pm.nowSub = store.unit(l.unitID)?.title ?? ""
        loadSubtitles()
        pm.load(url: store.url(for: l.fileName), startAt: l.isDone ? 0 : l.position)
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
        if full { isFullscreen = false; setOrientation(.portrait) }
        else { isFullscreen = true; setOrientation(.landscape) }
        pokeControls()
    }
}
