import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

/// Apps dont l'utilisation du micro signale un appel en cours.
let callBundleIDs: Set<String> = [
    "com.apple.mobilephone",          // Téléphone
    "com.apple.FaceTime",
    "com.apple.avconferenced",        // moteur audio des appels Continuité / FaceTime
    "com.apple.telephonyutilities.callservicesd",
]

/// Navigateurs (Google Meet…) et apps de visio : un appel quand ils utilisent le micro.
let meetingBundlePrefixes = [
    "com.google.Chrome", "company.thebrowser", "com.apple.WebKit", "com.apple.Safari", "org.mozilla.firefox",
    "com.microsoft.edgemac", "com.brave.Browser", "us.zoom", "com.microsoft.teams", "net.whatsapp",
    "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.skype",
]

func isCallProcess(_ p: AudioProcess, includingMeetings: Bool = true) -> Bool {
    guard p.pid != ProcessInfo.processInfo.processIdentifier, p.usesInput else { return false }
    if callBundleIDs.contains(p.bundleID) || ["avconferenced", "callservicesd"].contains(p.name) { return true }
    return includingMeetings && meetingBundlePrefixes.contains { p.bundleID.hasPrefix($0) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var elapsed = ""
    @Published var message: String?
    @Published var lastRecording: URL?
    @Published var lastTranscript: URL?
    @Published var transcriptionsRunning = 0
    @Published var autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    @Published var askWorkCall = UserDefaults.standard.object(forKey: "askWorkCall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(askWorkCall, forKey: "askWorkCall") }
    }
    @Published var detectMeetings = UserDefaults.standard.object(forKey: "detectMeetings") as? Bool ?? true {
        didSet { UserDefaults.standard.set(detectMeetings, forKey: "detectMeetings") }
    }
    @Published var autoRecord = UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "autoRecord") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var language = Language.current {
        didSet { Language.current = language }
    }

    private let recorder = CallRecorder()
    private var startedAutomatically = false
    private var startDate = Date()
    private var quietTicks = 0
    private var wasInCall = false
    private var timer: Timer?

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func start(automatically: Bool = false) {
        guard !isRecording, !isSaving else { return }
        do {
            try recorder.start()
            isRecording = true
            startedAutomatically = automatically
            startDate = Date()
            quietTicks = 0
            message = nil
            tick()
        } catch {
            message = L("Impossible de démarrer : ", "Couldn't start: ") + error.localizedDescription
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isSaving = true
        // Un micro ouvert quelques secondes (note vocale, test) n'est pas un appel : on ne garde rien.
        let tooShort = startedAutomatically && Date().timeIntervalSince(startDate) < 15
        Task {
            do {
                let recording = try await recorder.stop()
                if tooShort {
                    try? FileManager.default.removeItem(at: recording.audio)
                    recording.discardTracks()
                    isSaving = false
                    return
                }
                lastRecording = recording.audio
                message = nil
                isSaving = false
                if autoTranscribe && Transcriber.isAvailable {
                    await transcribe(recording)
                } else {
                    recording.discardTracks()
                }
            } catch {
                message = L("Erreur à l'enregistrement : ", "Couldn't save the recording: ") + error.localizedDescription
                isSaving = false
            }
        }
    }

    private func transcribe(_ recording: Recording) async {
        // La question « pour le boulot ? » s'affiche tout de suite, pendant que la transcription tourne.
        let decision = Task { askWorkCall && WorkCall.isAvailable ? await WorkCallPanel().ask() : nil }
        transcriptionsRunning += 1
        do {
            let transcript = try await Transcriber.transcribe(recording)
            lastTranscript = transcript
            recording.discardTracks()
            transcriptionsRunning -= 1
            if let note = await decision.value {
                sendToClaude(transcript: transcript, audio: recording.audio, note: note)
            }
        } catch {
            // Les pistes restent dans le dossier temporaire ; l'audio mixé, lui, est bien enregistré.
            transcriptionsRunning -= 1
            message = L("Transcription impossible : ", "Transcription failed: ") + error.localizedDescription
        }
    }

    /// Pose la question pour le dernier appel (si on a raté la fenêtre).
    func askAgainForLastCall() {
        guard let transcript = lastTranscript, let audio = lastRecording else { return }
        Task {
            if let note = await WorkCallPanel().ask() { sendToClaude(transcript: transcript, audio: audio, note: note) }
        }
    }

    private func sendToClaude(transcript: URL, audio: URL, note: String) {
        do {
            try WorkCall.process(transcript: transcript, audio: audio, note: note)
        } catch {
            message = L("Impossible d'ouvrir Claude : ", "Couldn't open Claude: ") + error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = L("Lancement au démarrage : ", "Launch at login: ") + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func tick() {
        if isRecording {
            let s = Int(Date().timeIntervalSince(startDate))
            elapsed = String(format: "%02d:%02d", s / 60, s % 60)
        }
        guard autoRecord || startedAutomatically else { return }
        let inCall = AudioProcess.all().contains { isCallProcess($0, includingMeetings: detectMeetings) }
        defer { wasInCall = inCall }
        if inCall {
            quietTicks = 0
            // Seulement au début de l'appel : si tu arrêtes à la main, ça ne relance pas.
            if !wasInCall && !isRecording && autoRecord { start(automatically: true) }
        } else if isRecording && startedAutomatically {
            quietTicks += 1
            if quietTicks >= 3 { stop() } // l'appel est fini depuis 3 s
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Text(L("● Enregistrement en cours — ", "● Recording — ") + model.elapsed)
            Button(L("Arrêter l'enregistrement", "Stop recording")) { model.stop() }
                .keyboardShortcut("s")
        } else if model.isSaving {
            Text(L("Enregistrement du fichier…", "Saving file…"))
        } else {
            Button(L("Enregistrer maintenant", "Record now")) { model.start() }
                .keyboardShortcut("r")
        }
        if model.transcriptionsRunning > 0 { Text(L("Transcription en cours…", "Transcribing…")) }
        if let message = model.message { Text(message) }

        Divider()
        Toggle(L("Enregistrer automatiquement les appels", "Record calls automatically"), isOn: $model.autoRecord)
        Toggle(L("Inclure les visios (Meet, Zoom, Teams, WhatsApp…)", "Include video calls (Meet, Zoom, Teams, WhatsApp…)"),
               isOn: $model.detectMeetings)
            .disabled(!model.autoRecord)
        if Transcriber.isAvailable {
            Toggle(L("Transcrire chaque appel", "Transcribe every call"), isOn: $model.autoTranscribe)
            if WorkCall.isAvailable {
                Toggle(L("Demander si c'est pour le boulot", "Ask if it was a work call"), isOn: $model.askWorkCall)
                    .disabled(!model.autoTranscribe)
            }
        } else {
            Text(L("Transcription : installe whisper-cpp et son modèle", "Transcription: install whisper-cpp and its model"))
        }
        Toggle(L("Lancer à l'ouverture de session", "Launch at login"), isOn: Binding(
            get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Picker(L("Langue", "Language"), selection: $model.language) {
            ForEach(Language.allCases) { Text($0.label).tag($0) }
        }

        Divider()
        if let last = model.lastRecording {
            Button(L("Écouter le dernier appel", "Play last call")) { NSWorkspace.shared.open(last) }
        }
        if let transcript = model.lastTranscript {
            Button(L("Lire la dernière transcription", "Open last transcript")) { NSWorkspace.shared.open(transcript) }
            if WorkCall.isAvailable {
                Button(L("Envoyer le dernier appel à Claude…", "Send last call to Claude…")) { model.askAgainForLastCall() }
            }
        }
        Button(L("Ouvrir le dossier des appels", "Open recordings folder")) {
            try? FileManager.default.createDirectory(at: CallRecorder.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CallRecorder.folder)
        }
        Text(L("Pense à prévenir ton correspondant.", "Remember to tell the other person."))
        Divider()
        Button(L("Quitter", "Quit")) { model.stop(); NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct EnregistreurAppelsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
                Text(model.elapsed)
            } else {
                Image(systemName: model.isSaving ? "hourglass" : "phone.circle")
            }
        }
    }
}

@main
enum Main {
    static func main() {
        // `--processus` : liste ce qui utilise l'audio (utile pendant un appel pour régler la détection).
        if CommandLine.arguments.contains("--processus") {
            for p in AudioProcess.all() where p.usesInput || p.usesOutput {
                let flags = (p.usesInput ? "micro " : "") + (p.usesOutput ? "son" : "")
                print("\(isCallProcess(p) ? "APPEL " : "      ")\(p.pid)\t\(p.name)\t\(p.bundleID)\t\(flags)")
            }
            return
        }
        // `--claude fichier.txt "descriptif"` : envoie une transcription existante à Claude, sans passer par la fenêtre.
        if let i = CommandLine.arguments.firstIndex(of: "--claude") {
            let args = Array(CommandLine.arguments.dropFirst(i + 1))
            guard let path = args.first else { print("Usage : --claude fichier.txt \"descriptif\""); return }
            let transcript = URL(fileURLWithPath: path)
            do {
                try WorkCall.process(transcript: transcript, audio: transcript.deletingPathExtension().appendingPathExtension("m4a"),
                                     note: args.dropFirst().first ?? "")
            } catch {
                print("ERREUR \(error.localizedDescription)")
            }
            return
        }
        // `--test N` : enregistre N secondes puis affiche le fichier produit.
        if let i = CommandLine.arguments.firstIndex(of: "--test") {
            let seconds = Double(CommandLine.arguments.dropFirst(i + 1).first ?? "") ?? 5
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let recorder = CallRecorder()
                do {
                    try recorder.start()
                    try await Task.sleep(for: .seconds(seconds))
                    print(recorder.diagnostic)
                    let recording = try await recorder.stop()
                    print("OK \(recording.audio.path)")
                    if Transcriber.isAvailable {
                        print("TXT \(try await Transcriber.transcribe(recording).path)")
                        recording.discardTracks()
                    }
                } catch {
                    print("ERREUR \(error.localizedDescription)")
                }
                done.signal()
            }
            done.wait()
            return
        }
        EnregistreurAppelsApp.main()
    }
}
