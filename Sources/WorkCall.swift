import AppKit
import SwiftUI

/// Après un appel : « C'est pour le boulot ? ». Sur « Oui », ouvre Claude Code dans le Terminal
/// avec la transcription et le descriptif ; Claude suit le CLAUDE.md du dossier des appels.
enum WorkCall {
    static let claude: String? = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude", "~/.claude/local/claude"]
        .map { NSString(string: $0).expandingTildeInPath }
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isAvailable: Bool { claude != nil }

    static func process(transcript: URL, audio: URL, note: String) throws {
        guard let claude else { return }
        let prompt = L("""
            Nouvel appel boulot à traiter : suis les instructions de CLAUDE.md.
            Transcription : \(transcript.lastPathComponent)
            Audio : \(audio.lastPathComponent)
            Descriptif : \(note.isEmpty ? "(aucun)" : note)
            """, """
            New work call to process: follow the instructions in CLAUDE.md.
            Transcript: \(transcript.lastPathComponent)
            Audio: \(audio.lastPathComponent)
            Description: \(note.isEmpty ? "(none)" : note)
            """)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let promptFile = dir.appendingPathComponent("prompt.txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        // Un .command s'ouvre dans le Terminal sans demander d'autorisation d'automatisation.
        let script = dir.appendingPathComponent("Claude - appel.command")
        try """
            #!/bin/zsh -l
            cd \(quoted(transcript.deletingLastPathComponent().path))
            exec \(quoted(claude)) "$(cat \(quoted(promptFile.path)))"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Petite fenêtre « Cet appel est pour le boulot ? » avec un champ de descriptif.
@MainActor
final class WorkCallPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<String?, Never>?

    /// Renvoie le descriptif si on répond « Oui », nil sinon (ou fenêtre fermée).
    func ask() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L("Appel terminé", "Call ended")
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: WorkCallPrompt { [weak self] answer in self?.finish(answer) })
            window.center()
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ answer: String?) {
        continuation?.resume(returning: answer)
        continuation = nil
        let window = self.window
        self.window = nil
        window?.close()
    }
}

private struct WorkCallPrompt: View {
    let onAnswer: (String?) -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Cet appel est pour le boulot ?", "Was this a work call?"))
                .font(.headline)
            Text(L("Si oui, Claude s'en occupe. Ajoute un petit descriptif : qui est le client, son e-mail, des précisions.",
                   "If so, Claude takes care of it. Add a short description: who the client is, their e-mail, any details."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $note)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button(L("Non", "No")) { onAnswer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L("Oui", "Yes")) { onAnswer(note.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
