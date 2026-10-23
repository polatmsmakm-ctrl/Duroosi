import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LessonDrag: Codable, Transferable {
    var id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private enum RenameKind { case newUnit(UUID), unit(CourseUnit), lesson(Lesson) }

struct SubjectView: View {
    @EnvironmentObject var store: Store
    let subjectID: UUID

    @State private var expanded: Set<UUID> = []
    @State private var playTarget: PlayTarget?
    @State private var showFiles = false
    @State private var showSearch = false
    @State private var busy = false
    @State private var scrollTarget: UUID?
    @State private var bulkUnit: PlayTarget?
    @State private var showFolderImporter = false
    @State private var showAttach = false
    @State private var attachLesson: Lesson?
    @State private var reorderUnit: PlayTarget?

    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var targetUnit: UUID?
    @State private var showVideoImporter = false
    @State private var quizRun: PlayTarget?
    @State private var quizEdit: PlayTarget?
    @State private var toastText: String?

    @State private var renameKind: RenameKind?
    @State private var renameText = ""
    @State private var unitToDelete: CourseUnit?
    @State private var lessonToDelete: Lesson?

    private var subject: Subject? { store.subject(subjectID) }

    var body: some View {
        ZStack {
            AppBackground()
            if let s = subject {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            header(s)
                            curriculum(s)
                        }
                    }
                    .onChange(of: scrollTarget) { id in
                        guard let id else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .top) }
                            scrollTarget = nil
                        }
                    }
                }
            }
            if busy { BusyOverlay(text: store.importStatus) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
            }
        }
        .fullScreenCover(item: $playTarget) { t in LessonPlayerView(lessonID: t.id) }
        .sheet(isPresented: $showFiles) { FilesView(subjectID: subjectID) }
        .sheet(isPresented: $showSearch) {
            SearchView(subjectID: subjectID) { id in playTarget = PlayTarget(id: id) }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 200, matching: .videos)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty, let uid = targetUnit else { return }
            Task { await importPhotos(items, unitID: uid) }
        }
        .documentPicker(isPresented: $showVideoImporter,
                        types: [.movie, .video, .mpeg4Movie, .quickTimeMovie], asCopy: true) { urls in
            guard let uid = targetUnit else { toastText = "اختر الفصل أول"; return }
            Task {
                busy = true
                let n = await store.importLessons(urls, unitID: uid)
                busy = false
                expanded.insert(uid)
                toastText = n > 0 ? "تمت إضافة \(n) درس ✓" : ("تعذّر: " + (store.lastImportError ?? "استيراد الفيديو"))
            }
        }
        .documentPicker(isPresented: $showAttach,
                        types: [.movie, .video, .mpeg4Movie, .quickTimeMovie], asCopy: true) { urls in
            guard let l = attachLesson, let u = urls.first else { return }
            Task {
                busy = true
                let ok = await store.attachVideo(u, to: l)
                busy = false
                toastText = ok ? "تم ربط الفيديو ✓" : "تعذّر ربط الفيديو"
            }
        }
        .documentPicker(isPresented: $showFolderImporter, types: [.folder], asCopy: false) { urls in
            let uid = targetUnit
            busy = true
            toastText = "وصل المجلد، جاري القراءة…"
            Task {
                var n = 0
                for u in urls { n += await store.importFolder(u, subjectID: subjectID, unitID: uid) }
                busy = false
                if let uid { expanded.insert(uid) } else { expanded = Set(store.units(of: subjectID).map { $0.id }) }
                toastText = n > 0 ? "تمت إضافة \(n) فيديو ✓" : ("تعذّر: " + (store.lastImportError ?? "استيراد المجلد"))
            }
        }
        .sheet(item: $reorderUnit) { t in ReorderView(unitID: t.id) }
        .sheet(item: $bulkUnit) { t in BulkRenameView(unitID: t.id) }
        .sheet(item: $quizRun) { t in QuizRunnerView(unitID: t.id) }
        .sheet(item: $quizEdit) { t in QuizEditorView(unitID: t.id) }
        .toast($toastText)
        .alert(renameTitle, isPresented: Binding(get: { renameKind != nil }, set: { if !$0 { renameKind = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { commitRename() }
            Button("إلغاء", role: .cancel) { renameKind = nil }
        }
        .alert("حذف الفصل؟", isPresented: Binding(get: { unitToDelete != nil }, set: { if !$0 { unitToDelete = nil } })) {
            Button("حذف", role: .destructive) { if let u = unitToDelete { store.deleteUnit(u) }; unitToDelete = nil }
            Button("إلغاء", role: .cancel) { unitToDelete = nil }
        } message: { Text("راح ينحذف الفصل مع كل فيديوهاته وملفاته.") }
        .alert("حذف الدرس؟", isPresented: Binding(get: { lessonToDelete != nil }, set: { if !$0 { lessonToDelete = nil } })) {
            Button("حذف", role: .destructive) { if let l = lessonToDelete { store.deleteLesson(l) }; lessonToDelete = nil }
            Button("إلغاء", role: .cancel) { lessonToDelete = nil }
        }
        .onAppear {
            if expanded.isEmpty, let f = store.units(of: subjectID).first { expanded.insert(f.id) }
        }
    }

    // MARK: header
    private func header(_ s: Subject) -> some View {
        let units = store.units(of: s.id)
        let lessonCount = store.lessons.filter { $0.subjectID == s.id }.count
        let pct = Int(store.progress(subject: s.id) * 100)
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                SubjectOrb(subject: s, size: 62)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name).font(.title2.bold()).foregroundColor(.white).lineLimit(1)
                    Text("\(units.count) فصل · \(lessonCount) درس · \(pct)% مكتمل")
                        .font(.footnote).foregroundColor(.dim)
                }
                Spacer(minLength: 0)
            }
            if let l = store.continueLesson(subjectID) {
                ContinuePill(title: l.title, subtitle: store.progress(subject: subjectID) > 0 ? "تابع من حيث وقفت" : "ابدأ الآن") {
                    playTarget = PlayTarget(id: l.id)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [Palette.glow(s.colorIndex).opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: curriculum
    private func curriculum(_ s: Subject) -> some View {
        let units = store.units(of: s.id)
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("الفصول").font(.title3.bold()).foregroundColor(.white)
                Spacer()
                if units.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if expanded.count == units.count { expanded.removeAll() }
                            else { expanded = Set(units.map { $0.id }) }
                        }
                    } label: {
                        Text(expanded.count == units.count ? "طي الكل" : "فتح الكل")
                            .font(.footnote.bold()).foregroundColor(.accentBlue)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.cardBg, in: Capsule())
                    }
                }
                Button {
                    targetUnit = nil
                    showFolderImporter = true
                } label: {
                    Label("مجلد", systemImage: "folder.badge.plus")
                        .font(.footnote.bold()).foregroundColor(.accentBlue)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.cardBg, in: Capsule())
                }
                Button {
                    renameText = ""
                    renameKind = .newUnit(s.id)
                } label: {
                    Label("فصل", systemImage: "plus")
                        .font(.footnote.bold()).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.accentBlue, in: Capsule())
                }
            }

            Button { showFiles = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.body).foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(Palette.gradient(s.colorIndex), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("المذكرات والملفات").font(.subheadline.bold()).foregroundColor(.white)
                        Text("\(store.fileCount(s.id)) ملف").font(.caption).foregroundColor(.dim)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.left").font(.caption.bold()).foregroundColor(.dim)
                }
                .padding(12)
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if units.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 44)).foregroundColor(.white.opacity(0.3))
                    Text("ما فيه فصول بعد").font(.headline).foregroundColor(.white)
                    Text("اضغط «+ فصل» وسمّه، وبعدها ضيف الفيديوهات تحته").font(.footnote).foregroundColor(.dim)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 40)
            }

            ForEach(Array(units.enumerated()), id: \.element.id) { idx, u in
                unitCard(u, number: idx + 1).id(u.id)
            }

            Button {
                renameText = ""
                renameKind = .newUnit(s.id)
            } label: {
                Label("إضافة فصل جديد", systemImage: "plus")
                    .font(.headline).foregroundColor(.accentBlue)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.accentBlue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 90)
        }
        .padding(.horizontal, 16)
    }

    private func unitCard(_ u: CourseUnit, number: Int) -> some View {
        let ls = store.lessons(in: u.id)
        let isOpen = expanded.contains(u.id)
        let p = store.progress(unit: u.id)
        let total = ls.reduce(0) { $0 + $1.duration }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        if isOpen { expanded.remove(u.id) } else { expanded.insert(u.id) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text("\(number)")
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(p >= 0.95 ? AnyShapeStyle(Color.doneGreen) : AnyShapeStyle(Color.accentBlue), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(u.title).font(.headline).foregroundColor(.white).multilineTextAlignment(.leading).lineLimit(2)
                            Text(ls.isEmpty ? "فارغ" : "\(ls.count) فيديو" + (total > 0 ? " · \(formatTime(total))" : "") + " · \(Int(p * 100))%")
                                .font(.caption).foregroundColor(.dim)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.footnote.bold()).foregroundColor(.dim)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button { targetUnit = u.id; showPhotos = true } label: { Label("إضافة فيديو من الاستوديو", systemImage: "photo.on.rectangle") }
                    Button { targetUnit = u.id; showVideoImporter = true } label: { Label("إضافة فيديو من الملفات", systemImage: "folder") }
                    Button { targetUnit = u.id; showFolderImporter = true } label: { Label("إضافة مجلد كامل", systemImage: "folder.badge.plus") }
                    Button { bulkUnit = PlayTarget(id: u.id) } label: { Label("تعديل عناوين الفيديوهات", systemImage: "text.badge.checkmark") }
                    Button { reorderUnit = PlayTarget(id: u.id) } label: { Label("ترتيب الفيديوهات", systemImage: "arrow.up.arrow.down") }
                    Divider()
                    Button { quizEdit = PlayTarget(id: u.id) } label: { Label("أسئلة اختبار الفصل", systemImage: "checklist") }
                    Button { renameText = u.title; renameKind = .unit(u) } label: { Label("تغيير اسم الفصل", systemImage: "pencil") }
                    Button { store.moveUnit(u, by: -1) } label: { Label("نقل للأعلى", systemImage: "arrow.up") }
                    Button { store.moveUnit(u, by: 1) } label: { Label("نقل للأسفل", systemImage: "arrow.down") }
                    Button(role: .destructive) { unitToDelete = u } label: { Label("حذف الفصل", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title2).foregroundColor(.accentBlue)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)

            if isOpen {
                VStack(spacing: 0) {
                    Divider().background(Color.white.opacity(0.1)).padding(.bottom, 6)
                    ForEach(Array(ls.enumerated()), id: \.element.id) { idx, l in
                        lessonRow(l, isFirst: idx == 0, isLast: idx == ls.count - 1)
                    }
                    Menu {
                        Button { targetUnit = u.id; showPhotos = true } label: { Label("من الاستوديو", systemImage: "photo.on.rectangle") }
                        Button { targetUnit = u.id; showVideoImporter = true } label: { Label("من الملفات", systemImage: "folder") }
                        Button { targetUnit = u.id; showFolderImporter = true } label: { Label("مجلد كامل", systemImage: "folder.badge.plus") }
                    } label: {
                        Label("إضافة فيديوهات لهذا الفصل", systemImage: "plus.circle.fill")
                            .font(.subheadline.bold()).foregroundColor(.accentBlue)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.accentBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.top, 8)
                    Divider().background(Color.white.opacity(0.1)).padding(.vertical, 6)
                    quizRow(u)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .clipped()
        .dropDestination(for: LessonDrag.self) { items, _ in
            guard let d = items.first else { return false }
            store.moveLesson(id: d.id, toUnit: u.id, before: nil)
            withAnimation { _ = expanded.insert(u.id) }
            haptic()
            return true
        }
    }

    private func quizRow(_ u: CourseUnit) -> some View {
        let n = store.questions(of: u.id).count
        return Button {
            if n == 0 { quizEdit = PlayTarget(id: u.id) } else { quizRun = PlayTarget(id: u.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.footnote.bold()).foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.doneGreen.opacity(0.85), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("اختبار مراجعة الفصل").font(.subheadline.weight(.medium)).foregroundColor(.white)
                    Text(n == 0 ? "اضغط لإضافة أسئلة" : "\(n) سؤال").font(.caption2).foregroundColor(.dim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.left").font(.caption.bold()).foregroundColor(.dim)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lessonRow(_ l: Lesson, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 2) {
            lessonButton(l, isFirst: isFirst, isLast: isLast)
            Menu {
                Button { renameText = l.title; renameKind = .lesson(l) } label: { Label("تعديل العنوان", systemImage: "pencil") }
                Button { attachLesson = l; showAttach = true } label: {
                    Label(store.hasVideo(l) ? "استبدال الفيديو" : "ربط فيديو", systemImage: "film")
                }
                Button { store.toggleDone(l) } label: {
                    Label(l.isDone ? "إلغاء الإكمال" : "تعليم كمكتمل", systemImage: "checkmark.circle")
                }
                Button { store.moveLesson(l, by: -1) } label: { Label("نقل للأعلى", systemImage: "arrow.up") }
                Button { store.moveLesson(l, by: 1) } label: { Label("نقل للأسفل", systemImage: "arrow.down") }
                Button(role: .destructive) { lessonToDelete = l } label: { Label("حذف الدرس", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.body.bold()).foregroundColor(.dim)
                    .frame(width: 34, height: 48).contentShape(Rectangle())
            }
        }
        .draggable(LessonDrag(id: l.id)) {
            Text(l.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentBlue, in: Capsule())
        }
        .dropDestination(for: LessonDrag.self) { items, _ in
            guard let d = items.first else { return false }
            store.moveLesson(id: d.id, toUnit: l.unitID, before: l.id)
            haptic()
            return true
        }
    }

    private func lessonButton(_ l: Lesson, isFirst: Bool, isLast: Bool) -> some View {
        Button { playTarget = PlayTarget(id: l.id) } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    LessonThumb(url: store.url(for: l.fileName))
                    if l.duration > 0 {
                        GeometryReader { g in
                            Rectangle().fill(Color.white.opacity(0.25))
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(l.isDone ? Color.doneGreen : Color.accentBlue)
                                        .frame(width: g.size.width * CGFloat(l.progress))
                                }
                        }
                        .frame(height: 3)
                    }
                    Image(systemName: l.isDone ? "checkmark.circle.fill" : "play.fill")
                        .font(.system(size: l.isDone ? 20 : 15))
                        .foregroundColor(l.isDone ? .doneGreen : .white)
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 112, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(l.title).font(.subheadline.weight(.semibold)).foregroundColor(.white)
                        .multilineTextAlignment(.leading).lineLimit(2)
                    if l.duration > 0 {
                        Text(l.isDone ? "مكتمل · \(formatTime(l.duration))" : (l.position > 1 ? "تابع من \(formatTime(l.position)) · \(formatTime(l.duration))" : formatTime(l.duration)))
                            .font(.caption2).foregroundColor(l.isDone ? .doneGreen : .dim)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: helpers
    private var renameTitle: String {
        switch renameKind {
        case .newUnit: return "فصل جديد"
        case .unit: return "تغيير اسم الفصل"
        case .lesson: return "تغيير اسم الدرس"
        case nil: return ""
        }
    }

    private func commitRename() {
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renameKind = nil }
        guard !t.isEmpty, let k = renameKind else { return }
        switch k {
        case .newUnit(let sid):
            let u = store.addUnit(subjectID: sid, title: t)
            expanded.insert(u.id)
            scrollTarget = u.id
        case .unit(let u): store.renameUnit(u, to: t)
        case .lesson(let l): store.renameLesson(l, to: t)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem], unitID: UUID) async {
        busy = true
        var urls: [URL] = []
        for (idx, item) in items.enumerated() {
            store.importStatus = "جاري تحميل \(idx + 1) من \(items.count)…"
            if let movie = try? await item.loadTransferable(type: MovieFile.self) { urls.append(movie.url) }
        }
        let n = await store.importLessons(urls, unitID: unitID)
        toastText = n > 0 ? "تمت إضافة \(n) درس ✓" : ("تعذّر: " + (store.lastImportError ?? "استيراد الفيديو"))
        photoItems = []
        expanded.insert(unitID)
        busy = false
    }
}


struct BulkRenameView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let unitID: UUID
    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    ForEach(store.lessons(in: unitID)) { l in
                        HStack(spacing: 12) {
                            LessonThumb(url: store.url(for: l.fileName))
                                .frame(width: 76, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            TextField("العنوان", text: Binding(
                                get: { store.lesson(l.id)?.title ?? "" },
                                set: { store.renameLesson(l, to: $0) }))
                                .foregroundColor(.white)
                        }
                        .listRowBackground(Color.cardBg)
                    }
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("تعديل العناوين")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }
}


struct ReorderView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let unitID: UUID
    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    ForEach(store.lessons(in: unitID)) { l in
                        HStack(spacing: 12) {
                            LessonThumb(url: store.url(for: l.fileName))
                                .frame(width: 76, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(l.title).foregroundColor(.white).lineLimit(2)
                        }
                        .listRowBackground(Color.cardBg)
                    }
                    .onMove { from, to in store.moveLessons(in: unitID, from: from, to: to) }
                }
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
            .navigationTitle("ترتيب الفيديوهات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }
}
