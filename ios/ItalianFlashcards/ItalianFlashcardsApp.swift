import SwiftUI

@main
struct ItalianFlashcardsApp: App {
    @State private var repository = TermRepository()
    @State private var selection = CategorySelection()
    @State private var speaker = Speaker()
    @State private var progress = Self.makeProgressStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(repository)
                .environment(selection)
                .environment(speaker)
                .environment(progress)
                .task { await repository.refresh() }
                .task(id: scenePhase) {
                    // While the app is open, check for progress made on the website now and then.
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await progress.sync()
                        try? await Task.sleep(for: .seconds(progress.hasToken ? 30 : 120))
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up cards edited on the website while the app was in the background.
                    if phase == .active { Task { await repository.refreshIfStale() } }
                    // Save progress before iOS suspends the app.
                    if phase == .background, progress.hasUnsavedChanges { saveInBackground() }
                }
        }
    }

    /// UI tests start from no progress and stay offline so they don't depend on (or change) real progress.
    private static func makeProgressStore() -> ProgressStore {
        guard ProcessInfo.processInfo.arguments.contains("-UITestFreshProgress") else { return ProgressStore() }
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return ProgressStore(directory: dir, syncEnabled: false)
    }

    private func saveInBackground() {
        let id = UIApplication.shared.beginBackgroundTask(withName: "Save progress")
        Task {
            await progress.sync()
            UIApplication.shared.endBackgroundTask(id)
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
