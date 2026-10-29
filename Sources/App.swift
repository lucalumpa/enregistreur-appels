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

func isCallProcess(_ p: AudioProcess) -> Bool {
    p.pid != ProcessInfo.processInfo.processIdentifier && p.usesInput
        && (callBundleIDs.contains(p.bundleID) || ["avconferenced", "callservicesd"].contains(p.name))
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
    @Published var autoRecord = UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "autoRecord") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

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
            message = "Impossible de démarrer : \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isSaving = true
        Task {
            do {
                let recording = try await recorder.stop()
                lastRecording = recording.audio
                message = nil
                isSaving = false
                if autoTranscribe && Transcriber.isAvailable {
                    await transcribe(recording)
                } else {
                    recording.discardTracks()
                }
            } catch {
                message = "Erreur à l'enregistrement : \(error.localizedDescription)"
                isSaving = false
            }
        }
    }

    private func transcribe(_ recording: Recording) async {
        transcriptionsRunning += 1
        defer { transcriptionsRunning -= 1 }
        do {
            lastTranscript = try await Transcriber.transcribe(recording)
            recording.discardTracks()
        } catch {
            // Les pistes restent dans le dossier temporaire ; l'audio mixé, lui, est bien enregistré.
            message = "Transcription impossible : \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Lancement au démarrage : \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func tick() {
        if isRecording {
            let s = Int(Date().timeIntervalSince(startDate))
            elapsed = String(format: "%02d:%02d", s / 60, s % 60)
        }
        guard autoRecord || startedAutomatically else { return }
        let inCall = AudioProcess.all().contains(where: isCallProcess)
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
            Text("● Enregistrement en cours — \(model.elapsed)")
            Button("Arrêter l'enregistrement") { model.stop() }
                .keyboardShortcut("s")
        } else if model.isSaving {
            Text("Enregistrement du fichier…")
        } else {
            Button("Enregistrer maintenant") { model.start() }
                .keyboardShortcut("r")
        }
        if model.transcriptionsRunning > 0 { Text("Transcription en cours…") }
        if let message = model.message { Text(message) }

        Divider()
        Toggle("Enregistrer automatiquement les appels", isOn: $model.autoRecord)
        if Transcriber.isAvailable {
            Toggle("Transcrire chaque appel", isOn: $model.autoTranscribe)
        } else {
            Text("Transcription : installe whisper-cpp et son modèle")
        }
        Toggle("Lancer à l'ouverture de session", isOn: Binding(
            get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

        Divider()
        if let last = model.lastRecording {
            Button("Écouter le dernier appel") { NSWorkspace.shared.open(last) }
        }
        if let transcript = model.lastTranscript {
            Button("Lire la dernière transcription") { NSWorkspace.shared.open(transcript) }
        }
        Button("Ouvrir le dossier des appels") {
            try? FileManager.default.createDirectory(at: CallRecorder.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CallRecorder.folder)
        }
        Text("Pense à prévenir ton correspondant.")
        Divider()
        Button("Quitter") { model.stop(); NSApp.terminate(nil) }
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
