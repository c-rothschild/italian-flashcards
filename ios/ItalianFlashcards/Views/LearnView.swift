import SwiftUI

struct LearnView: View {
    @Environment(TermRepository.self) private var repository
    @Environment(CategorySelection.self) private var selection
    @Environment(Speaker.self) private var speaker
    @AppStorage("learn.answerWith") private var answerMode: AnswerMode = .term
    @AppStorage("learn.autoAudio") private var autoAudio = false
    @State private var session: LearnSession?
    @State private var input = ""
    @State private var retypeError = false
    @State private var shakes = 0
    @State private var autoAdvance: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
    let openCategories: () -> Void

    private static let accents = ["à", "è", "é", "ì", "ò", "ù"]
    private static let praise = ["Great job!", "Correct!", "Perfetto!", "Bravo!", "Esatto!"]

    var body: some View {
        NavigationStack {
            Group {
                if let session, !session.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ProgressHeader(session: session)
                            switch session.phase {
                            case .asking, .correct, .wrong: questionCard(session)
                            case .summary: summaryCard(session)
                            case .done: doneCard(session)
                            }
                        }
                        .padding()
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else {
                    ContentUnavailableView {
                        Label("Nothing to learn yet", systemImage: "pencil.line")
                    } description: {
                        Text("Choose one or more categories to study.")
                    } actions: {
                        Button("Choose Categories", action: openCategories).buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Learn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SelectionButton(action: openCategories) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Answer with", selection: $answerMode) {
                            ForEach(AnswerMode.allCases) { Text("Answer in \($0.label)").tag($0) }
                        }
                        Toggle("Auto-play audio", systemImage: "speaker.wave.2", isOn: $autoAudio)
                        Button("Start over", systemImage: "arrow.counterclockwise") { startNew() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Learn options")
                }
            }
        }
        .onAppear { if session == nil { startNew() } }
        .onChange(of: selection.deselected) { startNew() }
        .onChange(of: repository.terms) {
            guard let session else { startNew(); return }
            let wasAsking = session.question?.id
            session.reconcile(with: repository.terms, isSelected: selection.isSelected)
            if session.isEmpty { startNew() } else if session.question?.id != wasAsking { afterAdvance() }
        }
        .onChange(of: answerMode) {
            guard let session else { return }
            session.answerMode = answerMode
            if session.phase == .asking {
                session.askCurrent()
                questionShown()
            }
        }
    }

    // MARK: cards

    @ViewBuilder
    private func questionCard(_ s: LearnSession) -> some View {
        if let q = s.question, let item = s.currentItem {
            let promptSide = q.answerSide.opposite
            let answerItalian = q.answerSide == .term
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(promptSide == .term ? "ITALIANO" : "ENGLISH")
                        .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.term.categoryLabel)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                HStack(spacing: 12) {
                    Text(promptSide.text(of: item.term))
                        .font(.title.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if promptSide == .term { SpeakButton(text: item.term.term, size: 38) }
                }
                .frame(minHeight: 70, alignment: .leading)

                if s.phase == .correct { correctFeedback(q, item) }
                if s.phase == .wrong { wrongFeedback(s, q, item) }

                Text(s.phase == .wrong ? "Type the correct answer to continue" : "Your answer (\(q.answerSide.languageName))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField(s.phase == .wrong ? "Type the correct answer" : "Type the \(q.answerSide.languageName)", text: fieldBinding(s, q))
                    .font(.title3)
                    .padding(12)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(retypeError ? Color.red : (fieldFocused ? Color.accentColor : Color(.separator)), lineWidth: 2))
                    .modifier(Shake(animatableData: CGFloat(shakes)))
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(s.phase == .correct ? .next : .done)
                    .onSubmit { submitPressed(s) }

                if answerItalian && s.phase != .correct {
                    HStack(spacing: 8) {
                        ForEach(Self.accents, id: \.self) { ch in
                            Button(ch) { input.append(ch) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Insert \(ch)")
                        }
                    }
                }

                if retypeError {
                    Text("That doesn't match yet. Copy the answer above.")
                        .font(.footnote).foregroundStyle(.red)
                }

                HStack {
                    switch s.phase {
                    case .asking:
                        Button("Don't know?") { giveUp(s) }
                        Spacer()
                        Button("Answer") { submitPressed(s) }.buttonStyle(.borderedProminent)
                    case .wrong:
                        Spacer()
                        Button("Check") { submitPressed(s) }.buttonStyle(.borderedProminent)
                    default:
                        Text("Press return to continue").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Continue") { advance(s) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// The text field doubles as the "continue" target after a correct answer, so the
    /// keyboard stays up and Return moves on. It shows what you typed and ignores edits.
    private func fieldBinding(_ s: LearnSession, _ q: LearnSession.Question) -> Binding<String> {
        Binding(
            get: { s.phase == .correct ? (q.given ?? "") : input },
            set: { newValue in
                // Refocusing writes the same text back; only a real edit clears the error.
                guard s.phase != .correct, newValue != input else { return }
                input = newValue
                retypeError = false
            }
        )
    }

    private func correctFeedback(_ q: LearnSession.Question, _ item: LearnSession.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(q.grade == .accent ? "Correct, but watch the accents!" : Self.praise[abs(q.id.hashValue) % Self.praise.count])
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            answerLine(label: AnswerGrader.normalize(q.given ?? "") == AnswerGrader.normalize(q.answerSide.text(of: item.term)) ? nil : "Answer:", q: q, item: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func wrongFeedback(_ s: LearnSession, _ q: LearnSession.Question, _ item: LearnSession.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(q.given == nil ? "No problem. Here's the answer, and you'll see it again." : "Not quite. You'll see this one again.")
                .font(.headline)
                .foregroundStyle(.red)
            if let given = q.given {
                HStack(alignment: .firstTextBaseline) {
                    Text("You said:").foregroundStyle(.secondary)
                    Text(given).strikethrough().foregroundStyle(.red)
                    Spacer(minLength: 8)
                }
                Button("Override: I was right") { override(s) }
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.semibold))
            }
            answerLine(label: "Correct answer:", q: q, item: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func answerLine(label: String?, q: LearnSession.Question, item: LearnSession.Item) -> some View {
        HStack(spacing: 8) {
            if let label { Text(label).foregroundStyle(.secondary) }
            Text(q.answerSide.text(of: item.term)).font(.title3.weight(.bold))
                .accessibilityIdentifier("expectedAnswer")
            if q.answerSide == .term { SpeakButton(text: item.term.term, size: 32) }
        }
    }

    private func summaryCard(_ s: LearnSession) -> some View {
        let results = s.roundResults
        let right = results.filter(\.correct).count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Round \(s.round?.number ?? 1) done: \(right) of \(results.count) correct")
                .font(.title2.weight(.bold))
            Text("You've mastered \(s.masteredCount) of \(s.total) terms. Keep going!")
                .foregroundStyle(.secondary)
            ResultList(rows: results.map { ($0.item, $0.correct, nil) })
            Button {
                s.continueAfterSummary()
                afterAdvance()
            } label: {
                Text("Continue to next round").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func doneCard(_ s: LearnSession) -> some View {
        let missed = s.mostMissed
        let pct = s.total == 0 ? 0 : Int((Double(s.firstTryCount) / Double(s.total) * 100).rounded())
        return VStack(alignment: .leading, spacing: 12) {
            Text(s.missedOnly ? "You've got the tricky ones now! 🎉" : "You've learned all \(s.total) terms! 🎉")
                .font(.title2.weight(.bold))
            Text("\(s.firstTryCount) of \(s.total) right on the first try (\(pct)%).")
                .foregroundStyle(.secondary)
            if missed.isEmpty {
                Text("A perfect run: nothing missed.")
            } else {
                Text("Most missed").font(.headline).padding(.top, 4)
                ResultList(rows: missed.prefix(12).map { ($0, false, "missed \($0.misses)×") })
                Button {
                    session = LearnSession(terms: missed.map(\.term), answerMode: answerMode, missedOnly: true)
                    afterAdvance()
                } label: {
                    Text("Practice the \(missed.count) I missed").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button {
                startNew()
            } label: {
                Text("Learn again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: actions

    private func startNew() {
        autoAdvance?.cancel()
        let pool = selection.pool(from: repository.terms)
        session = pool.isEmpty ? nil : LearnSession(terms: pool, answerMode: answerMode)
        afterAdvance()
    }

    private func submitPressed(_ s: LearnSession) {
        switch s.phase {
        case .asking:
            let isEmpty = input.trimmingCharacters(in: .whitespaces).isEmpty
            let grade = s.submit(input) // empty = "Don't know"
            answerRevealed(s)
            if !isEmpty, grade == .correct { scheduleAutoAdvance(s) }
            if s.phase == .wrong { input = "" }
            fieldFocused = true
        case .wrong:
            // Return dismisses the keyboard by default; keep it up until the answer is retyped.
            guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { shake(); fieldFocused = true; return }
            if s.checkRetype(input) {
                afterAdvance()
            } else {
                retypeError = true
                shake()
                fieldFocused = true
            }
        case .correct:
            advance(s)
        default:
            break
        }
    }

    private func giveUp(_ s: LearnSession) {
        s.giveUp()
        input = ""
        answerRevealed(s)
        fieldFocused = true
    }

    private func override(_ s: LearnSession) {
        s.overrideCorrect()
        afterAdvance()
    }

    private func advance(_ s: LearnSession) {
        autoAdvance?.cancel()
        s.next()
        afterAdvance()
    }

    /// Quizlet-style: move on by itself after a clean correct answer.
    private func scheduleAutoAdvance(_ s: LearnSession) {
        autoAdvance?.cancel()
        let id = s.question?.id
        autoAdvance = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, s.phase == .correct, s.question?.id == id else { return }
            advance(s)
        }
    }

    private func afterAdvance() {
        input = ""
        retypeError = false
        if session?.phase == .asking {
            questionShown()
        } else {
            fieldFocused = false
        }
    }

    private func questionShown() {
        input = ""
        retypeError = false
        fieldFocused = true
        if autoAudio, let s = session, let q = s.question, q.answerSide == .definition, let item = s.currentItem {
            speaker.speak(item.term.term)
        }
    }

    private func answerRevealed(_ s: LearnSession) {
        if autoAudio, let q = s.question, q.answerSide == .term, let item = s.currentItem {
            speaker.speak(item.term.term)
        }
    }

    private func shake() {
        withAnimation(.default) { shakes += 1 }
    }
}

private struct ProgressHeader: View {
    let session: LearnSession

    var body: some View {
        let total = max(session.total, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(session.masteredCount) / CGFloat(total))
                    Rectangle().fill(Color.orange)
                        .frame(width: geo.size.width * CGFloat(session.learningCount) / CGFloat(total))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Color(.systemFill))
            .clipShape(Capsule())
            .animation(.easeOut, value: session.masteredCount)

            HStack(spacing: 14) {
                stat(Color.accentColor, "\(session.masteredCount) mastered")
                stat(.orange, "\(session.learningCount) learning")
                stat(Color(.systemFill), "\(session.newCount) new")
                Spacer()
                if let round = session.round, session.phase != .done {
                    Text("Round \(round.number)").font(.caption.weight(.semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func stat(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

private struct ResultList: View {
    let rows: [(item: LearnSession.Item, correct: Bool, note: String?)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: row.correct ? "checkmark" : "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(row.correct ? Color.accentColor : .red)
                        .frame(width: 16)
                    Text(row.item.term.term).fontWeight(.semibold)
                    Text(row.item.term.definition).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let note = row.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }
}

/// Horizontal shake for a wrong retype.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 4), y: 0))
    }
}
