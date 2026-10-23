import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer

struct Cue { let start: Double; let end: Double; let text: String }

enum SRT {
    static func parse(_ raw: String) -> [Cue] {
        let norm = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in norm.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1]) else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !body.isEmpty { cues.append(Cue(start: a, end: b, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func time(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0].replacingOccurrences(of: ",", with: ".")
        let p = t.split(separator: ":").map(String.init)
        guard p.count >= 2 else { return nil }
        let nums = p.compactMap { Double($0) }
        guard nums.count == p.count else { return nil }
        if nums.count == 3 { return nums[0] * 3600 + nums[1] * 60 + nums[2] }
        return nums[0] * 60 + nums[1]
    }
}

enum SystemVolume {
    static weak var host: MPVolumeView?
    static func set(_ v: Float) {
        DispatchQueue.main.async {
            let slider = host?.subviews.compactMap { $0 as? UISlider }.first
            slider?.setValue(max(0, min(v, 1)), animated: false)
        }
    }
    static var current: Float { AVAudioSession.sharedInstance().outputVolume }
}

struct VolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        v.alpha = 0.01
        SystemVolume.host = v
        return v
    }
    func updateUIView(_ v: MPVolumeView, context: Context) {}
}

final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var model: PlayerModel?
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.model?.onPiPStart?() }
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.model?.restoring = true
            if let id = self.model?.currentLessonID { self.model?.restoreLessonID = id }
        }
        completionHandler(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            guard let m = self.model else { return }
            let wasRestore = m.restoring
            m.restoring = false
            if !wasRestore && !m.viewVisible { m.stop() }
        }
    }
}

final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()
    let player = AVPlayer()
    @Published var restoreLessonID: UUID?
    var currentLessonID: UUID?
    var viewVisible = false
    var restoring = false
    var onPiPStart: (() -> Void)?
    let pipDelegate = PiPDelegate()
    lazy var hostView: PlayerUIView = {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let c = AVPictureInPictureController(playerLayer: v.playerLayer)
            c?.canStartPictureInPictureAutomaticallyFromInline = true
            pipDelegate.model = self
            c?.delegate = pipDelegate
            pip = c
        }
        return v
    }()
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var fill = false
    @Published var videoSize: CGSize = .zero
    @Published var buffered: Double = 0
    @Published var holdBoost = false
    @Published var cues: [Cue] = []
    @Published var subtitlesOn = false
    @Published var subtitleText = ""
    @Published var legibleOptions: [AVMediaSelectionOption] = []
    @Published var audioOptions: [AVMediaSelectionOption] = []
    @Published var selectedLegible: AVMediaSelectionOption?
    @Published var selectedAudio: AVMediaSelectionOption?

    var videoAspect: CGFloat { videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : 0 }

    var rate: Float = 1
    var onProgress: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onWatch: ((Double) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var pip: AVPictureInPictureController?
    var nowTitle = ""
    var nowSub = ""

    private var legibleGroup: AVMediaSelectionGroup?
    private var audioGroup: AVMediaSelectionGroup?
    private var pendingWatch: Double = 0
    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcObs: NSKeyValueObservation?
    private var sizeObs: NSKeyValueObservation?
    private var bufObs: NSKeyValueObservation?
    private var lastSave: Double = -10
    private var lastNow: Double = -10
    private var remoteSet = false

    init() {
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self else { return }
            let s = t.seconds
            if s.isFinite { self.current = s }
            self.updateSubtitle(s)
            if abs(s - self.lastSave) >= 3 { self.lastSave = s; self.flush() }
            if abs(s - self.lastNow) >= 5 { self.lastNow = s; self.updateNowPlaying() }
            if self.isPlaying {
                self.pendingWatch += 0.25
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

    // MARK: loading
    func load(url: URL, startAt: Double) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        current = startAt
        duration = 0
        lastSave = startAt
        legibleOptions = []; audioOptions = []
        videoSize = .zero; buffered = 0
        selectedLegible = nil; selectedAudio = nil
        legibleGroup = nil; audioGroup = nil
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.onProgress?(self.duration, self.duration)
            self.onEnd?()
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .readyToPlay {
                let d = it.duration.seconds
                DispatchQueue.main.async {
                    self?.duration = d.isFinite ? d : 0
                    self?.updateNowPlaying()
                }
                self?.loadGroups(it)
            }
        }
        sizeObs = item.observe(\.presentationSize, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async { self?.videoSize = it.presentationSize }
        }
        bufObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] it, _ in
            let now = it.currentTime().seconds
            let ranges = it.loadedTimeRanges.map { $0.timeRangeValue }
            let end = ranges.first(where: { $0.start.seconds <= now + 0.5 && now <= $0.end.seconds + 0.5 })?.end.seconds
                ?? ranges.last?.end.seconds ?? 0
            DispatchQueue.main.async { self?.buffered = end.isFinite ? end : 0 }
        }
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        player.rate = rate
        updateNowPlaying()
    }

    private func loadGroups(_ item: AVPlayerItem) {
        Task { [weak self] in
            let asset = item.asset
            let leg = try? await asset.loadMediaSelectionGroup(for: .legible)
            let aud = try? await asset.loadMediaSelectionGroup(for: .audible)
            await MainActor.run {
                guard let self = self else { return }
                self.legibleGroup = leg
                self.audioGroup = aud
                self.legibleOptions = leg?.options ?? []
                self.audioOptions = aud?.options ?? []
                if let g = leg { item.select(nil, in: g) }
                if let g = aud { self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: g) }
            }
        }
    }

    // MARK: subtitles
    func setCues(_ c: [Cue]) {
        cues = c
        subtitlesOn = !c.isEmpty
        if c.isEmpty { subtitleText = "" }
    }
    private func updateSubtitle(_ t: Double) {
        guard subtitlesOn, !cues.isEmpty else {
            if !subtitleText.isEmpty { subtitleText = "" }
            return
        }
        let text = cues.first(where: { t >= $0.start && t <= $0.end })?.text ?? ""
        if text != subtitleText { subtitleText = text }
    }
    func disableSubtitles() {
        subtitlesOn = false
        subtitleText = ""
        selectLegible(nil, keepFile: false)
    }
    func useFileSubtitles() {
        selectLegible(nil, keepFile: true)
        subtitlesOn = !cues.isEmpty
    }
    func selectLegible(_ o: AVMediaSelectionOption?, keepFile: Bool = false) {
        if let g = legibleGroup, let item = player.currentItem { item.select(o, in: g) }
        selectedLegible = o
        if o != nil { subtitlesOn = false; subtitleText = "" }
        if o == nil && !keepFile { subtitlesOn = false }
    }
    func selectAudio(_ o: AVMediaSelectionOption) {
        if let g = audioGroup, let item = player.currentItem { item.select(o, in: g) }
        selectedAudio = o
    }

    // MARK: control
    func flush() {
        let pos = player.currentTime().seconds
        if pos.isFinite, duration > 0 { onProgress?(pos, duration) }
    }
    func togglePlay() {
        if player.timeControlStatus == .paused { player.play(); player.rate = holdBoost ? 2 : rate }
        else { player.pause() }
    }
    func seek(to s: Double) {
        let t = max(0, min(s, duration > 0 ? duration : s))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
        updateNowPlaying()
    }
    func skip(_ d: Double) { seek(to: player.currentTime().seconds + d) }
    func setRate(_ r: Float) {
        rate = r
        if player.timeControlStatus != .paused && !holdBoost { player.rate = r }
    }
    func setHold(_ on: Bool) {
        guard on != holdBoost else { return }
        holdBoost = on
        if player.timeControlStatus != .paused { player.rate = on ? 2 : rate }
    }
    func stop() {
        flush()
        if pendingWatch > 1 { onWatch?(pendingWatch) }
        pendingWatch = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentLessonID = nil
        teardownRemote()
    }

    // MARK: lock screen / remote
    func setupRemote() {
        guard !remoteSet else { return }
        remoteSet = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.player.play(); self.player.rate = self.rate; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(10); return .success }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-10); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.onPrev?(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let ev = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: ev.positionTime) }
            return .success
        }
    }
    func teardownRemote() {
        guard remoteSet else { return }
        remoteSet = false
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipForwardCommand, c.skipBackwardCommand,
         c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func updateNowPlaying() {
        guard remoteSet else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowTitle,
            MPMediaItemPropertyArtist: nowSub,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let model: PlayerModel
    let fill: Bool
    func makeUIView(context: Context) -> PlayerUIView {
        let v = model.hostView
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

func setOrientation(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
}
