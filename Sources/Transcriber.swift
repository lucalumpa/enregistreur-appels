import AVFoundation
import Foundation

/// Transcrit un appel en local avec whisper.cpp, voix par voix, pour savoir qui parle.
enum Transcriber {
    static let whisper = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static let model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whisper/ggml-large-v3-turbo.bin")
    /// Facultatif : détecteur de voix qui évite que Whisper invente du texte pendant les silences.
    static let vadModel = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whisper/ggml-silero-v5.1.2.bin")

    static var isAvailable: Bool { whisper != nil && FileManager.default.fileExists(atPath: model.path) }

    struct Segment {
        let start: Int // ms
        let end: Int
        let text: String
        let speaker: String
    }

    /// Écrit le .txt à côté du fichier audio et renvoie son URL.
    static func transcribe(_ recording: Recording) async throws -> URL {
        let mine = try await segments(of: recording.myVoice, speaker: L("Moi", "Me"))
        let theirs = try await segments(of: recording.theirVoice, speaker: L("Correspondant", "Other person"))
        let merged = (removeEcho(mine, heardIn: theirs) + theirs).sorted { $0.start < $1.start }

        let formatter = DateFormatter()
        formatter.dateFormat = L("dd/MM/yyyy 'à' HH'h'mm", "MMM d, yyyy 'at' h:mm a")
        formatter.locale = Locale(identifier: Language.current.rawValue)
        let duration = Int((try? await AVURLAsset(url: recording.audio).load(.duration).seconds) ?? 0)
        var text = L("Appel du ", "Call on ") + "\(formatter.string(from: recording.date)) — \(duration / 60) min \(duration % 60) s\n"
        text += L("(transcription automatique Whisper, peut contenir des erreurs)",
                  "(automatic Whisper transcript, may contain mistakes)") + "\n"
        var lastSpeaker = ""
        for segment in merged {
            if segment.speaker != lastSpeaker {
                let s = segment.start / 1000
                text += String(format: "\n[%02d:%02d] ", s / 60, s % 60) + segment.speaker + L(" : ", ": ") + segment.text
                lastSpeaker = segment.speaker
            } else {
                text += " \(segment.text)"
            }
        }
        let output = recording.audio.deletingPathExtension().appendingPathExtension("txt")
        try (text + "\n").write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func segments(of audio: URL, speaker: String) async throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: audio.path), let whisper else { return [] }
        let base = audio.deletingPathExtension()
        let wav = base.appendingPathExtension("wav")
        try await run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path])

        var args = ["-m", model.path, "-l", "auto", "-f", wav.path, "-mc", "0", "-sns", "-np", "-oj", "-of", base.path]
        if FileManager.default.fileExists(atPath: vadModel.path) { args += ["--vad", "-vm", vadModel.path] }
        try await run(whisper, args)

        struct Output: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Item]
        }
        let data = try Data(contentsOf: base.appendingPathExtension("json"))
        var result: [Segment] = []
        for item in try JSONDecoder().decode(Output.self, from: data).transcription {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper boucle parfois sur la même phrase ou invente des génériques pendant les silences.
            guard !text.isEmpty, !isHallucination(text), normalized(text) != normalized(result.last?.text ?? "") else { continue }
            result.append(Segment(start: item.offsets.from, end: item.offsets.to, text: text, speaker: speaker))
        }
        return result
    }

    /// Sur haut-parleurs, le micro réentend le correspondant : on retire ces doublons de « Moi ».
    private static func removeEcho(_ mine: [Segment], heardIn theirs: [Segment]) -> [Segment] {
        mine.filter { m in
            !theirs.contains { t in
                t.start < m.end + 1500 && m.start < t.end + 1500 && similarity(m.text, t.text) >= 0.5
            }
        }
    }

    private static func words(_ s: String) -> Set<String> {
        Set(normalized(s).split(separator: " ").map(String.init))
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count))
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isHallucination(_ text: String) -> Bool {
        let t = normalized(text)
        return ["sous titrage", "sous titres", "amara org", "merci d avoir regarde", "abonnez vous"].contains { t.contains($0) }
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let name = (executable as NSString).lastPathComponent
                    continuation.resume(throwing: CoreAudioError(status: p.terminationStatus, what: "\(name) a échoué"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
