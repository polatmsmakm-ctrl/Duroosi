import SwiftUI
import AVFoundation
import QuickLook
import AVKit
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


struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    var asCopy: Bool = true
    let onPick: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ f: @escaping ([URL]) -> Void) { onPick = f }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

extension View {
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], asCopy: Bool = true,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(types: types, asCopy: asCopy) { urls in
                isPresented.wrappedValue = false
                onPick(urls)
            }
            .ignoresSafeArea()
        }
    }
    func toast(_ text: Binding<String?>) -> some View { modifier(ToastModifier(text: text)) }
}

struct ToastModifier: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = text {
                Text(t)
                    .font(.subheadline.bold()).foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.cardBg2, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .padding(.bottom, 34)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_400_000_000)
                        withAnimation { text = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: text)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
