import SwiftUI

struct SubjectsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Subject?
    @State private var showNew = false
    @State private var toDelete: Subject?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.subjects.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tertiary)
                        Text("ما فيه مواد بعد")
                            .font(.title3.bold())
                        Text("اضغط + لإضافة أول مادة، وبعدها ضيف فيديوهاتك وملفاتك داخلها")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button { showNew = true } label: {
                            Label("إضافة مادة", systemImage: "plus")
                                .padding(.horizontal, 20).padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 120)
                    .padding(.horizontal, 30)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.subjects) { s in
                            NavigationLink(value: s) { SubjectCard(subject: s) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { editing = s } label: { Label("تعديل", systemImage: "pencil") }
                                    Button(role: .destructive) { toDelete = s } label: { Label("حذف", systemImage: "trash") }
                                }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("دروسي")
            .navigationDestination(for: Subject.self) { s in SubjectDetailView(subjectID: s.id) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $showNew) { SubjectEditor(subject: nil) }
            .sheet(item: $editing) { s in SubjectEditor(subject: s) }
            .alert("حذف المادة؟", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
                Button("حذف", role: .destructive) { if let s = toDelete { store.deleteSubject(s) }; toDelete = nil }
                Button("إلغاء", role: .cancel) { toDelete = nil }
            } message: {
                Text("راح تنحذف المادة مع كل فيديوهاتها وملفاتها.")
            }
        }
    }
}

struct SubjectCard: View {
    @EnvironmentObject var store: Store
    let subject: Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            Text(subject.name)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            HStack(spacing: 10) {
                Label("\(store.videoCount(subject))", systemImage: "play.fill")
                Label("\(store.fileCount(subject))", systemImage: "paperclip")
            }
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .padding(16)
        .background(Palette.gradient(subject.colorIndex))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

struct SubjectEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let subject: Subject?
    @State private var name = ""
    @State private var colorIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("اسم المادة") {
                    TextField("مثال: الرياضيات", text: $name)
                }
                Section("اللون") {
                    HStack(spacing: 14) {
                        ForEach(0..<Palette.gradients.count, id: \.self) { i in
                            Circle()
                                .fill(Palette.gradient(i))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary, lineWidth: colorIndex == i ? 3 : 0).padding(-4))
                                .onTapGesture { colorIndex = i }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(subject == nil ? "مادة جديدة" : "تعديل المادة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty else { return }
                        if let s = subject { store.updateSubject(s, name: n, colorIndex: colorIndex) }
                        else { store.addSubject(name: n, colorIndex: colorIndex) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let s = subject { name = s.name; colorIndex = s.colorIndex }
                else { colorIndex = store.subjects.count % Palette.gradients.count }
            }
        }
        .presentationDetents([.medium])
    }
}
