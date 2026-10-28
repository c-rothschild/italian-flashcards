import AVFoundation
import SwiftUI

struct CategoriesView: View {
    @Environment(TermRepository.self) private var repository
    @Environment(CategorySelection.self) private var selection
    @Environment(Speaker.self) private var speaker
    @Environment(ProgressStore.self) private var progress
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            List {
                cloudSection
                progressSection
                categorySection
                voiceSection
            }
            .navigationTitle("Categories")
            .refreshable {
                async let cards: Void = repository.refresh()
                async let studied: Void = progress.sync()
                _ = await (cards, studied)
            }
            .sheet(isPresented: $connecting) { ConnectGitHubView() }
        }
    }

    private var progressSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(progress.masteredCount) mastered").font(.headline)
                    Text(progressStatus).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if progress.isSyncing { ProgressView() }
            }
            if let error = progress.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if progress.hasToken {
                Button("Disconnect GitHub", role: .destructive) { progress.disconnect() }
            } else {
                Button("Connect GitHub…", systemImage: "link") { connecting = true }
            }
        } header: {
            Text("Learn progress")
        } footer: {
            Text(progress.hasToken
                 ? "Words you learn here and on the website stay in sync."
                 : "Progress from the website shows up here. To send what you learn on this iPhone back to the website, connect GitHub.")
        }
    }

    private var progressStatus: String {
        if progress.hasUnsavedChanges { return "Saving…" }
        if let date = progress.lastSynced {
            return "Synced \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Not synced yet"
    }

    private var cloudSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(repository.terms.count) cards").font(.headline)
                    Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if repository.isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await repository.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Check for new cards")
                }
            }
            if let error = repository.errorMessage {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let change = repository.lastChange {
                Label(change, systemImage: "sparkles").font(.footnote)
            }
        } header: {
            Text("Flashcards")
        } footer: {
            Text("Cards you edit on the website are pushed to GitHub, and this app downloads them. Pull down to check for new cards.")
        }
    }

    private var statusLine: String {
        if let date = repository.lastUpdated {
            return "Up to date as of \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return repository.source == .bundled ? "Using the cards built into the app" : "Using the cards saved on this device"
    }

    private var categorySection: some View {
        Section {
            ForEach(repository.categories, id: \.self) { category in
                Toggle(isOn: Binding(
                    get: { selection.isSelected(category) },
                    set: { selection.set(category, selected: $0) }
                )) {
                    HStack {
                        Text(Term.label(for: category))
                        Spacer()
                        Text("\(repository.count(of: category))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            HStack {
                Text("Study these categories")
                Spacer()
                Button("All") { selection.selectAll() }
                Text("·").foregroundStyle(.secondary)
                Button("None") { selection.selectNone(repository.categories) }
            }
            .font(.footnote.weight(.semibold))
        } footer: {
            let n = selection.pool(from: repository.terms).count
            Text("\(n) card\(n == 1 ? "" : "s") selected for Flashcards and Learn.")
        }
    }

    private var voiceSection: some View {
        Section {
            if speaker.voices.isEmpty {
                Text("No Italian voice is installed.").foregroundStyle(.secondary)
            } else {
                Picker("Italian voice", selection: Binding(
                    get: { speaker.selectedVoice?.identifier },
                    set: { speaker.selectVoice($0) }
                )) {
                    ForEach(speaker.voices, id: \.identifier) { voice in
                        Text(Self.name(of: voice)).tag(Optional(voice.identifier))
                    }
                }
            }
            Button("Test voice", systemImage: "speaker.wave.2") { speaker.speak("Ciao! Come stai?") }
        } header: {
            Text("Pronunciation")
        } footer: {
            Text("For a more natural voice, download an Enhanced or Premium Italian voice in Settings › Accessibility › Spoken Content › Voices › Italian.")
        }
        .onAppear { speaker.loadVoices() }
    }

    private static func name(of voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        default: voice.name
        }
    }
}

/// Asks for a fine-grained GitHub token that can write to the flashcards repo.
private struct ConnectGitHubView: View {
    @Environment(ProgressStore.self) private var progress
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    // Pre-fills the name and the Contents permission on GitHub's "new token" page.
    private static let newTokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new?name=Italiano%20app%20progress&description=Lets%20the%20Italiano%20iPhone%20app%20save%20learn%20progress&contents=write")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("To save what you learn on this iPhone, the app needs a GitHub token that can write to **\(CloudConfig.repo)**. The token is kept in this iPhone's Keychain.")
                    Link(destination: Self.newTokenURL) {
                        Label("Create a token on GitHub", systemImage: "arrow.up.right.square")
                    }
                } footer: {
                    Text("On GitHub: under Repository access, choose Only select repositories › \(CloudConfig.repo). Under Permissions, set Contents to Read and write. Then tap Generate token and copy it.")
                }
                Section("Token") {
                    SecureField("github_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Connect", action: connect).disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func connect() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            let problem = await progress.connect(token: token)
            working = false
            if let problem, !progress.hasToken { error = problem } else { dismiss() }
        }
    }
}
