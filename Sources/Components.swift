import SwiftUI
import AVFoundation
import QuickLook
import CoreTransferable
import UniformTypeIdentifiers

struct PlayTarget: Identifiable { let id: UUID }
struct IdentURL: Identifiable { let url: URL; var id: String { url.path } }

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

func formatTime(_ s: Double) -> String {
    let t = Int(s.isFinite ? max(s, 0) : 0)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

enum Thumbs {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(for url: URL) async -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let c = cache.object(forKey: key) { return c }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        let at = CMTime(seconds: min(max(dur * 0.1, 0), 5), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct LessonThumb: View {
    let url: URL
    @State private var img: UIImage?
    var body: some View {
        ZStack {
            Color.cardBg2
            if let img { Image(uiImage: img).resizable().scaledToFill() }
            else { Image(systemName: "play.fill").foregroundColor(.white.opacity(0.4)) }
        }
        .task(id: url.lastPathComponent) { img = await Thumbs.image(for: url) }
    }
}

func fileIcon(_ fileName: String) -> String {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "pdf": return "doc.richtext.fill"
    case "png", "jpg", "jpeg", "heic", "gif": return "photo.fill"
    case "doc", "docx", "pages", "txt", "rtf": return "doc.text.fill"
    case "ppt", "pptx", "key": return "rectangle.on.rectangle.fill"
    case "xls", "xlsx", "csv", "numbers": return "tablecells.fill"
    case "mp3", "m4a", "wav": return "waveform"
    case "zip", "rar": return "doc.zipper"
    default: return "doc.fill"
    }
}

struct FileRow: View {
    let file: FileAttachment
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileIcon(file.fileName))
                .font(.title3)
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Color.accentBlue, Color(red: 0.45, green: 0.3, blue: 0.95)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.title).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                if let subtitle { Text(subtitle).font(.caption).foregroundColor(.dim) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.left").font(.caption.bold()).foregroundColor(.dim)
        }
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

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
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct BusyOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("جاري الاستيراد…").font(.subheadline).foregroundColor(.white)
            }
            .padding(26)
            .background(Color.cardBg2, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
