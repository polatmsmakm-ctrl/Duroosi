import SwiftUI
import AVKit
import QuickLook

struct PlayerScreen: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let video: VideoItem

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayerView(
                url: store.url(for: video.fileName),
                startAt: video.isDone ? 0 : video.position
            ) { pos, dur in
                store.updateProgress(video.id, position: pos, duration: dur)
            }
            .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(14)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    let startAt: Double
    let onProgress: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProgress) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(url: url)
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false
        context.coordinator.attach(player, startAt: startAt)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.finish()
    }

    final class Coordinator {
        let onProgress: (Double, Double) -> Void
        private var player: AVPlayer?
        private var token: Any?

        init(_ onProgress: @escaping (Double, Double) -> Void) { self.onProgress = onProgress }

        func attach(_ player: AVPlayer, startAt: Double) {
            self.player = player
            if startAt > 1 {
                player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            token = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 3, preferredTimescale: 600), queue: .main
            ) { [weak self] _ in self?.report() }
            player.play()
        }

        private func report() {
            guard let p = player, let item = p.currentItem else { return }
            let dur = item.duration.seconds
            let pos = p.currentTime().seconds
            if pos.isFinite { onProgress(pos, dur) }
        }

        func finish() {
            report()
            if let t = token { player?.removeTimeObserver(t); token = nil }
            player?.pause()
            player = nil
        }
    }
}

struct IdentifiableURLItem: Identifiable { let url: URL; var id: String { url.path } }

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
