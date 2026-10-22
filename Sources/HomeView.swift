import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var showNew = false
    @State private var editing: Subject?
    @State private var toDelete: Subject?
    @State private var playTarget: PlayTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("دروسي").font(.system(size: 34, weight: .heavy)).foregroundColor(.white)
                                Text(store.subjects.isEmpty ? "ابدأ بإضافة أول مادة" : "\(store.subjects.count) مواد")
                                    .font(.subheadline).foregroundColor(.dim)
                            }
                            Spacer()
                            Button { showNew = true } label: {
                                Image(systemName: "plus")
                                    .font(.headline.bold())
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentBlue, in: Circle())
                            }
                        }
                        .padding(.top, 8)

                        if !store.lessons.isEmpty { StatsCard() }

                        if let l = store.globalContinue(), let s = store.subject(l.subjectID) {
                            ContinuePill(title: l.title, subtitle: s.name) {
                                playTarget = PlayTarget(id: l.id)
                            }
                        }

                        if store.subjects.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "books.vertical.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.25))
                                Text("ما فيه مواد بعد").font(.title3.bold()).foregroundColor(.white)
                                Text("أضف مادة، وبعدها وحدات، وبعدها ضيف فيديوهاتك وملفاتك داخلها")
                                    .font(.subheadline).foregroundColor(.dim).multilineTextAlignment(.center)
                            }
                            .padding(.top, 80)
                        }

                        ForEach(store.subjects) { s in
                            NavigationLink(value: s) { SubjectRow(subject: s) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { editing = s } label: { Label("تعديل", systemImage: "pencil") }
                                    Button(role: .destructive) { toDelete = s } label: { Label("حذف", systemImage: "trash") }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Subject.self) { s in SubjectView(subjectID: s.id) }
            .sheet(isPresented: $showNew) { SubjectEditor(subject: nil) }
            .sheet(item: $editing) { s in SubjectEditor(subject: s) }
            .fullScreenCover(item: $playTarget) { t in LessonPlayerView(lessonID: t.id) }
            .alert("حذف المادة؟", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
                Button("حذف", role: .destructive) { if let s = toDelete { store.deleteSubject(s) }; toDelete = nil }
                Button("إلغاء", role: .cancel) { toDelete = nil }
            } message: {
                Text("راح تنحذف المادة مع كل وحداتها ودروسها وملفاتها.")
            }
        }
    }
}

struct ContinuePill: View {
    let title: String
    let subtitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("أكمل الدراسة · \(subtitle)").font(.caption).foregroundColor(.white.opacity(0.8))
                    Text(title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentBlue, in: Circle())
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(
                LinearGradient(colors: [Color(red: 0.42, green: 0.25, blue: 0.95), Color(red: 0.25, green: 0.2, blue: 0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SubjectRow: View {
    @EnvironmentObject var store: Store
    let subject: Subject
    var body: some View {
        let p = store.progress(subject: subject.id)
        let lessonCount = store.lessons.filter { $0.subjectID == subject.id }.count
        HStack(spacing: 14) {
            SubjectOrb(subject: subject, size: 62)
            VStack(alignment: .leading, spacing: 7) {
                Text(subject.name).font(.headline).foregroundColor(.white).lineLimit(1)
                Text("\(store.units(of: subject.id).count) وحدة · \(lessonCount) درس · \(store.fileCount(subject.id)) ملف")
                    .font(.caption).foregroundColor(.dim)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Palette.gradient(subject.colorIndex)).frame(width: g.size.width * CGFloat(p))
                    }
                }
                .frame(height: 5)
            }
            Spacer(minLength: 0)
            Text("\(Int(p * 100))%").font(.subheadline.bold()).foregroundColor(.white.opacity(0.85))
        }
        .padding(14)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

struct SubjectEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let subject: Subject?
    @State private var name = ""
    @State private var colorIndex = 0
    @State private var icon = subjectIcons[0]

    var body: some View {
        NavigationStack {
            Form {
                Section("اسم المادة") { TextField("مثال: الرياضيات", text: $name) }
                Section("اللون") {
                    HStack(spacing: 14) {
                        ForEach(0..<Palette.gradients.count, id: \.self) { i in
                            Circle().fill(Palette.gradient(i)).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Color.white, lineWidth: colorIndex == i ? 3 : 0).padding(-4))
                                .onTapGesture { colorIndex = i }
                        }
                    }.padding(.vertical, 6)
                }
                Section("الأيقونة") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(subjectIcons, id: \.self) { sym in
                            Image(systemName: sym).font(.title3).frame(width: 46, height: 46)
                                .background(icon == sym ? Palette.glow(colorIndex).opacity(0.4) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { icon = sym }
                        }
                    }.padding(.vertical, 6)
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
                        if let s = subject { store.updateSubject(s, name: n, colorIndex: colorIndex, icon: icon) }
                        else { store.addSubject(name: n, colorIndex: colorIndex, icon: icon) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let s = subject { name = s.name; colorIndex = s.colorIndex; icon = s.icon }
                else { colorIndex = store.subjects.count % Palette.gradients.count; icon = subjectIcons[store.subjects.count % subjectIcons.count] }
            }
        }
    }
}


struct StatsCard: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let d = store.totalDone()
        HStack(spacing: 0) {
            stat("flame.fill", "\(store.streak())", "أيام متتالية", .orange)
            Divider().background(Color.white.opacity(0.12)).frame(height: 40)
            stat("clock.fill", "\(store.todayMinutes())", "دقيقة اليوم", .cyan)
            Divider().background(Color.white.opacity(0.12)).frame(height: 40)
            stat("checkmark.circle.fill", "\(d.done)/\(d.total)", "دروس مكتملة", .doneGreen)
        }
        .padding(.vertical, 14)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
    private func stat(_ icon: String, _ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color)
            Text(value).font(.title3.bold()).foregroundColor(.white)
            Text(label).font(.caption2).foregroundColor(.dim)
        }
        .frame(maxWidth: .infinity)
    }
}
