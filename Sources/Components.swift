import SwiftUI
import AVFoundation
import QuickLook
import AVKit
import PhotosUI
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


struct DocPickerHost: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let types: [UTType]
    let asCopy: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if isPresented, !c.showing {
            c.showing = true
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
            picker.allowsMultipleSelection = true
            picker.delegate = c
            DispatchQueue.main.async {
                var top: UIViewController? = vc.view.window?.rootViewController
                    ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
                while let p = top?.presentedViewController { top = p }
                if let top { top.present(picker, animated: true) } else { c.showing = false; isPresented = false }
            }
        }
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocPickerHost?
        var showing = false
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            showing = false
            parent?.isPresented = false
            parent?.onPick(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            showing = false
            parent?.isPresented = false
        }
    }
}

extension View {
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], asCopy: Bool = true,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        background(DocPickerHost(isPresented: isPresented, types: types, asCopy: asCopy, onPick: onPick)
            .frame(width: 0, height: 0))
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


struct AttachSources: ViewModifier {
    @EnvironmentObject var store: Store
    @Binding var showFiles: Bool
    @Binding var showPhotos: Bool
    @Binding var busy: Bool
    let subjectID: UUID
    let lessonID: UUID?
    let onMessage: (String) -> Void
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var errorText: String?

    func body(content: Content) -> some View {
        content
            .documentPicker(isPresented: $showFiles, types: [.item]) { urls in
                Task {
                    busy = true
                    store.lastImportError = nil
                    let n = await store.importFiles(urls, subjectID: subjectID, lessonID: lessonID)
                    busy = false
                    finish(n)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    busy = true
                    store.lastImportError = nil
                    var datas: [(Data, String)] = []
                    for it in items {
                        if let d = try? await it.loadTransferable(type: Data.self) {
                            let ext = it.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            datas.append((d, ext))
                        }
                    }
                    photoItems = []
                    let n = store.importData(datas, subjectID: subjectID, lessonID: lessonID)
                    busy = false
                    finish(n)
                }
            }
            .alert("تعذّر الإرفاق", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("حسناً", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
    }

    private func finish(_ n: Int) {
        if n > 0 { onMessage("تم إرفاق \(n) ✓") }
        else { errorText = store.lastImportError ?? "ما وصلني أي ملف من نافذة الاختيار" }
    }
}

extension View {
    func attachSources(showFiles: Binding<Bool>, showPhotos: Binding<Bool>, busy: Binding<Bool>,
                       subjectID: UUID, lessonID: UUID?, onMessage: @escaping (String) -> Void) -> some View {
        modifier(AttachSources(showFiles: showFiles, showPhotos: showPhotos, busy: busy,
                               subjectID: subjectID, lessonID: lessonID, onMessage: onMessage))
    }
}
