import SwiftUI

struct QuizEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let unitID: UUID
    @State private var editing: QuizQuestion?
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                let qs = store.questions(of: unitID)
                if qs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checklist").font(.system(size: 52)).foregroundColor(.white.opacity(0.25))
                        Text("ما فيه أسئلة").font(.headline).foregroundColor(.white)
                        Text("اضغط + لإضافة أسئلة اختيار من متعدد لمراجعة الوحدة")
                            .font(.subheadline).foregroundColor(.dim).multilineTextAlignment(.center)
                    }.padding(30)
                } else {
                    List {
                        ForEach(Array(qs.enumerated()), id: \.element.id) { i, q in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.footnote.bold()).foregroundColor(.white)
                                    .frame(width: 28, height: 28).background(Color.accentBlue, in: Circle())
                                Text(q.text).font(.subheadline).foregroundColor(.white).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = q }
                            .listRowBackground(Color.cardBg)
                        }
                        .onDelete { idx in
                            let items = idx.map { qs[$0] }
                            items.forEach { store.deleteQuestion($0) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("أسئلة الاختبار")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $showNew) { QuestionForm(unitID: unitID, question: nil) }
            .sheet(item: $editing) { q in QuestionForm(unitID: unitID, question: q) }
        }
    }
}

struct QuestionForm: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let unitID: UUID
    let question: QuizQuestion?
    @State private var text = ""
    @State private var opts = ["", "", "", ""]
    @State private var correct = 0

    private var cleanCount: Int { opts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    private var valid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cleanCount >= 2
            && !opts[correct].trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("السؤال") { TextField("اكتب السؤال", text: $text, axis: .vertical).lineLimit(2...5) }
                Section("الخيارات — اضغط الدائرة لتحديد الإجابة الصحيحة") {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 10) {
                            Button { correct = i } label: {
                                Image(systemName: correct == i ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundColor(correct == i ? .doneGreen : .dim)
                            }
                            .buttonStyle(.plain)
                            TextField("الخيار \(i + 1)", text: $opts[i])
                        }
                    }
                }
            }
            .navigationTitle(question == nil ? "سؤال جديد" : "تعديل السؤال")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        let trimmed = opts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        var kept: [String] = []
                        var newCorrect = 0
                        for (i, o) in trimmed.enumerated() where !o.isEmpty {
                            if i == correct { newCorrect = kept.count }
                            kept.append(o)
                        }
                        var q = question ?? QuizQuestion(unitID: unitID, text: "", options: [], correct: 0)
                        q.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        q.options = kept
                        q.correct = newCorrect
                        store.saveQuestion(q)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .onAppear {
                if let q = question {
                    text = q.text
                    var o = q.options
                    while o.count < 4 { o.append("") }
                    opts = Array(o.prefix(4))
                    correct = q.correct
                }
            }
        }
    }
}

struct QuizRunnerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let unitID: UUID

    @State private var questions: [QuizQuestion] = []
    @State private var index = 0
    @State private var order: [Int] = []
    @State private var selected: Int?
    @State private var score = 0
    @State private var finished = false

    private let praise = ["ممتاز! 🎉", "أحسنت! 👏", "إجابة صحيحة ✨", "برافو عليك 🔥", "عاش! 💪"]
    private let retry = ["للأسف خطأ، ركّز أكثر", "قريب! حاول مرة ثانية", "ما صارت، راجع الدرس"]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if questions.isEmpty {
                    Text("ما فيه أسئلة").foregroundColor(.dim)
                } else if finished {
                    resultView
                } else {
                    questionView
                }
            }
            .navigationTitle(store.unit(unitID)?.title ?? "الاختبار")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
            .onAppear { start() }
        }
    }

    private var questionView: some View {
        let q = questions[index]
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("سؤال \(index + 1) من \(questions.count)").font(.footnote.bold()).foregroundColor(.dim)
                    Spacer()
                    Text("النتيجة: \(score)").font(.footnote.bold()).foregroundColor(.dim)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Color.accentBlue)
                            .frame(width: g.size.width * CGFloat(index + (selected == nil ? 0 : 1)) / CGFloat(questions.count))
                    }
                }.frame(height: 6)

                Text(q.text).font(.title3.bold()).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)

                ForEach(order, id: \.self) { i in
                    Button { choose(i, q) } label: {
                        HStack {
                            Text(q.options[i]).font(.body).foregroundColor(.white).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if let s = selected {
                                if i == q.correct { Image(systemName: "checkmark.circle.fill").foregroundColor(.doneGreen) }
                                else if i == s { Image(systemName: "xmark.circle.fill").foregroundColor(.red) }
                            }
                        }
                        .padding(16)
                        .background(optionColor(i, q), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(optionBorder(i, q), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(selected != nil)
                }

                if let s = selected {
                    Text(s == q.correct ? praise[index % praise.count] : retry[index % retry.count])
                        .font(.headline)
                        .foregroundColor(s == q.correct ? .doneGreen : .red)
                    Button { next() } label: {
                        Text(index + 1 == questions.count ? "عرض النتيجة" : "السؤال التالي")
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(Color.accentBlue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(18)
        }
    }

    private var resultView: some View {
        let pct = Int((Double(score) / Double(max(questions.count, 1))) * 100)
        return VStack(spacing: 18) {
            Text(pct >= 80 ? "🏆" : (pct >= 50 ? "👍" : "📚")).font(.system(size: 70))
            Text("\(score) من \(questions.count)").font(.largeTitle.bold()).foregroundColor(.white)
            Text("\(pct)%").font(.title2.bold()).foregroundColor(pct >= 50 ? .doneGreen : .orange)
            Text(pct >= 80 ? "ممتاز! أنت متقن للوحدة" : (pct >= 50 ? "جيد، راجع الأسئلة اللي أخطأت فيها" : "تحتاج مراجعة أكثر للوحدة"))
                .font(.subheadline).foregroundColor(.dim)
            Button { start() } label: {
                Text("إعادة الاختبار").font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.accentBlue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 30).padding(.top, 10)
            Button("إغلاق") { dismiss() }.foregroundColor(.dim)
        }
        .padding()
    }

    private func optionColor(_ i: Int, _ q: QuizQuestion) -> Color {
        guard let s = selected else { return Color.cardBg }
        if i == q.correct { return Color.doneGreen.opacity(0.22) }
        if i == s { return Color.red.opacity(0.22) }
        return Color.cardBg
    }
    private func optionBorder(_ i: Int, _ q: QuizQuestion) -> Color {
        guard let s = selected else { return Color.white.opacity(0.08) }
        if i == q.correct { return .doneGreen }
        if i == s { return .red }
        return Color.white.opacity(0.05)
    }

    private func start() {
        questions = store.questions(of: unitID).shuffled()
        index = 0; score = 0; selected = nil; finished = false
        prepareOrder()
    }
    private func prepareOrder() {
        guard index < questions.count else { return }
        order = Array(questions[index].options.indices).shuffled()
    }
    private func choose(_ i: Int, _ q: QuizQuestion) {
        selected = i
        if i == q.correct { score += 1; UINotificationFeedbackGenerator().notificationOccurred(.success) }
        else { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    }
    private func next() {
        if index + 1 >= questions.count { finished = true }
        else { index += 1; selected = nil; prepareOrder() }
    }
}
