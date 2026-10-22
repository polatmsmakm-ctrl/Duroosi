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
    var lastWatched: Date? = nil
    var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }
    var isDone: Bool { progress > 0.95 }
}

struct SubjectPrefs: Codable, Hashable {
    var rate: Double?
    var fill: Bool?
}

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var lessonID: UUID
    var time: Double
    var note: String
}

struct QuizQuestion: Identifiable, Codable, Hashable {
    var id = UUID()
    var unitID: UUID
    var text: String
    var options: [String]
    var correct: Int
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
        [Color(red: 0.95, green: 0.62, blue: 0.24), Color(red: 0.70, green: 0.34, blue: 0.12)],
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
    @Published var bookmarks: [Bookmark] = []
    @Published var questions: [QuizQuestion] = []
    @Published var lessonNotes: [String: String] = [:]
    @Published var studyLog: [String: Double] = [:]
    @Published var subjectPrefs: [String: SubjectPrefs] = [:]
    @Published var importStatus: String?
    @Published var logLines: [String] = []
    private var logObs: NSObjectProtocol?
    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logLines.append(f.string(from: Date()) + "  " + s)
        if logLines.count > 120 { logLines.removeFirst(logLines.count - 120) }
    }
    var lastImportError: String?

    private struct Library: Codable {
        var subjects: [Subject]
        var units: [CourseUnit]
        var lessons: [Lesson]
        var files: [FileAttachment]
        var lastLessonID: UUID?
        var bookmarks: [Bookmark]?
        var questions: [QuizQuestion]?
        var lessonNotes: [String: String]?
        var studyLog: [String: Double]?
        var subjectPrefs: [String: SubjectPrefs]?
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
        logObs = NotificationCenter.default.addObserver(forName: Notification.Name("duroosi.log"), object: nil, queue: .main) { [weak self] n in
            let s = (n.object as? String) ?? ""
            Task { @MainActor in self?.log(s) }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: libURL),
           let lib = try? JSONDecoder().decode(Library.self, from: data) {
            subjects = lib.subjects; units = lib.units; lessons = lib.lessons
            files = lib.files; lastLessonID = lib.lastLessonID
            bookmarks = lib.bookmarks ?? []; questions = lib.questions ?? []
            lessonNotes = lib.lessonNotes ?? [:]; studyLog = lib.studyLog ?? [:]
            subjectPrefs = lib.subjectPrefs ?? [:]
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
        let lib = Library(subjects: subjects, units: units, lessons: lessons, files: files, lastLessonID: lastLessonID,
                      bookmarks: bookmarks, questions: questions, lessonNotes: lessonNotes, studyLog: studyLog, subjectPrefs: subjectPrefs)
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
        let lids = Set(lessons.filter { $0.subjectID == s.id }.map { $0.id })
        let uids = Set(units.filter { $0.subjectID == s.id }.map { $0.id })
        bookmarks.removeAll { lids.contains($0.lessonID) }
        lids.forEach { lessonNotes[$0.uuidString] = nil }
        questions.removeAll { uids.contains($0.unitID) }
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
        bookmarks.removeAll { ids.contains($0.lessonID) }
        ids.forEach { lessonNotes[$0.uuidString] = nil }
        questions.removeAll { $0.unitID == u.id }
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
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let dest = mediaDir.appendingPathComponent(name)

        let tmpPath = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        if source.resolvingSymlinksInPath().path.hasPrefix(tmpPath),
           (try? FileManager.default.moveItem(at: source, to: dest)) != nil {
            return name
        }

        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
        }
        if coordError != nil || copyError != nil {
            // fallback: read bytes directly
            do {
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                try data.write(to: dest, options: .atomic)
            } catch {
                throw copyError ?? coordError ?? error
            }
        }
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        if source.resolvingSymlinksInPath().path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: source)
        }
        return name
    }

    nonisolated static let videoExts: Set<String> = ["mp4", "mov", "m4v", "3gp", "mpg", "mpeg"]

    nonisolated static func scanFolder(_ folder: URL) -> [(String, [URL])] {
        let fm = FileManager.default
        func natural(_ a: URL, _ b: URL) -> Bool {
            a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        func videos(in dir: URL) -> [URL] {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
            var out: [URL] = []
            for case let u as URL in en where videoExts.contains(u.pathExtension.lowercased()) { out.append(u) }
            return out.sorted(by: natural)
        }
        let items = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var result: [(String, [URL])] = []
        let rootVids = items.filter { videoExts.contains($0.pathExtension.lowercased()) }
        if !rootVids.isEmpty { result.append((folder.lastPathComponent, rootVids)) }
        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let v = videos(in: u)
                if !v.isEmpty { result.append((u.lastPathComponent, v)) }
            }
        }
        return result
    }

    /// unitID != nil: كل الفيديوهات تنحط في هذا الفصل. nil: كل مجلد فرعي يصير فصل باسمه.
    func importFolder(_ folder: URL, subjectID: UUID, unitID: UUID?) async -> Int {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        log("استيراد مجلد: \(folder.lastPathComponent) — صلاحية=\(scoped)")
        let groups = await Task.detached { Store.scanFolder(folder) }.value
        let total = groups.reduce(0) { $0 + $1.1.count }
        log("لقيت \(groups.count) مجموعة و\(total) فيديو")
        guard total > 0 else { lastImportError = "ما لقيت فيديوهات داخل المجلد"; return 0 }
        defer { importStatus = nil }
        var done = 0
        var count = 0
        var flat: [(String, [URL])] = groups
        if unitID != nil { flat = [("", groups.flatMap { $0.1 })] }
        for (name, urls) in flat {
            let uid: UUID
            if let u = unitID { uid = u }
            else if let ex = units.first(where: { $0.subjectID == subjectID && $0.title == name }) { uid = ex.id }
            else { uid = addUnit(subjectID: subjectID, title: name).id }
            for url in urls {
                done += 1
                importStatus = "جاري استيراد \(done) من \(total)…"
                var title = url.deletingPathExtension().lastPathComponent
                if Store.looksGenerated(title) { title = "درس \(lessons.filter { $0.unitID == uid }.count + 1)" }
                let result = await Task.detached { () -> Result<String, Error> in
                    Result { try Store.copyIn(url) }
                }.value
                switch result {
                case .failure(let e): lastImportError = describe(e); log("فشل \(url.lastPathComponent): \(describe(e))")
                case .success(let fileName):
                    lessons.append(Lesson(unitID: uid, subjectID: subjectID, title: title, fileName: fileName))
                    count += 1
                }
            }
            save()
        }
        log("انتهى استيراد المجلد: \(count) من \(total)")
        return count
    }

    nonisolated static func looksGenerated(_ t: String) -> Bool {
        let h = t.replacingOccurrences(of: "-", with: "")
        if h.count >= 28, h.allSatisfy({ $0.isHexDigit }) { return true }
        return t.hasPrefix("IMG_") && false
    }

    func fixTitles() {
        var changed = false
        for u in units {
            var n = 0
            for i in lessons.indices where lessons[i].unitID == u.id {
                n += 1
                if Store.looksGenerated(lessons[i].title) { lessons[i].title = "درس \(n)"; changed = true }
            }
        }
        if changed { save() }
    }

    private func describe(_ e: Error) -> String {
        let ns = e as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    @discardableResult
    func importLessons(_ urls: [URL], unitID: UUID) async -> Int {
        guard let u = unit(unitID) else { return 0 }
        var count = 0
        defer { importStatus = nil }
        for (idx, url) in urls.enumerated() {
            importStatus = "جاري استيراد \(idx + 1) من \(urls.count)…"
            var title = url.deletingPathExtension().lastPathComponent
            if Store.looksGenerated(title) { title = "درس \(lessons.filter { $0.unitID == unitID }.count + 1)" }
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try Store.copyIn(url) }
            }.value
            switch result {
            case .failure(let e): lastImportError = describe(e)
            case .success(let name):
                lessons.append(Lesson(unitID: unitID, subjectID: u.subjectID, title: title, fileName: name))
                count += 1
            }
        }
        save()
        return count
    }

    @discardableResult
    func importFiles(_ urls: [URL], subjectID: UUID, lessonID: UUID?) async -> Int {
        var count = 0
        for url in urls {
            let title = url.lastPathComponent
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try Store.copyIn(url) }
            }.value
            switch result {
            case .failure(let e): lastImportError = describe(e)
            case .success(let name):
                files.append(FileAttachment(subjectID: subjectID, lessonID: lessonID, title: title, fileName: name))
                count += 1
            }
        }
        save()
        return count
    }

    @discardableResult
    func importData(_ items: [(Data, String)], subjectID: UUID, lessonID: UUID?) -> Int {
        var n = 0
        for (d, ext) in items {
            let name = UUID().uuidString + "." + ext
            do {
                try d.write(to: url(for: name), options: .atomic)
                files.append(FileAttachment(subjectID: subjectID, lessonID: lessonID,
                                            title: "صورة \(files.count + 1)", fileName: name))
                n += 1
            } catch { lastImportError = describe(error) }
        }
        save()
        return n
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
        bookmarks.removeAll { $0.lessonID == l.id }
        lessonNotes[l.id.uuidString] = nil
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
        if abs(lessons[i].position - position) > 0.5 || lessons[i].lastWatched == nil { lessons[i].lastWatched = Date() }
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

    // MARK: bookmarks
    func bookmarks(of lid: UUID) -> [Bookmark] { bookmarks.filter { $0.lessonID == lid }.sorted { $0.time < $1.time } }
    func addBookmark(lessonID: UUID, time: Double, note: String) {
        bookmarks.append(Bookmark(lessonID: lessonID, time: time, note: note)); save()
    }
    func updateBookmark(_ b: Bookmark, note: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == b.id }) else { return }
        bookmarks[i].note = note; save()
    }
    func deleteBookmark(_ b: Bookmark) { bookmarks.removeAll { $0.id == b.id }; save() }

    // MARK: notes
    func note(for lid: UUID) -> String { lessonNotes[lid.uuidString] ?? "" }
    func setNote(_ text: String, for lid: UUID) {
        lessonNotes[lid.uuidString] = text.isEmpty ? nil : text; save()
    }

    // MARK: quiz
    func questions(of uid: UUID) -> [QuizQuestion] { questions.filter { $0.unitID == uid } }
    func saveQuestion(_ q: QuizQuestion) {
        if let i = questions.firstIndex(where: { $0.id == q.id }) { questions[i] = q } else { questions.append(q) }
        save()
    }
    func deleteQuestion(_ q: QuizQuestion) { questions.removeAll { $0.id == q.id }; save() }

    // MARK: study stats
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private func dayKey(_ d: Date) -> String { Store.dayFormatter.string(from: d) }
    func minutes(daysAgo n: Int) -> Int {
        guard let d = Calendar.current.date(byAdding: .day, value: -n, to: Date()) else { return 0 }
        return Int((studyLog[dayKey(d)] ?? 0) / 60)
    }
    func recentLessons(limit: Int) -> [Lesson] {
        Array(lessons.filter { $0.lastWatched != nil }.sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }.prefix(limit))
    }
    func prefs(for sid: UUID) -> SubjectPrefs { subjectPrefs[sid.uuidString] ?? SubjectPrefs() }
    func setRate(_ r: Double, subjectID sid: UUID) {
        var p = prefs(for: sid); p.rate = r; subjectPrefs[sid.uuidString] = p; save()
    }
    func setFill(_ f: Bool, subjectID sid: UUID) {
        var p = prefs(for: sid); p.fill = f; subjectPrefs[sid.uuidString] = p; save()
    }
    func addStudy(seconds: Double) {
        let k = dayKey(Date())
        studyLog[k, default: 0] += seconds
        save()
    }
    func todayMinutes() -> Int { Int((studyLog[dayKey(Date())] ?? 0) / 60) }
    func streak() -> Int {
        let cal = Calendar.current
        var d = Date()
        var n = 0
        if (studyLog[dayKey(d)] ?? 0) < 30, let y = cal.date(byAdding: .day, value: -1, to: d) { d = y }
        while (studyLog[dayKey(d)] ?? 0) >= 30 {
            n += 1
            guard let y = cal.date(byAdding: .day, value: -1, to: d) else { break }
            d = y
        }
        return n
    }
    func totalDone() -> (done: Int, total: Int) { (lessons.filter { $0.isDone }.count, lessons.count) }
}
