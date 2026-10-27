import SwiftUI

struct FlashcardsView: View {
    @Environment(TermRepository.self) private var repository
    @Environment(CategorySelection.self) private var selection
    @AppStorage("cards.front") private var front: CardSide = .term
    @AppStorage("cards.shuffle") private var shuffle = false
    @State private var order: [String] = [] // card ids in study order
    @State private var index = 0
    @State private var flipped = false
    let openCategories: () -> Void

    private var pool: [Term] { selection.pool(from: repository.terms) }

    private var deck: [Term] {
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    var body: some View {
        let deck = deck
        NavigationStack {
            VStack(spacing: 14) {
                if deck.isEmpty {
                    ContentUnavailableView {
                        Label("No cards selected", systemImage: "rectangle.on.rectangle.slash")
                    } description: {
                        Text("Choose one or more categories to study.")
                    } actions: {
                        Button("Choose Categories", action: openCategories)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView(value: Double(min(index + 1, deck.count)), total: Double(deck.count))
                        .padding(.horizontal)

                    TabView(selection: $index) {
                        ForEach(Array(deck.enumerated()), id: \.element.id) { i, term in
                            FlashcardView(term: term, front: front, flipped: flipped && i == index) {
                                withAnimation(.spring(duration: 0.45)) { flipped.toggle() }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    HStack {
                        Button { go(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .disabled(index == 0)
                            .accessibilityLabel("Previous card")
                        Spacer()
                        Text("\(min(index + 1, deck.count)) / \(deck.count)")
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Button { go(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .disabled(index >= deck.count - 1)
                            .accessibilityLabel("Next card")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .padding(.horizontal, 28)

                    Text("Tap to flip · swipe for the next card")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Flashcards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SelectionButton(action: openCategories) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show first", selection: $front) {
                            Text("Italian first").tag(CardSide.term)
                            Text("English first").tag(CardSide.definition)
                        }
                        Toggle("Shuffle", systemImage: "shuffle", isOn: $shuffle)
                        Button("Start over", systemImage: "arrow.counterclockwise") { rebuild(reset: true) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Card options")
                }
            }
        }
        .onAppear { if order.isEmpty { rebuild(reset: true) } }
        .onChange(of: selection.deselected) { rebuild(reset: true) }
        .onChange(of: shuffle) { rebuild(reset: true) }
        .onChange(of: front) { flipped = false }
        .onChange(of: repository.terms) { rebuild(reset: false) }
        .onChange(of: index) { flipped = false }
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < deck.count else { return }
        withAnimation { index = next }
    }

    /// Rebuilds the study order. `reset` starts over from the first card; otherwise
    /// (after a cloud update) it keeps the order and the current card where possible.
    private func rebuild(reset: Bool) {
        let ids = pool.map(\.id)
        let currentDeck = deck
        let currentID = currentDeck.indices.contains(index) ? currentDeck[index].id : nil
        if reset || order.isEmpty {
            order = shuffle ? ids.shuffled() : ids
        } else if shuffle {
            let available = Set(ids)
            let kept = order.filter(available.contains)
            let keptSet = Set(kept)
            order = kept + ids.filter { !keptSet.contains($0) }.shuffled()
        } else {
            order = ids
        }
        if !reset, let currentID, let i = order.firstIndex(of: currentID) {
            index = i
        } else {
            index = reset ? 0 : min(index, max(0, order.count - 1))
            flipped = false
        }
    }
}

/// A card that flips in 3D. The Italian side has a pronunciation button.
struct FlashcardView: View {
    let term: Term
    let front: CardSide
    let flipped: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            CardFace(term: term, side: front)
                .modifier(FlipVisibility(progress: flipped ? 1 : 0, isFront: true))
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            CardFace(term: term, side: front.opposite)
                .modifier(FlipVisibility(progress: flipped ? 1 : 0, isFront: false))
                .rotation3DEffect(.degrees(flipped ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        }
        .frame(maxWidth: 560, maxHeight: 480)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Flip", onTap)
    }
}

/// Swaps which face is visible exactly halfway through the flip animation.
private struct FlipVisibility: ViewModifier, Animatable {
    var progress: Double
    let isFront: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let visible = isFront ? progress < 0.5 : progress >= 0.5
        content
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
    }
}

private struct CardFace: View {
    let term: Term
    let side: CardSide

    var body: some View {
        let text = side.text(of: term)
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
            .overlay {
                Text(text)
                    .font(.system(size: text.count > 40 ? 26 : 38, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 64)
            }
            .overlay(alignment: .topLeading) {
                Text(side == .term ? "ITALIANO" : "ENGLISH")
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
            .overlay(alignment: .topTrailing) {
                if side == .term { SpeakButton(text: term.term).padding(14) }
            }
            .overlay(alignment: .bottom) {
                Text(term.categoryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .padding(16)
            }
    }
}
