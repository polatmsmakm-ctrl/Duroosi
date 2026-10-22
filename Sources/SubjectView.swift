import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum RenameKind { case newUnit(UUID), unit(CourseUnit), lesson(Lesson) }

struct SubjectView: View {
    @EnvironmentObject var store: Store
    let subjectID: UUID

    @State private var expanded: Set<UUID> = []
    @State private var playTarget: PlayTarget?
    @State private var showFiles = false
    @State private var showSearch = false
    @State private var busy = false
    @State private var float = false

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
                ScrollView {
                    VStack(spacing: 0) {
                        hero(s)
                        curriculum(s)
                    }
                }
            }
            if busy { BusyOverlay() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(subject?.name ?? "")
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
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 30, matching: .videos)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty, let uid = targetUnit else { return }
            Task { await importPhotos(items, unitID: uid) }
        }
        .documentPicker(isPresented: $showVideoImporter,
                        types: [.movie, .video, .mpeg4Movie, .quickTimeMovie], asCopy: false) { urls in
            guard let uid = targetUnit else { return }
            Task {
                busy = true
                let n = await store.importLessons(urls, unitID: uid)
                busy = false
                expanded.insert(uid)
                toastText = n > 0 ? "تمت إضافة \(n) درس ✓" : ("تعذّر: " + (store.lastImportError ?? "استيراد الفيديو"))
            }
        }
        .sheet(item: $quizRun) { t in QuizRunnerView(unitID: t.id) }
        .sheet(item: $quizEdit) { t in QuizEditorView(unitID: t.id) }
        .toast($toastText)
        .alert(renameTitle, isPresented: Binding(get: { renameKind != nil }, set: { if !$0 { renameKind = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { commitRename() }
            Button("إلغاء", role: .cancel) { renameKind = nil }
        }
        .alert("حذف الوحدة؟", isPresented: Binding(get: { unitToDelete != nil }, set: { if !$0 { unitToDelete = nil } })) {
            Button("حذف", role: .destructive) { if let u = unitToDelete { store.deleteUnit(u) }; unitToDelete = nil }
            Button("إلغاء", role: .cancel) { unitToDelete = nil }
        } message: { Text("راح تنحذف الوحدة مع كل دروسها وملفاتها.") }
        .alert("حذف الدرس؟", isPresented: Binding(get: { lessonToDelete != nil }, set: { if !$0 { lessonToDelete = nil } })) {
            Button("حذف", role: .destructive) { if let l = lessonToDelete { store.deleteLesson(l) }; lessonToDelete = nil }
            Button("إلغاء", role: .cancel) { lessonToDelete = nil }
        }
        .onAppear {
            float = true
            if expanded.isEmpty, let f = store.units(of: subjectID).first { expanded.insert(f.id) }
        }
    }

    // MARK: hero
    private func hero(_ s: Subject) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Palette.glow(s.colorIndex).opacity(0.55), .clear],
                                         center: .center, startRadius: 5, endRadius: 150))
                    .frame(width: 300, height: 300)
                Image(systemName: s.icon)
                    .font(.system(size: 120, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.white, Palette.glow(s.colorIndex)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Palette.glow(s.colorIndex).opacity(0.8), radius: 24)
                    .offset(y: float ? -8 : 8)
                    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: float)
            }
            .frame(height: 230)

            if let l = store.continueLesson(subjectID) {
                ContinuePill(title: l.title, subtitle: store.progress(subject: subjectID) > 0 ? "تابع من حيث وقفت" : "ابدأ الآن") {
                    playTarget = PlayTarget(id: l.id)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 70)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [.clear, Palette.glow(s.colorIndex).opacity(0.35)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: curriculum
    private func curriculum(_ s: Subject) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("منهج المادة").font(.title3.bold()).foregroundColor(.white)
                Spacer()
                Text("\(Int(store.progress(subject: s.id) * 100))%").font(.subheadline.bold()).foregroundColor(.dim)
            }
            .padding(.top, 22)

            Button { showFiles = true } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("المذكرات والملفات").font(.headline).foregroundColor(.white)
                        Text("مذكرات وملفات المادة المهمة").font(.caption).foregroundColor(.dim)
                    }
                    Spacer(minLength: 0)
                    Text("\(store.fileCount(s.id))")
                        .font(.caption.bold()).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accentBlue, in: Capsule())
                    Image(systemName: "doc.on.doc.fill")
                        .font(.title2).foregroundColor(.white)
                        .frame(width: 54, height: 54)
                        .background(Palette.gradient(s.colorIndex), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(14)
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)

            ForEach(store.units(of: s.id)) { u in unitCard(u) }

            Button {
                renameText = ""
                renameKind = .newUnit(s.id)
            } label: {
                Label("إضافة وحدة", systemImage: "plus")
                    .font(.headline).foregroundColor(.accentBlue)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.accentBlue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 50)
        }
        .padding(.horizontal, 16)
        .background(Color.appBg.opacity(0.92), in: RoundedCorner(radius: 32, corners: [.topLeft, .topRight]))
        .frame(minHeight: 420, alignment: .top)
    }

    private func unitCard(_ u: CourseUnit) -> some View {
        let ls = store.lessons(in: u.id)
        let isOpen = expanded.contains(u.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if isOpen { expanded.remove(u.id) } else { expanded.insert(u.id) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(u.title).font(.headline).foregroundColor(.white).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text("\(ls.count)").font(.caption.bold()).foregroundColor(.dim)
                        Image(systemName: isOpen ? "minus" : "plus").font(.subheadline.bold()).foregroundColor(.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button { targetUnit = u.id; showPhotos = true } label: { Label("إضافة فيديو من الاستوديو", systemImage: "photo.on.rectangle") }
                    Button { targetUnit = u.id; showVideoImporter = true } label: { Label("إضافة فيديو من الملفات", systemImage: "folder") }
                    Divider()
                    Button { quizEdit = PlayTarget(id: u.id) } label: { Label("أسئلة اختبار الوحدة", systemImage: "checklist") }
                    Button { renameText = u.title; renameKind = .unit(u) } label: { Label("تغيير اسم الوحدة", systemImage: "pencil") }
                    Button { store.moveUnit(u, by: -1) } label: { Label("نقل للأعلى", systemImage: "arrow.up") }
                    Button { store.moveUnit(u, by: 1) } label: { Label("نقل للأسفل", systemImage: "arrow.down") }
                    Button(role: .destructive) { unitToDelete = u } label: { Label("حذف الوحدة", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3).foregroundColor(.accentBlue)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 18)

            if isOpen {
                VStack(spacing: 0) {
                    if ls.isEmpty {
                        Text("ما فيه دروس — اضغط ⋯ وأضف فيديو")
                            .font(.footnote).foregroundColor(.dim).padding(.vertical, 14)
                    }
                    ForEach(Array(ls.enumerated()), id: \.element.id) { idx, l in
                        lessonRow(l, isFirst: idx == 0, isLast: idx == ls.count - 1)
                    }
                    Divider().background(Color.white.opacity(0.12)).padding(.vertical, 4)
                    quizRow(u)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
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
                    Text("اختبار مراجعة الوحدة").font(.subheadline.weight(.medium)).foregroundColor(.white)
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
        Button { playTarget = PlayTarget(id: l.id) } label: {
            HStack(spacing: 12) {
                ZStack {
                    VStack(spacing: 0) {
                        Rectangle().fill(isFirst ? Color.clear : Color.accentBlue.opacity(0.6)).frame(width: 2)
                        Rectangle().fill(isLast ? Color.clear : Color.accentBlue.opacity(0.6)).frame(width: 2)
                    }
                    ProgressRing(progress: l.progress, size: 26)
                }
                .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(l.title).font(.subheadline.weight(.medium)).foregroundColor(.white).multilineTextAlignment(.leading).lineLimit(2)
                    if l.duration > 0 {
                        Text(l.isDone ? "مكتمل" : (l.position > 1 ? "تابع من \(formatTime(l.position))" : formatTime(l.duration)))
                            .font(.caption2).foregroundColor(l.isDone ? .doneGreen : .dim)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.left").font(.caption.bold()).foregroundColor(.dim)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { store.toggleDone(l) } label: {
                Label(l.isDone ? "إلغاء الإكمال" : "تعليم كمكتمل", systemImage: "checkmark.circle")
            }
            Button { renameText = l.title; renameKind = .lesson(l) } label: { Label("تغيير الاسم", systemImage: "pencil") }
            Button { store.moveLesson(l, by: -1) } label: { Label("نقل للأعلى", systemImage: "arrow.up") }
            Button { store.moveLesson(l, by: 1) } label: { Label("نقل للأسفل", systemImage: "arrow.down") }
            Button(role: .destructive) { lessonToDelete = l } label: { Label("حذف الدرس", systemImage: "trash") }
        }
    }

    // MARK: helpers
    private var renameTitle: String {
        switch renameKind {
        case .newUnit: return "وحدة جديدة"
        case .unit: return "تغيير اسم الوحدة"
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
        case .unit(let u): store.renameUnit(u, to: t)
        case .lesson(let l): store.renameLesson(l, to: t)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem], unitID: UUID) async {
        busy = true
        var urls: [URL] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: MovieFile.self) { urls.append(movie.url) }
        }
        let n = await store.importLessons(urls, unitID: unitID)
        toastText = n > 0 ? "تمت إضافة \(n) درس ✓" : ("تعذّر: " + (store.lastImportError ?? "استيراد الفيديو"))
        photoItems = []
        expanded.insert(unitID)
        busy = false
    }
}
