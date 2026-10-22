import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import AVFoundation

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

private enum ImportMode { case videos, files }
private enum Tab: String, CaseIterable { case videos = "الفيديوهات", files = "الملفات" }

struct SubjectDetailView: View {
    @EnvironmentObject var store: Store
    let subjectID: UUID

    @State private var tab: Tab = .videos
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importMode: ImportMode = .files
    @State private var showImporter = false
    @State private var busy = false
    @State private var playing: VideoItem?
    @State private var previewURL: URL?
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""

    enum RenameTarget: Identifiable {
        case video(VideoItem), file(AttachmentItem)
        var id: UUID {
            switch self { case .video(let v): return v.id; case .file(let f): return f.id }
        }
    }

    private var subject: Subject? { store.subjects.first { $0.id == subjectID } }
    private var videos: [VideoItem] { store.videos.filter { $0.subjectID == subjectID } }
    private var files: [AttachmentItem] { store.files.filter { $0.subjectID == subjectID } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 10)

            List {
                if tab == .videos {
                    if videos.isEmpty { emptyRow("ما فيه فيديوهات", "اضغط + وأضف فيديو من الاستوديو أو من الملفات") }
                    ForEach(videos) { v in
                        VideoRow(video: v, url: store.url(for: v.fileName))
                            .contentShape(Rectangle())
                            .onTapGesture { playing = v }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.deleteVideo(v) } label: { Label("حذف", systemImage: "trash") }
                                Button { startRename(.video(v), v.title) } label: { Label("اسم", systemImage: "pencil") }.tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
                                Button { store.toggleDone(v) } label: {
                                    Label(v.isDone ? "غير مكتمل" : "تمت المشاهدة", systemImage: "checkmark.circle")
                                }.tint(.green)
                            }
                    }
                } else {
                    if files.isEmpty { emptyRow("ما فيه ملفات", "اضغط + وأرفق ملفات PDF أو صور أو أي ملف") }
                    ForEach(files) { f in
                        FileRow(file: f)
                            .contentShape(Rectangle())
                            .onTapGesture { previewURL = store.url(for: f.fileName) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.deleteFile(f) } label: { Label("حذف", systemImage: "trash") }
                                Button { startRename(.file(f), f.title) } label: { Label("اسم", systemImage: "pencil") }.tint(.orange)
                            }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(subject?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button { showPhotos = true } label: { Label("فيديو من الاستوديو", systemImage: "photo.on.rectangle") }
                    Button { importMode = .videos; showImporter = true } label: { Label("فيديو من الملفات", systemImage: "folder") }
                    Divider()
                    Button { importMode = .files; showImporter = true } label: { Label("إرفاق ملف", systemImage: "paperclip") }
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .videos)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            tab = .videos
            Task { await importPhotos(items) }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importMode == .videos ? [.movie, .video, .mpeg4Movie, .quickTimeMovie] : [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let mode = importMode
            Task {
                busy = true
                if mode == .videos { _ = await store.importVideos(urls, subjectID: subjectID); tab = .videos }
                else { _ = await store.importFiles(urls, subjectID: subjectID); tab = .files }
                busy = false
            }
        }
        .fullScreenCover(item: $playing) { v in
            PlayerScreen(video: v)
        }
        .sheet(item: Binding(get: { previewURL.map { IdentURL(url: $0) } }, set: { previewURL = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .alert("تغيير الاسم", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, let target = renameTarget {
                    switch target {
                    case .video(let v): store.renameVideo(v, to: t)
                    case .file(let f): store.renameFile(f, to: t)
                    }
                }
                renameTarget = nil
            }
            Button("إلغاء", role: .cancel) { renameTarget = nil }
        }
        .overlay {
            if busy {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("جاري الاستيراد…").font(.subheadline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func startRename(_ t: RenameTarget, _ current: String) {
        renameText = current
        renameTarget = t
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        busy = true
        var urls: [URL] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: MovieFile.self) {
                urls.append(movie.url)
            }
        }
        _ = await store.importVideos(urls, subjectID: subjectID)
        photoItems = []
        busy = false
    }

    private func emptyRow(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(sub).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowSeparator(.hidden)
    }
}

struct IdentURL: Identifiable { let url: URL; var id: String { url.path } }

struct VideoRow: View {
    let video: VideoItem
    let url: URL
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.25)
                }
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            .frame(width: 112, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) {
                if video.progress > 0 {
                    GeometryReader { g in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: g.size.width * video.progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if video.isDone {
                    Label("تمت المشاهدة", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if video.position > 1 {
                    Text("تابع من \(formatTime(video.position))").font(.caption).foregroundStyle(.secondary)
                } else if video.duration > 0 {
                    Text(formatTime(video.duration)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .task(id: video.fileName) { thumb = await Thumbs.image(for: url) }
    }
}

struct FileRow: View {
    let file: AttachmentItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(file.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
    private var icon: String {
        switch (file.fileName as NSString).pathExtension.lowercased() {
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
}

func formatTime(_ s: Double) -> String {
    let t = Int(s.isFinite ? s : 0)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

enum Thumbs {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(for url: URL) async -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let c = cache.object(forKey: key) { return c }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        let dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        let at = CMTime(seconds: min(max(dur * 0.1, 0), 5), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }
}
