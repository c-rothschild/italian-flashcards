import AVFoundation
import SwiftUI

struct CategoriesView: View {
    @Environment(TermRepository.self) private var repository
    @Environment(CategorySelection.self) private var selection
    @Environment(Speaker.self) private var speaker

    var body: some View {
        NavigationStack {
            List {
                cloudSection
                categorySection
                voiceSection
            }
            .navigationTitle("Categories")
            .refreshable { await repository.refresh() }
        }
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
