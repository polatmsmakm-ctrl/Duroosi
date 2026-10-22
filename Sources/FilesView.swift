import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let subjectID: UUID
    @State private var showImporter = false
    @State private var preview: IdentURL?
    @State private var renaming: FileAttachment?
    @State private var text = ""
    @State private var busy = false

    private var notes: [FileAttachment] { store.notes(of: subjectID) }
    private var lessonFiles: [FileAttachment] { store.files.filter { $0.subjectID == subjectID && $0.lessonID != nil } }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if notes.isEmpty && lessonFiles.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "paperclip").font(.system(size: 50)).foregroundColor(.white.opacity(0.25))
                                Text("ما فيه ملفات").font(.headline).foregroundColor(.white)
                                Text("اضغط + وأرفق مذكرات PDF أو صور أو أي ملف").font(.subheadline).foregroundColor(.dim)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 100)
                        }
                        if !notes.isEmpty {
                            Text("مذكرات المادة").font(.headline).foregroundColor(.white)
                            ForEach(notes) { f in row(f, subtitle: nil) }
                        }
                        if !lessonFiles.isEmpty {
                            Text("ملفات الدروس").font(.headline).foregroundColor(.white).padding(.top, 8)
                            ForEach(lessonFiles) { f in row(f, subtitle: f.lessonID.flatMap { store.lesson($0)?.title }) }
                        }
                    }
                    .padding(16)
                }
                if busy { BusyOverlay() }
            }
            .navigationTitle("المذكرات والملفات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showImporter = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                Task { busy = true; await store.importFiles(urls, subjectID: subjectID, lessonID: nil); busy = false }
            }
            .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
            .alert("تغيير الاسم", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("الاسم", text: $text)
                Button("حفظ") {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, let f = renaming { store.renameFile(f, to: t) }
                    renaming = nil
                }
                Button("إلغاء", role: .cancel) { renaming = nil }
            }
        }
    }

    private func row(_ f: FileAttachment, subtitle: String?) -> some View {
        FileRow(file: f, subtitle: subtitle)
            .onTapGesture { preview = IdentURL(url: store.url(for: f.fileName)) }
            .contextMenu {
                Button { text = f.title; renaming = f } label: { Label("تغيير الاسم", systemImage: "pencil") }
                Button(role: .destructive) { store.deleteFile(f) } label: { Label("حذف", systemImage: "trash") }
            }
    }
}

struct SearchView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let subjectID: UUID
    let onPlay: (UUID) -> Void
    @State private var query = ""
    @State private var preview: IdentURL?

    private var lessonResults: [Lesson] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.orderedLessons(subjectID).filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var fileResults: [FileAttachment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.files.filter { $0.subjectID == subjectID && $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if query.isEmpty {
                            Text("اكتب اسم درس أو ملف").font(.subheadline).foregroundColor(.dim).padding(.top, 60).frame(maxWidth: .infinity)
                        } else if lessonResults.isEmpty && fileResults.isEmpty {
                            Text("ما لقيت نتائج").font(.subheadline).foregroundColor(.dim).padding(.top, 60).frame(maxWidth: .infinity)
                        }
                        ForEach(lessonResults) { l in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onPlay(l.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    LessonThumb(url: store.url(for: l.fileName))
                                        .frame(width: 96, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(l.title).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                                        Text(store.unit(l.unitID)?.title ?? "").font(.caption).foregroundColor(.dim)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(fileResults) { f in
                            FileRow(file: f).onTapGesture { preview = IdentURL(url: store.url(for: f.fileName)) }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("بحث")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ابحث في المادة")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
        }
    }
}
