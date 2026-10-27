import AVFoundation
import Observation
import SwiftUI

/// Reads Italian aloud with the device's text-to-speech voices.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var voices: [AVSpeechSynthesisVoice] = []
    private(set) var speakingText: String?
    private(set) var voiceID: String? = UserDefaults.standard.string(forKey: "speech.voice")

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var current: AVSpeechUtterance?
    @ObservationIgnored private var sessionReady = false
    @ObservationIgnored private var fallbackVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
        loadVoices()
    }

    func selectVoice(_ id: String?) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: "speech.voice")
    }

    var selectedVoice: AVSpeechSynthesisVoice? {
        voices.first { $0.identifier == voiceID } ?? voices.first
    }

    /// Loads the Italian voices, best quality first (Premium, then Enhanced, then default).
    /// Runs off the main thread: the voice lookup waits on the main thread internally and
    /// deadlocks the app if called from it.
    func loadVoices() {
        Task.detached(priority: .userInitiated) {
            func rank(_ v: AVSpeechSynthesisVoice) -> Int {
                switch v.quality {
                case .premium: 3
                case .enhanced: 2
                default: v.language == "it-IT" ? 1 : 0
                }
            }
            let italian = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("it") }
                .sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name }
            let fallback = AVSpeechSynthesisVoice(language: "it-IT")
            await MainActor.run {
                self.voices = italian
                self.fallbackVoice = fallback
            }
        }
    }

    func speak(_ text: String) {
        let clean = text.regexReplace("\\.{2,}|…", " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if !sessionReady {
            // .playback so it still speaks with the ring/silent switch on silent.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            sessionReady = true
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = selectedVoice ?? fallbackVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        current = utterance
        speakingText = text
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    private func finished(_ id: ObjectIdentifier) {
        // Ignore the old utterance being cancelled when a new one starts.
        guard let current, ObjectIdentifier(current) == id else { return }
        self.current = nil
        speakingText = nil
    }
}

/// Round speaker button that pronounces `text` (and lights up while speaking).
struct SpeakButton: View {
    @Environment(Speaker.self) private var speaker
    let text: String
    var size: CGFloat = 44

    var body: some View {
        let active = speaker.speakingText == text
        Button {
            speaker.speak(text)
        } label: {
            Image(systemName: active ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Color.white : Color.accentColor)
                .background(active ? Color.accentColor : Color.accentColor.opacity(0.13), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pronounce \(text)")
    }
}
