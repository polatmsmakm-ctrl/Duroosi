import SwiftUI

func intervalLabel(_ days: Double) -> String {
    if days <= 0 { return "10 د" }
    if days < 30 { return "\(Int(days.rounded())) يوم" }
    return "\(Int((days / 30).rounded())) شهر"
}

struct FlashcardsEntry: View {
    @EnvironmentObject var store: Store
    @State private var show = false
    var body: some View {
        let due = store.dueCards().count
        Button { show = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.title3.bold()).foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentBlue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("مراجعة البطاقات").font(.subheadline.bold()).foregroundColor(.white)
                    Text(store.flashcards.isEmpty ? "حوّل علاماتك لبطاقات مراجعة" : (due > 0 ? "\(due) بطاقة مستحقة اليوم" : "خلّصت مراجعة اليوم ✓"))
                        .font(.caption).foregroundColor(.dim)
                }
                Spacer(minLength: 0)
                if due > 0 {
                    Text("\(due)").font(.footnote.bold()).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.85), in: Capsule())
                }
                Image(systemName: "chevron.left").font(.caption.bold()).foregroundColor(.dim)
            }
            .padding(14)
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $show) { FlashcardsHub() }
    }
}

struct FlashcardsHub: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        Text("مراجعة").tag(0)
                        Text("كل البطاقات").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    if tab == 0 { ReviewView() } else { CardsList() }
                }
            }
            .navigationTitle("البطاقات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: Store
    @State private var queue: [UUID] = []
    @State private var started = false
    @State private var revealed = false
    @State private var done = 0
    @State private var play: PlayTarget?
    @State private var playStart: Double?

    private var current: Flashcard? {
        guard let id = queue.first else { return nil }
        return store.flashcards.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 16) {
            if let c = current {
                HStack {
                    Text("متبقي \(queue.count)").font(.footnote.bold()).foregroundColor(.dim)
                    Spacer()
                    Text("تمت \(done)").font(.footnote.bold()).foregroundColor(.doneGreen)
                }
                .padding(.horizontal, 20)

                ScrollView {
                    VStack(spacing: 18) {
                        Text(c.front)
                            .font(.title2.bold()).foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        if revealed {
                            Divider().background(Color.white.opacity(0.2))
                            Text(c.back)
                                .font(.title3).foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.5))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                            if let lid = c.lessonID, store.lesson(lid) != nil {
                                Button {
                                    playStart = max(0, (c.time ?? 0) - 3)
                                    play = PlayTarget(id: lid)
                                } label: {
                                    Label("افتح الفيديو", systemImage: "play.circle.fill")
                                        .font(.subheadline.bold()).foregroundColor(.white)
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                        .background(Color.white.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .background(Color.cardBg2, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { revealed = true } }
                }

                if revealed {
                    HStack(spacing: 8) {
                        ForEach(Grade.allCases, id: \.self) { g in
                            Button { answer(c, g) } label: {
                                VStack(spacing: 4) {
                                    Text(g.title).font(.subheadline.bold())
                                    Text(intervalLabel(store.nextInterval(c, g))).font(.caption2).opacity(0.8)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(color(g), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                } else {
                    Button { withAnimation { revealed = true } } label: {
                        Text("أظهر الإجابة").font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.accentBlue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: store.flashcards.isEmpty ? "rectangle.on.rectangle.angled" : "checkmark.seal.fill")
                        .font(.system(size: 54)).foregroundColor(store.flashcards.isEmpty ? .white.opacity(0.3) : .doneGreen)
                    Text(store.flashcards.isEmpty ? "ما عندك بطاقات بعد" : "خلّصت مراجعة اليوم 🎉")
                        .font(.title3.bold()).foregroundColor(.white)
                    Text(store.flashcards.isEmpty
                         ? "أضف علامات مكتوب عليها ملاحظة في الدروس، وبعدها اضغط «توليد من العلامات» أو أضف بطاقة بنفسك من «كل البطاقات»."
                         : "البطاقات الجاية توصلك بالمواعيد اللي حددها نظام التكرار المتباعد.")
                        .font(.footnote).foregroundColor(.dim).multilineTextAlignment(.center).padding(.horizontal, 30)
                    if store.flashcards.isEmpty {
                        Button {
                            store.generateCardsFromBookmarks()
                            reload()
                        } label: {
                            Text("توليد من العلامات").font(.subheadline.bold()).foregroundColor(.white)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Color.accentBlue, in: Capsule())
                        }
                    }
                }
                Spacer()
            }
        }
        .onAppear { if !started { started = true; reload() } }
        .fullScreenCover(item: $play) { t in LessonPlayerView(lessonID: t.id, startAt: playStart) }
    }

    private func reload() {
        queue = store.dueCards().map { $0.id }
        revealed = false
    }

    private func color(_ g: Grade) -> Color {
        switch g {
        case .again: return Color.red.opacity(0.75)
        case .hard: return Color.orange.opacity(0.8)
        case .good: return Color.green.opacity(0.7)
        case .easy: return Color.blue.opacity(0.75)
        }
    }

    private func answer(_ c: Flashcard, _ g: Grade) {
        store.rate(c, g)
        haptic()
        if !queue.isEmpty { queue.removeFirst() }
        if g == .again { queue.append(c.id) } else { done += 1 }
        withAnimation { revealed = false }
    }
}

struct CardsList: View {
    @EnvironmentObject var store: Store
    @State private var editing: Flashcard?
    @State private var adding = false
    @State private var msg: String?

    var body: some View {
        List {
            Section {
                Button { adding = true } label: { Label("بطاقة جديدة", systemImage: "plus.circle.fill") }
                Button {
                    let n = store.generateCardsFromBookmarks()
                    msg = n > 0 ? "تم توليد \(n) بطاقة ✓" : "ما فيه علامات جديدة مكتوب عليها ملاحظة"
                } label: { Label("توليد من العلامات", systemImage: "bookmark.fill") }
                if let m = msg { Text(m).font(.footnote).foregroundColor(.dim) }
            }
            .listRowBackground(Color.cardBg)

            Section("\(store.flashcards.count) بطاقة") {
                ForEach(store.flashcards) { c in
                    Button { editing = c } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.front).font(.subheadline.bold()).foregroundColor(.white).lineLimit(2)
                            Text(c.back).font(.caption).foregroundColor(.dim).lineLimit(1)
                            Text(c.due <= Date() ? "مستحقة الآن" : "بعد " + intervalLabel(max(c.due.timeIntervalSinceNow / 86400, 0.01)))
                                .font(.caption2).foregroundColor(c.due <= Date() ? .orange : .doneGreen)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.deleteCard(c) } label: { Label("حذف", systemImage: "trash") }
                    }
                }
            }
            .listRowBackground(Color.cardBg)
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $adding) { CardEditor(card: nil) }
        .sheet(item: $editing) { c in CardEditor(card: c) }
    }
}

struct CardEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let card: Flashcard?
    @State private var front = ""
    @State private var back = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("السؤال / الوجه الأمامي") { TextField("اكتب السؤال", text: $front, axis: .vertical).lineLimit(2...6) }
                Section("الإجابة / الوجه الخلفي") { TextField("اكتب الإجابة", text: $back, axis: .vertical).lineLimit(2...8) }
            }
            .navigationTitle(card == nil ? "بطاقة جديدة" : "تعديل البطاقة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        let f = front.trimmingCharacters(in: .whitespacesAndNewlines)
                        let b = back.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !f.isEmpty else { return }
                        if var c = card { c.front = f; c.back = b; store.updateCard(c) }
                        else { store.addCard(front: f, back: b) }
                        dismiss()
                    }
                    .disabled(front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if let c = card { front = c.front; back = c.back } }
        }
    }
}
