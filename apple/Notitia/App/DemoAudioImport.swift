#if DEBUG
import Foundation
import NotitiaKit
import SwiftData

/// `-NotitiaDemoMode YES -NotitiaDemoAudio <fichier>` (Debug) : crée une note de réunion à partir d'un fichier
/// audio placé dans le dossier temporaire du conteneur de l'app, en le faisant passer par les mêmes analyses qu'un
/// enregistrement (transcription réelle, sons, volume, empreinte, audio chiffré). Sert à tester sans micro.
@MainActor
enum DemoAudioImport {
    static func run(services: AppServices) async {
        guard let name = UserDefaults.standard.string(forKey: "NotitiaDemoAudio") else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        let context = services.container.mainContext
        let folder = (try? context.fetch(FetchDescriptor<Folder>()))?.first { $0.name == "Réunions" }
        let note = Note(title: "Réunion de test — sprint 3", document: NoteDocument(blocks: [
            Block(kind: .paragraph, text: RichText("Transcription du fichier audio en cours…", style: TextStyle(italic: true, color: .gray))),
        ]), folder: folder)
        context.insert(note)
        try? context.save()

        do {
            let (chunks, duration) = try AudioFileReader.chunks(of: url)
            let localeID = Preferences.transcriptionLocale
            let engine = EngineCatalog.transcriptionEngine(id: Preferences.transcriptionEngineID)
            let recording = Recording(localeIdentifier: localeID, engineName: engine.descriptor.displayName, consentConfirmedAt: .now, note: note)
            context.insert(recording)

            async let segments = collect(engine.transcribe(audio: AudioFileReader.stream(chunks), locale: Locale(identifier: localeID)))
            async let sounds = collect(SoundEventDetector().detect(audio: AudioFileReader.stream(chunks)))
            async let levels = collect(LevelAnnotationDetector().detect(audio: AudioFileReader.stream(chunks)))

            // Un segment est émis plusieurs fois (provisoire puis définitif) : on garde la dernière version.
            var latest: [UUID: TranscriptSegment] = [:]
            var order: [UUID] = []
            for segment in try await segments {
                if latest[segment.id] == nil { order.append(segment.id) }
                latest[segment.id] = segment
            }
            recording.segments = order.compactMap { latest[$0] }.filter { !$0.text.isEmpty }.map {
                var final = $0
                final.isFinal = true
                return final
            }
            recording.annotations = (try await sounds + levels).mergingOverlaps()
            recording.duration = duration
            recording.seal()

            // Copie chiffrée de l'audio : les horodatages peuvent rejouer chaque phrase.
            let copy = FileManager.default.temporaryDirectory.appending(path: "notitia-import-\(recording.uid.uuidString).m4a")
            try FileManager.default.copyItem(at: url, to: copy)
            try services.vault.seal(plaintextFile: copy, id: recording.uid)
            recording.hasAudio = true

            NSLog("%@", "Import démo : \(recording.segments.count) segments, \(recording.annotations.count) annotations, \(Int(duration)) s — \(recording.segments.prefix(2).map(\.text))")
            note.document = NoteDocument(blocks: [
                Block(kind: .paragraph, text: RichText("Réunion de test générée à partir d'un fichier audio (voix de synthèse). Essayez « Résumer », « Carte mentale » et « Analyser le ton des passages ».", style: TextStyle(italic: true, color: .gray))),
                Block(kind: .transcript, recordingID: recording.uid),
            ])
        } catch {
            NSLog("Import démo impossible : %@", "\(error)")
            note.document = NoteDocument(blocks: [
                Block(kind: .callout, text: RichText("Import impossible : \(error.localizedDescription)")),
            ])
        }
        note.updatedAt = .now
        try? context.save()
    }

    private static func collect<Element>(_ stream: AsyncThrowingStream<Element, any Error>) async throws -> [Element] {
        var elements: [Element] = []
        for try await element in stream { elements.append(element) }
        return elements
    }
}
#endif
