import AVFoundation
import CoreAudio
import Foundation

/// Capture tout le son sortant du Mac (la voix du correspondant) grâce à un « process tap » Core Audio.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "enregistreur.tap", qos: .userInitiated)
    /// Pour le diagnostic : quantité et niveau max du son reçu.
    private(set) var framesCaptured = 0
    private(set) var peak: Float = 0

    func start(writingTo url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), L("Création du tap audio système", "Creating the system audio tap"))

        var streamDescription = try readValue(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(status: -1, what: L("Format du tap audio illisible", "Unreadable system audio format"))
        }

        let outputDevice = try readValue(AudioObjectID(kAudioObjectSystemObject),
                                         kAudioHardwarePropertyDefaultSystemOutputDevice,
                                         initial: AudioObjectID(kAudioObjectUnknown))
        guard let outputUID = readString(outputDevice, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, what: L("Sortie audio introuvable", "No audio output found"))
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Enregistreur d'appels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), L("Création du périphérique agrégé", "Creating the aggregate device"))

        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.file = file

        framesCaptured = 0
        peak = 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            self?.framesCaptured += Int(buffer.frameLength)
            if let data = buffer.floatChannelData, buffer.frameLength > 0 {
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { self?.peak = max(self?.peak ?? 0, abs(data[c][i])) }
                }
            }
            try? file.write(from: buffer)
        }, L("Branchement sur le tap", "Connecting to the tap"))
        try check(AudioDeviceStart(aggregateID, procID), L("Démarrage de la capture système", "Starting system audio capture"))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        queue.sync {} // laisse finir la dernière écriture avant de fermer le fichier
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        file = nil
    }
}

struct Recording {
    let audio: URL
    let date: Date
    let workDir: URL
    var myVoice: URL { workDir.appendingPathComponent("micro.m4a") }
    var theirVoice: URL { workDir.appendingPathComponent("systeme.m4a") }

    func discardTracks() { try? FileManager.default.removeItem(at: workDir) }
}

/// Enregistre le micro (ta voix) et le son système (ton correspondant), puis mixe les deux dans un .m4a.
final class CallRecorder {
    /// ~/Documents/Appels enregistrés (ou Call Recordings) : on garde le dossier existant si la langue change.
    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = ["Appels enregistrés", "Call Recordings"]
        let existing = names.first { FileManager.default.fileExists(atPath: documents.appendingPathComponent($0).path) }
        return documents.appendingPathComponent(existing ?? L(names[0], names[1]), isDirectory: true)
    }

    private let tap = SystemAudioTap()
    private var mic: AVAudioRecorder?
    private var workDir: URL?
    private var startDate = Date()

    func start() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        startDate = Date()

        let mic = try AVAudioRecorder(url: dir.appendingPathComponent("micro.m4a"), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        do {
            try tap.start(writingTo: dir.appendingPathComponent("systeme.m4a"))
        } catch {
            tap.stop()
            throw error
        }
        guard mic.record() else {
            tap.stop()
            throw CoreAudioError(status: -1, what: L("Le micro n'a pas pu démarrer", "The microphone couldn't start"))
        }
        self.mic = mic
    }

    var diagnostic: String {
        "système : \(tap.framesCaptured) échantillons, pic \(String(format: "%.3f", tap.peak))"
    }

    /// Arrête l'enregistrement et renvoie le fichier mixé, avec les deux voix encore séparées pour la transcription.
    func stop() async throws -> Recording {
        mic?.stop()
        mic = nil
        tap.stop()
        guard let dir = workDir else { throw CoreAudioError(status: -1, what: L("Aucun enregistrement en cours", "No recording in progress")) }
        workDir = nil

        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = L("'Appel' yyyy-MM-dd 'à' HH'h'mm", "'Call' yyyy-MM-dd 'at' HH.mm")
        let output = uniqueURL(folder.appendingPathComponent(formatter.string(from: startDate)))

        let recording = Recording(audio: output, date: startDate, workDir: dir)
        do {
            try await mix([recording.theirVoice, recording.myVoice], into: output)
        } catch {
            // On ne perd rien : les pistes brutes sont rangées à côté.
            let rescue = output.deletingPathExtension().appendingPathExtension("pistes")
            try? FileManager.default.moveItem(at: dir, to: rescue)
            throw error
        }
        return recording
    }

    private func mix(_ sources: [URL], into output: URL) async throws {
        let composition = AVMutableComposition()
        for url in sources where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration > .zero else { continue }
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try target?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        guard !composition.tracks.isEmpty,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CoreAudioError(status: -1, what: L("Aucun son n'a été capté", "No sound was captured"))
        }
        try await export.export(to: output, as: .m4a)
    }

    private func uniqueURL(_ base: URL) -> URL {
        var url = base.appendingPathExtension("m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: base.path + " (\(n)).m4a")
            n += 1
        }
        return url
    }
}
