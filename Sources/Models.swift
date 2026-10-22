import SwiftUI
import UniformTypeIdentifiers

struct Subject: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
}

struct VideoItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var subjectID: UUID
    var title: String
    var fileName: String
    var position: Double = 0
    var duration: Double = 0
    var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }
    var isDone: Bool { progress > 0.95 }
}

struct AttachmentItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var subjectID: UUID
    var title: String
    var fileName: String
}

enum Palette {
    static let gradients: [[Color]] = [
        [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.55, green: 0.30, blue: 0.90)],
        [Color(red: 0.98, green: 0.45, blue: 0.40), Color(red: 0.95, green: 0.25, blue: 0.50)],
        [Color(red: 0.15, green: 0.75, blue: 0.60), Color(red: 0.10, green: 0.55, blue: 0.75)],
        [Color(red: 1.00, green: 0.70, blue: 0.20), Color(red: 0.95, green: 0.45, blue: 0.15)],
        [Color(red: 0.30, green: 0.80, blue: 0.95), Color(red: 0.25, green: 0.50, blue: 0.95)],
        [Color(red: 0.60, green: 0.85, blue: 0.35), Color(red: 0.20, green: 0.65, blue: 0.40)]
    ]
    static func gradient(_ i: Int) -> LinearGradient {
        let g = gradients[((i % gradients.count) + gradients.count) % gradients.count]
        return LinearGradient(colors: g, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var subjects: [Subject] = []
    @Published var videos: [VideoItem] = []
    @Published var files: [AttachmentItem] = []

    private struct Library: Codable {
        var subjects: [Subject]
        var videos: [VideoItem]
        var files: [AttachmentItem]
    }

    nonisolated static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    nonisolated static let mediaDir = docs.appendingPathComponent("Media", isDirectory: true)
    private let libURL = Store.docs.appendingPathComponent(".library.json")

    init() {
        try? FileManager.default.createDirectory(at: Store.mediaDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: persistence
    private func load() {
        guard let data = try? Data(contentsOf: libURL),
              let lib = try? JSONDecoder().decode(Library.self, from: data) else { return }
        subjects = lib.subjects
        videos = lib.videos
        files = lib.files
    }

    func save() {
        let lib = Library(subjects: subjects, videos: videos, files: files)
        if let data = try? JSONEncoder().encode(lib) {
            try? data.write(to: libURL, options: .atomic)
        }
    }

    func url(for fileName: String) -> URL {
        Store.mediaDir.appendingPathComponent(fileName)
    }

    // MARK: subjects
    func addSubject(name: String, colorIndex: Int) {
        subjects.append(Subject(name: name, colorIndex: colorIndex))
        save()
    }

    func updateSubject(_ s: Subject, name: String, colorIndex: Int) {
        guard let i = subjects.firstIndex(where: { $0.id == s.id }) else { return }
        subjects[i].name = name
        subjects[i].colorIndex = colorIndex
        save()
    }

    func deleteSubject(_ s: Subject) {
        for v in videos where v.subjectID == s.id { try? FileManager.default.removeItem(at: url(for: v.fileName)) }
        for f in files where f.subjectID == s.id { try? FileManager.default.removeItem(at: url(for: f.fileName)) }
        videos.removeAll { $0.subjectID == s.id }
        files.removeAll { $0.subjectID == s.id }
        subjects.removeAll { $0.id == s.id }
        save()
    }

    func moveSubjects(from: IndexSet, to: Int) {
        subjects.move(fromOffsets: from, toOffset: to)
        save()
    }

    func videoCount(_ s: Subject) -> Int { videos.filter { $0.subjectID == s.id }.count }
    func fileCount(_ s: Subject) -> Int { files.filter { $0.subjectID == s.id }.count }

    // MARK: importing
    nonisolated static func copyIn(_ source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let dest = mediaDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: dest)
        if source.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: source)
        }
        return name
    }

    func importVideos(_ urls: [URL], subjectID: UUID) async -> Int {
        var count = 0
        for url in urls {
            let title = url.deletingPathExtension().lastPathComponent
            let result = await Task.detached { try? Store.copyIn(url) }.value
            if let name = result {
                videos.append(VideoItem(subjectID: subjectID, title: title, fileName: name))
                count += 1
            }
        }
        save()
        return count
    }

    func importFiles(_ urls: [URL], subjectID: UUID) async -> Int {
        var count = 0
        for url in urls {
            let title = url.lastPathComponent
            let result = await Task.detached { try? Store.copyIn(url) }.value
            if let name = result {
                files.append(AttachmentItem(subjectID: subjectID, title: title, fileName: name))
                count += 1
            }
        }
        save()
        return count
    }

    // MARK: videos / files
    func renameVideo(_ v: VideoItem, to title: String) {
        guard let i = videos.firstIndex(where: { $0.id == v.id }) else { return }
        videos[i].title = title
        save()
    }

    func deleteVideo(_ v: VideoItem) {
        try? FileManager.default.removeItem(at: url(for: v.fileName))
        videos.removeAll { $0.id == v.id }
        save()
    }

    func updateProgress(_ id: UUID, position: Double, duration: Double) {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        videos[i].position = position
        if duration.isFinite && duration > 0 { videos[i].duration = duration }
        save()
    }

    func toggleDone(_ v: VideoItem) {
        guard let i = videos.firstIndex(where: { $0.id == v.id }) else { return }
        if videos[i].isDone {
            videos[i].position = 0
        } else if videos[i].duration > 0 {
            videos[i].position = videos[i].duration
        } else {
            videos[i].duration = 1
            videos[i].position = 1
        }
        save()
    }

    func renameFile(_ f: AttachmentItem, to title: String) {
        guard let i = files.firstIndex(where: { $0.id == f.id }) else { return }
        files[i].title = title
        save()
    }

    func deleteFile(_ f: AttachmentItem) {
        try? FileManager.default.removeItem(at: url(for: f.fileName))
        files.removeAll { $0.id == f.id }
        save()
    }
}
