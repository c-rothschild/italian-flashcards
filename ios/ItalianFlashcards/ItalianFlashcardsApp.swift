import SwiftUI

@main
struct ItalianFlashcardsApp: App {
    @State private var repository = TermRepository()
    @State private var selection = CategorySelection()
    @State private var speaker = Speaker()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(repository)
                .environment(selection)
                .environment(speaker)
                .task { await repository.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up cards edited on the website while the app was in the background.
                    if phase == .active { Task { await repository.refreshIfStale() } }
                }
        }
    }
}

enum AppTab: Hashable { case flashcards, learn, categories }

struct RootView: View {
    @State private var tab: AppTab = .flashcards

    var body: some View {
        TabView(selection: $tab) {
            FlashcardsView(openCategories: { tab = .categories })
                .tabItem { Label("Flashcards", systemImage: "rectangle.on.rectangle.angled") }
                .tag(AppTab.flashcards)
            LearnView(openCategories: { tab = .categories })
                .tabItem { Label("Learn", systemImage: "pencil.line") }
                .tag(AppTab.learn)
            CategoriesView()
                .tabItem { Label("Categories", systemImage: "list.bullet") }
                .tag(AppTab.categories)
        }
    }
}

/// Toolbar button showing how many cards are selected; opens the Categories tab.
struct SelectionButton: View {
    @Environment(TermRepository.self) private var repository
    @Environment(CategorySelection.self) private var selection
    let action: () -> Void

    var body: some View {
        let count = selection.pool(from: repository.terms).count
        Button(action: action) {
            Label("\(count) cards", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("\(count) cards selected. Choose categories.")
    }
}
