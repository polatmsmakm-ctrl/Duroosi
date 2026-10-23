import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var showNew = false
    @State private var editing: Subject?
    @State private var toDelete: Subject?
    @State private var playTarget: PlayTarget?

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selected: UUID?

    private func content(split: Bool) -> some View {
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
            if !store.lessons.isEmpty || !store.flashcards.isEmpty { FlashcardsEntry() }

            if let l = store.globalContinue(), let s = store.subject(l.subjectID) {
                ContinuePill(title: l.title, subtitle: s.name) {
                    playTarget = PlayTarget(id: l.id)
                }
            }

            if store.subjects.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.25))
                    Text("ما فيه مواد بعد").font(.title3.bold()).foregroundColor(.white)
                    Text("أضف مادة، وبعدها فصول، وبعدها ضيف فيديوهاتك وملفاتك داخلها")
                        .font(.subheadline).foregroundColor(.dim).multilineTextAlignment(.center)
                }
                .padding(.top, 80)
            }

            LazyVGrid(columns: split
                      ? [GridItem(.flexible())]
                      : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(store.subjects) { s in
                    Group {
                        if split {
                            Button { selected = s.id } label: { SubjectRow(subject: s) }
                        } else {
                            NavigationLink(value: s) { SubjectRow(subject: s) }
                        }
                    }
                    .buttonStyle(.plain)
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.accentBlue, lineWidth: split && selected == s.id ? 3 : 0))
                    .contextMenu {
                        Button { editing = s } label: { Label("تعديل", systemImage: "pencil") }
                        Button(role: .destructive) { toDelete = s } label: { Label("حذف", systemImage: "trash") }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }

    private var phoneBody: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView { content(split: false) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Subject.self) { s in SubjectView(subjectID: s.id) }
        }
    }

    private var splitBody: some View {
        NavigationSplitView {
            ZStack {
                AppBackground()
                ScrollView { content(split: true) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
        } detail: {
            ZStack {
                AppBackground()
                if let id = selected, store.subject(id) != nil {
                    NavigationStack { SubjectView(subjectID: id) }.id(id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sidebar.leading").font(.system(size: 54)).foregroundColor(.white.opacity(0.25))
                        Text("اختر مادة من القائمة").font(.title3.bold()).foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    var body: some View {
        Group {
            if hSize == .regular { splitBody } else { phoneBody }
        }
        .sheet(isPresented: $showNew) { SubjectEditor(subject: nil) }
        .sheet(item: $editing) { s in SubjectEditor(subject: s) }
        .fullScreenCover(item: $playTarget) { t in LessonPlayerView(lessonID: t.id) }
        .alert("حذف المادة؟", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("حذف", role: .destructive) { if let s = toDelete { store.deleteSubject(s) }; toDelete = nil }
            Button("إلغاء", role: .cancel) { toDelete = nil }
        } message: {
            Text("راح تنحذف المادة مع كل فصولها ودروسها وملفاتها.")
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
                LinearGradient(colors: [Color(red: 0.93, green: 0.60, blue: 0.22), Color(red: 0.62, green: 0.30, blue: 0.10)],
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
        ZStack(alignment: .topLeading) {
            Palette.gradient(subject.colorIndex)
            Image(systemName: subject.icon)
                .font(.system(size: 96, weight: .bold))
                .foregroundColor(.white.opacity(0.16))
                .rotationEffect(.degrees(-12))
                .offset(x: -34, y: 38)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: subject.icon)
                    .font(.title3.bold()).foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Spacer(minLength: 6)
                Text(subject.name).font(.headline.bold()).foregroundColor(.white).lineLimit(2).multilineTextAlignment(.leading)
                Text("\(store.units(of: subject.id).count) فصل · \(lessonCount) درس")
                    .font(.caption).foregroundColor(.white.opacity(0.85))
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.25))
                            Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(p))
                        }
                    }
                    .frame(height: 5)
                    Text("\(Int(p * 100))%").font(.caption2.bold()).foregroundColor(.white)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 172)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: Palette.glow(subject.colorIndex).opacity(0.35), radius: 14, y: 8)
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
            stat("clock.fill", "\(store.todayMinutes())", "دقيقة اليوم", Color(red: 1.0, green: 0.78, blue: 0.40))
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
