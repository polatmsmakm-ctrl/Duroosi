import SwiftUI
import UserNotifications

// MARK: - Reminders

@MainActor
enum Reminders {
    static func schedule(store: Store) {
        let d = UserDefaults.standard
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-review"])
        guard d.bool(forKey: "reminderOn") else { return }
        let hour = d.object(forKey: "reminderHour") as? Int ?? 18
        let minute = d.object(forKey: "reminderMinute") as? Int ?? 0
        let content = UNMutableNotificationContent()
        content.title = "دروسي 📚"
        if let l = store.globalContinue() {
            content.body = "حان وقت المراجعة — كمّل: \(l.title)"
        } else {
            content.body = "حان وقت المراجعة اليومية"
        }
        content.sound = .default
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: "daily-review", content: content, trigger: trigger))
    }

    static func enable(store: Store, completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
                if granted { schedule(store: store) }
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("المواد", systemImage: "books.vertical.fill") }
            SearchTab()
                .tabItem { Label("بحث", systemImage: "magnifyingglass") }
            ProgressTab()
                .tabItem { Label("تقدّمي", systemImage: "chart.bar.fill") }
            SettingsTab()
                .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
        .onAppear { Reminders.schedule(store: store) }
        .onChange(of: phase) { p in
            if p == .active { Reminders.schedule(store: store) }
        }
    }
}

// MARK: - Global search

struct SearchTab: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var playTarget: PlayTarget?
    @State private var preview: IdentURL?

    private var q: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var lessonHits: [Lesson] {
        guard !q.isEmpty else { return [] }
        return store.lessons.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var noteHits: [(Lesson, String)] {
        guard !q.isEmpty else { return [] }
        var out: [(Lesson, String)] = []
        for (key, text) in store.lessonNotes where text.localizedCaseInsensitiveContains(q) {
            if let id = UUID(uuidString: key), let l = store.lesson(id) { out.append((l, text)) }
        }
        return out
    }
    private var markHits: [(Lesson, Bookmark)] {
        guard !q.isEmpty else { return [] }
        return store.bookmarks.compactMap { b in
            guard b.note.localizedCaseInsensitiveContains(q), let l = store.lesson(b.lessonID) else { return nil }
            return (l, b)
        }
    }
    private var fileHits: [FileAttachment] {
        guard !q.isEmpty else { return [] }
        return store.files.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private func path(_ l: Lesson) -> String {
        let s = store.subject(l.subjectID)?.name ?? ""
        let u = store.unit(l.unitID)?.title ?? ""
        return s + " › " + u
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.footnote.bold()).foregroundColor(.dim).padding(.top, 6)
    }

    private func hitRow(_ l: Lesson, icon: String, line1: String, line2: String) -> some View {
        Button { playTarget = PlayTarget(id: l.id) } label: {
            HStack(spacing: 12) {
                LessonThumb(url: store.url(for: l.fileName))
                    .frame(width: 88, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(line1).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                    Text(line2).font(.caption).foregroundColor(.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: icon).font(.footnote).foregroundColor(.accentBlue)
            }
            .padding(10)
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if q.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").font(.system(size: 44)).foregroundColor(.white.opacity(0.3))
                                Text("ابحث في الدروس والملاحظات والعلامات والملفات").font(.subheadline).foregroundColor(.dim)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 90)
                        } else if lessonHits.isEmpty && noteHits.isEmpty && markHits.isEmpty && fileHits.isEmpty {
                            Text("ما لقيت نتائج").font(.subheadline).foregroundColor(.dim)
                                .frame(maxWidth: .infinity).padding(.top, 90)
                        }
                        if !lessonHits.isEmpty {
                            header("الدروس")
                            ForEach(lessonHits) { l in
                                hitRow(l, icon: "play.fill", line1: l.title, line2: path(l))
                            }
                        }
                        if !noteHits.isEmpty {
                            header("الملاحظات")
                            ForEach(Array(noteHits.enumerated()), id: \.offset) { _, pair in
                                hitRow(pair.0, icon: "note.text", line1: String(pair.1.prefix(90)), line2: pair.0.title)
                            }
                        }
                        if !markHits.isEmpty {
                            header("العلامات")
                            ForEach(Array(markHits.enumerated()), id: \.offset) { _, pair in
                                hitRow(pair.0, icon: "bookmark.fill",
                                       line1: pair.1.note, line2: pair.0.title + " · " + formatTime(pair.1.time))
                            }
                        }
                        if !fileHits.isEmpty {
                            header("الملفات")
                            ForEach(fileHits) { f in
                                FileRow(file: f).onTapGesture { preview = IdentURL(url: store.url(for: f.fileName)) }
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("بحث")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ابحث في كل شي")
            .fullScreenCover(item: $playTarget) { t in LessonPlayerView(lessonID: t.id) }
            .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
        }
    }
}

// MARK: - Progress

struct ProgressTab: View {
    @EnvironmentObject var store: Store
    @State private var playTarget: PlayTarget?

    private func weekday(_ daysAgo: Int) -> String {
        guard let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "E"
        return f.string(from: d)
    }

    private var weekChart: some View {
        let mins = (0..<7).reversed().map { store.minutes(daysAgo: $0) }
        let top = max(mins.max() ?? 0, 30)
        let total = mins.reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("آخر 7 أيام").font(.headline).foregroundColor(.white)
                Spacer()
                Text("\(total) دقيقة").font(.footnote.bold()).foregroundColor(.dim)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(mins.enumerated()), id: \.offset) { idx, m in
                    VStack(spacing: 6) {
                        Text(m > 0 ? "\(m)" : "").font(.caption2).foregroundColor(.dim).frame(height: 12)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(idx == 6 ? AnyShapeStyle(Color.accentBlue) : AnyShapeStyle(Color.white.opacity(0.35)))
                            .frame(height: max(5, CGFloat(m) / CGFloat(top) * 90))
                        Text(weekday(6 - idx)).font(.caption2).foregroundColor(.dim).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
        .padding(16)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func ago(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ar")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Text("تقدّمي").font(.system(size: 32, weight: .heavy)).foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.top, 8)

                        StatsCard()
                        weekChart

                        let recent = store.recentLessons(limit: 6)
                        if !recent.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("شاهدتها مؤخراً").font(.headline).foregroundColor(.white)
                                ForEach(recent) { l in
                                    Button { playTarget = PlayTarget(id: l.id) } label: {
                                        HStack(spacing: 12) {
                                            LessonThumb(url: store.url(for: l.fileName))
                                                .frame(width: 88, height: 50)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(l.title).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                                                Text(l.isDone ? "مكتمل" : "وصلت \(formatTime(l.position))")
                                                    .font(.caption).foregroundColor(l.isDone ? .doneGreen : .dim)
                                            }
                                            Spacer(minLength: 0)
                                            Text(ago(l.lastWatched)).font(.caption2).foregroundColor(.dim)
                                        }
                                        .padding(10)
                                        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !store.subjects.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("تقدّم المواد").font(.headline).foregroundColor(.white)
                                ForEach(store.subjects) { s in
                                    let p = store.progress(subject: s.id)
                                    HStack(spacing: 12) {
                                        SubjectOrb(subject: s, size: 40)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(s.name).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                                            GeometryReader { g in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(Color.white.opacity(0.12))
                                                    Capsule().fill(Palette.gradient(s.colorIndex)).frame(width: g.size.width * CGFloat(p))
                                                }
                                            }
                                            .frame(height: 6)
                                        }
                                        Text("\(Int(p * 100))%").font(.footnote.bold()).foregroundColor(.white)
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $playTarget) { t in LessonPlayerView(lessonID: t.id) }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var store: Store
    @AppStorage("reminderOn") private var reminderOn = false
    @AppStorage("reminderHour") private var hour = 18
    @AppStorage("reminderMinute") private var minute = 0
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("loopLesson") private var loopLesson = false
    @State private var denied = false
    @State private var backups: [BackupInfo] = []
    @State private var backupBusy = false
    @State private var restoreTarget: BackupInfo?
    @State private var deleteTarget: BackupInfo?
    @State private var showBackupImport = false
    @State private var backupMsg: String?

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = hour
                c.minute = minute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                hour = c.hour ?? 18
                minute = c.minute ?? 0
                Reminders.schedule(store: store)
            })
    }

    private var storageText: String {
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: Store.mediaDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in en {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                Form {
                    Section {
                        Toggle("تذكير يومي بالمراجعة", isOn: Binding(
                            get: { reminderOn },
                            set: { on in
                                if on {
                                    Reminders.enable(store: store) { ok in
                                        reminderOn = ok
                                        denied = !ok
                                    }
                                } else {
                                    reminderOn = false
                                    Reminders.schedule(store: store)
                                }
                            }))
                        if reminderOn {
                            DatePicker("وقت التذكير", selection: timeBinding, displayedComponents: .hourAndMinute)
                        }
                        if denied {
                            Text("الإشعارات مقفلة، فعّلها من إعدادات الآيفون ← دروسي ← الإشعارات")
                                .font(.footnote).foregroundColor(.orange)
                        }
                    } header: { Text("التذكير") } footer: {
                        Text("يوصلك إشعار كل يوم بالوقت اللي تحدده، ويذكّرك بالدرس اللي وقفت عنده.")
                    }
                    .listRowBackground(Color.cardBg)

                    Section("المشغّل") {
                        Toggle("تشغيل الدرس التالي تلقائياً", isOn: $autoNext)
                        Toggle("تكرار الدرس", isOn: $loopLesson)
                    }
                    .listRowBackground(Color.cardBg)

                    Section {
                        Button {
                            Task {
                                backupBusy = true
                                do { _ = try await store.makeBackup(); backupMsg = "تم إنشاء النسخة ✓" }
                                catch { backupMsg = "تعذّر: \(error.localizedDescription)" }
                                backups = store.listBackups()
                                backupBusy = false
                            }
                        } label: {
                            HStack {
                                Label("إنشاء نسخة احتياطية الآن", systemImage: "externaldrive.badge.plus")
                                Spacer()
                                if backupBusy { ProgressView() }
                            }
                        }
                        .disabled(backupBusy)
                        ForEach(backups) { b in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.bold())
                                    Text("\(b.subjects) مواد · \(b.lessons) فيديو" + (b.hasMedia ? "" : " · بدون ملفات"))
                                        .font(.caption).foregroundColor(.dim)
                                }
                                Spacer()
                                Menu {
                                    Button { restoreTarget = b } label: { Label("استعادة هذي النسخة", systemImage: "arrow.counterclockwise") }
                                    Button { exportItem(b.url) } label: { Label("تصدير (iCloud / ملفات)", systemImage: "square.and.arrow.up") }
                                    Button(role: .destructive) { deleteTarget = b } label: { Label("حذف النسخة", systemImage: "trash") }
                                } label: {
                                    Image(systemName: "ellipsis.circle").font(.title3)
                                }
                            }
                        }
                        Button { showBackupImport = true } label: {
                            Label("استيراد نسخة من مجلد", systemImage: "folder.badge.plus")
                        }
                        if let m = backupMsg { Text(m).font(.footnote).foregroundColor(.dim) }
                    } header: { Text("النسخ الاحتياطي") } footer: {
                        Text("النسخة تحفظ المواد والفصول والملاحظات والعلامات والتقدّم والفيديوهات والملفات. النسخ تنحفظ داخل التطبيق، وإذا حذفت التطبيق تنحذف معه، فاستخدم «تصدير» وخزّنها في iCloud أو الملفات.")
                    }
                    .listRowBackground(Color.cardBg)

                    Section {
                        if store.logLines.isEmpty {
                            Text("ما فيه أحداث بعد").font(.footnote).foregroundColor(.dim)
                        } else {
                            ForEach(Array(store.logLines.suffix(25).enumerated()), id: \.offset) { _, l in
                                Text(l).font(.caption2.monospaced()).foregroundColor(.dim)
                            }
                            Button("نسخ السجل") { UIPasteboard.general.string = store.logLines.joined(separator: "\n") }
                        }
                    } header: { Text("سجل الاستيراد (للتشخيص)") }
                    .listRowBackground(Color.cardBg)

                    Section("المكتبة") {
                        LabeledContent("المواد", value: "\(store.subjects.count)")
                        LabeledContent("الفصول", value: "\(store.units.count)")
                        LabeledContent("الفيديوهات", value: "\(store.lessons.count)")
                        LabeledContent("الملفات المرفقة", value: "\(store.files.count)")
                        LabeledContent("المساحة المستخدمة", value: storageText)
                    }
                    .listRowBackground(Color.cardBg)
                }
                .scrollContentBackground(.hidden)
            }
            .onAppear { backups = store.listBackups() }
            .documentPicker(isPresented: $showBackupImport, types: [.folder], asCopy: false) { urls in
                Task {
                    backupBusy = true
                    for u in urls {
                        do { try await store.importBackupFolder(u); backupMsg = "تم استيراد النسخة ✓" }
                        catch { backupMsg = "تعذّر: \(error.localizedDescription)" }
                    }
                    backups = store.listBackups()
                    backupBusy = false
                }
            }
            .alert("استعادة النسخة؟", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
                Button("استعادة", role: .destructive) {
                    if let b = restoreTarget {
                        Task {
                            backupBusy = true
                            do { try await store.restoreBackup(b); backupMsg = "تمت الاستعادة ✓" }
                            catch { backupMsg = "تعذّر: \(error.localizedDescription)" }
                            backups = store.listBackups()
                            backupBusy = false
                        }
                    }
                    restoreTarget = nil
                }
                Button("إلغاء", role: .cancel) { restoreTarget = nil }
            } message: { Text("راح تستبدل بيانات التطبيق الحالية بالنسخة. قبل الاستعادة ينعمل نسخة تلقائية من وضعك الحالي.") }
            .alert("حذف النسخة؟", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("حذف", role: .destructive) {
                    if let b = deleteTarget { store.deleteBackup(b); backups = store.listBackups() }
                    deleteTarget = nil
                }
                Button("إلغاء", role: .cancel) { deleteTarget = nil }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
