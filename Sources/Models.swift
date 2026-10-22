import SwiftUI

struct Subject: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var icon: String
}

struct CourseUnit: Identifiable, Codable, Hashable {
    var id = UUID()
    var subjectID: UUID
    var title: String
}

struct Lesson: Identifiable, Codable, Hashable {
    var id = UUID()
    var unitID: UUID
    var subjectID: UUID
    var title: String
    var fileName: String
    var position: Double = 0
    var duration: Double = 0
    var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }
    var isDone: Bool { progress > 0.95 }
}

struct FileAttachment: Identifiable, Codable, Hashable {
    var id = UUID()
    var subjectID: UUID
    var lessonID: UUID?
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
    static func colors(_ i: Int) -> [Color] { gradients[((i % gradients.count) + gradients.count) % gradients.count] }
    static func gradient(_ i: Int) -> LinearGradient {
        LinearGradient(colors: colors(i), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func glow(_ i: Int) -> Color { colors(i)[0] }
}

let subjectIcons = [
    "function", "atom", "book.fill", "globe.europe.africa.fill", "flask.fill", "character.book.closed.fill",
    "pencil.and.ruler.fill", "brain.head.profile", "chart.bar.fill", "laptopcomputer", "music.note",
    "paintpalette.fill", "leaf.fill", "heart.text.square.fill", "scroll.fill", "building.columns.fill",
    "sum", "network", "cross.case.fill", "dumbbell.fill"
]

@MainActor
final class Store: ObservableObject {
    @Published var subjects: [Subject] = []
    @Published var units: [CourseUnit] = []
    @Published var lessons: [Lesson] = []
    @Published var files: [FileAttachment] = []
    @Published var lastLessonID: UUID?

    private struct Library: Codable {
        var subjects: [Subject]
        var units: [CourseUnit]
        var lessons: [Lesson]
        var files: [FileAttachment]
        var lastLessonID: UUID?
    }

    // old v1 format (migration)
    private struct OldSubject: Codable { var id: UUID; var name: String; var colorIndex: Int }
    private struct OldVideo: Codable { var id: UUID; var subjectID: UUID; var title: String; var fileName: String; var position: Double; var duration: Double }
    private struct OldFile: Codable { var id: UUID; var subjectID: UUID; var title: String; var fileName: String }
    private struct OldLibrary: Codable { var subjects: [OldSubject]; var videos: [OldVideo]; var files: [OldFile] }

    nonisolated static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    nonisolated static let mediaDir = docs.appendingPathComponent("Media", isDirectory: true)
    private let libURL = Store.docs.appendingPathComponent(".library2.json")
    private let oldURL = Store.docs.appendingPathComponent(".library.json")

    init() {
        try? FileManager.default.createDirectory(at: Store.mediaDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: libURL),
           let lib = try? JSONDecoder().decode(Library.self, from: data) {
            subjects = lib.subjects; units = lib.units; lessons = lib.lessons
            files = lib.files; lastLessonID = lib.lastLessonID
            return
        }
        if let data = try? Data(contentsOf: oldURL),
           let old = try? JSONDecoder().decode(OldLibrary.self, from: data) {
            for (i, s) in old.subjects.enumerated() {
                subjects.append(Subject(id: s.id, name: s.name, colorIndex: s.colorIndex, icon: subjectIcons[i % subjectIcons.count]))
                let vids = old.videos.filter { $0.subjectID == s.id }
                if !vids.isEmpty {
                    let u = CourseUnit(subjectID: s.id, title: "الدروس")
                    units.append(u)
                    for v in vids {
                        lessons.append(Lesson(id: v.id, unitID: u.id, subjectID: s.id, title: v.title,
                                              fileName: v.fileName, position: v.position, duration: v.duration))
                    }
                }
                for f in old.files where f.subjectID == s.id {
                    files.append(FileAttachment(id: f.id, subjectID: s.id, lessonID: nil, title: f.title, fileName: f.fileName))
                }
            }
            save()
        }
    }

    func save() {
        let lib = Library(subjects: subjects, units: units, lessons: lessons, files: files, lastLessonID: lastLessonID)
        if let data = try? JSONEncoder().encode(lib) { try? data.write(to: libURL, options: .atomic) }
    }

    func url(for fileName: String) -> URL { Store.mediaDir.appendingPathComponent(fileName) }
    private func remove(_ fileName: String) { try? FileManager.default.removeItem(at: url(for: fileName)) }

    // MARK: queries
    func subject(_ id: UUID) -> Subject? { subjects.first { $0.id == id } }
    func units(of sid: UUID) -> [CourseUnit] { units.filter { $0.subjectID == sid } }
    func lessons(in uid: UUID) -> [Lesson] { lessons.filter { $0.unitID == uid } }
    func orderedLessons(_ sid: UUID) -> [Lesson] { units(of: sid).flatMap { lessons(in: $0.id) } }
    func lesson(_ id: UUID) -> Lesson? { lessons.first { $0.id == id } }
    func unit(_ id: UUID) -> CourseUnit? { units.first { $0.id == id } }
    func notes(of sid: UUID) -> [FileAttachment] { files.filter { $0.subjectID == sid && $0.lessonID == nil } }
    func attachments(of lid: UUID) -> [FileAttachment] { files.filter { $0.lessonID == lid } }
    func fileCount(_ sid: UUID) -> Int { files.filter { $0.subjectID == sid }.count }

    func progress(subject sid: UUID) -> Double {
        let ls = lessons.filter { $0.subjectID == sid }
        guard !ls.isEmpty else { return 0 }
        return ls.reduce(0) { $0 + $1.progress } / Double(ls.count)
    }
    func progress(unit uid: UUID) -> Double {
        let ls = lessons(in: uid)
        guard !ls.isEmpty else { return 0 }
        return ls.reduce(0) { $0 + $1.progress } / Double(ls.count)
    }

    func nextLesson(after id: UUID) -> Lesson? {
        guard let l = lesson(id) else { return nil }
        let all = orderedLessons(l.subjectID)
        guard let i = all.firstIndex(where: { $0.id == id }), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
    func previousLesson(before id: UUID) -> Lesson? {
        guard let l = lesson(id) else { return nil }
        let all = orderedLessons(l.subjectID)
        guard let i = all.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        return all[i - 1]
    }

    func continueLesson(_ sid: UUID) -> Lesson? {
        let all = orderedLessons(sid)
        if let last = lastLessonID, let l = lesson(last), l.subjectID == sid {
            if !l.isDone { return l }
            if let n = nextLesson(after: l.id) { return n }
            return l
        }
        return all.first { !$0.isDone } ?? all.first
    }
    func globalContinue() -> Lesson? {
        guard let last = lastLessonID, let l = lesson(last) else { return nil }
        return continueLesson(l.subjectID)
    }

    // MARK: subjects
    func addSubject(name: String, colorIndex: Int, icon: String) {
        subjects.append(Subject(name: name, colorIndex: colorIndex, icon: icon)); save()
    }
    func updateSubject(_ s: Subject, name: String, colorIndex: Int, icon: String) {
        guard let i = subjects.firstIndex(where: { $0.id == s.id }) else { return }
        subjects[i].name = name; subjects[i].colorIndex = colorIndex; subjects[i].icon = icon; save()
    }
    func deleteSubject(_ s: Subject) {
        lessons.filter { $0.subjectID == s.id }.forEach { remove($0.fileName) }
        files.filter { $0.subjectID == s.id }.forEach { remove($0.fileName) }
        lessons.removeAll { $0.subjectID == s.id }
        files.removeAll { $0.subjectID == s.id }
        units.removeAll { $0.subjectID == s.id }
        subjects.removeAll { $0.id == s.id }
        save()
    }

    // MARK: units
    @discardableResult
    func addUnit(subjectID: UUID, title: String) -> CourseUnit {
        let u = CourseUnit(subjectID: subjectID, title: title)
        units.append(u); save(); return u
    }
    func renameUnit(_ u: CourseUnit, to t: String) {
        guard let i = units.firstIndex(where: { $0.id == u.id }) else { return }
        units[i].title = t; save()
    }
    func deleteUnit(_ u: CourseUnit) {
        let ids = Set(lessons(in: u.id).map { $0.id })
        lessons(in: u.id).forEach { remove($0.fileName) }
        files.filter { $0.lessonID.map(ids.contains) ?? false }.forEach { remove($0.fileName) }
        files.removeAll { $0.lessonID.map(ids.contains) ?? false }
        lessons.removeAll { $0.unitID == u.id }
        units.removeAll { $0.id == u.id }
        save()
    }
    func moveUnit(_ u: CourseUnit, by d: Int) {
        let ids = units.indices.filter { units[$0].subjectID == u.subjectID }
        guard let pos = ids.firstIndex(where: { units[$0].id == u.id }) else { return }
        let np = pos + d
        guard np >= 0, np < ids.count else { return }
        units.swapAt(ids[pos], ids[np]); save()
    }

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

    func importLessons(_ urls: [URL], unitID: UUID) async {
        guard let u = unit(unitID) else { return }
        for url in urls {
            let title = url.deletingPathExtension().lastPathComponent
            let result = await Task.detached { try? Store.copyIn(url) }.value
            if let name = result {
                lessons.append(Lesson(unitID: unitID, subjectID: u.subjectID, title: title, fileName: name))
            }
        }
        save()
    }

    func importFiles(_ urls: [URL], subjectID: UUID, lessonID: UUID?) async {
        for url in urls {
            let title = url.lastPathComponent
            let result = await Task.detached { try? Store.copyIn(url) }.value
            if let name = result {
                files.append(FileAttachment(subjectID: subjectID, lessonID: lessonID, title: title, fileName: name))
            }
        }
        save()
    }

    // MARK: lessons / files
    func renameLesson(_ l: Lesson, to t: String) {
        guard let i = lessons.firstIndex(where: { $0.id == l.id }) else { return }
        lessons[i].title = t; save()
    }
    func deleteLesson(_ l: Lesson) {
        remove(l.fileName)
        attachments(of: l.id).forEach { remove($0.fileName) }
        files.removeAll { $0.lessonID == l.id }
        lessons.removeAll { $0.id == l.id }
        if lastLessonID == l.id { lastLessonID = nil }
        save()
    }
    func moveLesson(_ l: Lesson, by d: Int) {
        let ids = lessons.indices.filter { lessons[$0].unitID == l.unitID }
        guard let pos = ids.firstIndex(where: { lessons[$0].id == l.id }) else { return }
        let np = pos + d
        guard np >= 0, np < ids.count else { return }
        lessons.swapAt(ids[pos], ids[np]); save()
    }
    func updateProgress(_ id: UUID, position: Double, duration: Double) {
        guard let i = lessons.firstIndex(where: { $0.id == id }) else { return }
        lessons[i].position = position
        if duration.isFinite && duration > 0 { lessons[i].duration = duration }
        save()
    }
    func toggleDone(_ l: Lesson) {
        guard let i = lessons.firstIndex(where: { $0.id == l.id }) else { return }
        if lessons[i].isDone { lessons[i].position = 0 }
        else {
            if lessons[i].duration <= 0 { lessons[i].duration = 1 }
            lessons[i].position = lessons[i].duration
        }
        save()
    }
    func setLast(_ id: UUID) { lastLessonID = id; save() }

    func renameFile(_ f: FileAttachment, to t: String) {
        guard let i = files.firstIndex(where: { $0.id == f.id }) else { return }
        files[i].title = t; save()
    }
    func deleteFile(_ f: FileAttachment) {
        remove(f.fileName)
        files.removeAll { $0.id == f.id }; save()
    }
}
