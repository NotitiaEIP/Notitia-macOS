#if DEBUG
import AppKit
import NotitiaKit
import SwiftData
import SwiftUI

/// Captures automatiques de la fenêtre (développement uniquement).
///
/// Lancer avec `-NotitiaDemoMode YES -NotitiaSnapshots YES` : l'application parcourt
/// quelques écrans et enregistre des PNG dans son dossier temporaire
/// (`~/Library/Containers/com.notitia.Notitia/Data/tmp/`). Utile pour la documentation
/// et pour vérifier l'interface sans permission d'enregistrement d'écran.
enum DebugSnapshots {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "NotitiaSnapshots") }

    static func run(_ workspace: Workspace) async {
        guard isEnabled else { return }
        if UserDefaults.standard.bool(forKey: "NotitiaSnapshotTutorial") {
            // Le contenu dessiné par SwiftUI dans la fenêtre n'est pas capturable de l'extérieur :
            // on rend chaque page hors écran (les contrôles AppKit, comme les boutons, n'y figurent pas).
            for page in TutorialPage.allCases.indices {
                for scheme in [ColorScheme.light, .dark] {
                    let view = TutorialView(mode: .firstLaunch, initialPage: page, onFinish: { _ in })
                        .frame(width: 1200, height: 760)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    if let image = renderer.cgImage {
                        let url = FileManager.default.temporaryDirectory.appending(path: "notitia-tutorial-\(page)-\(scheme == .light ? "light" : "dark").png")
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    }
                }
            }
            return
        }
        let notes = (try? workspace.context.fetch(FetchDescriptor<Note>())) ?? []
        try? await Task.sleep(for: .seconds(2))
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)

        NSApp.appearance = NSAppearance(named: .aqua)

        // 1. Note de cours
        if let note = notes.first(where: { $0.title.contains("tons") }), let folder = note.folder {
            workspace.sidebarSelection = .folder(folder.uid)
            workspace.selectedNoteID = note.uid
        }
        try? await Task.sleep(for: .seconds(1.5))
        capture("1-note-light")

        // 2. Réunion : résumé et carte mentale générés localement
        if let meeting = notes.first(where: \.hasRecording) {
            workspace.sidebarSelection = .recordings
            workspace.selectedNoteID = meeting.uid
            workspace.isInspectorPresented = true
            try? await Task.sleep(for: .seconds(1))
            // Transcription enrichie (annotations, ton), puis « Citer avec le contexte »
            if let editor = workspace.editor, let transcript = editor.blocks.first(where: { $0.kind == .transcript }),
               let recording = meeting.recordings.first {
                editor.scrollTarget = transcript.id
                try? await Task.sleep(for: .seconds(1.5))
                capture("2-transcript-light")
                if let cited = recording.segments.dropFirst(3).first {
                    editor.insertQuote(recordingID: recording.uid, segmentID: cited.id, after: transcript.id)
                    try? await Task.sleep(for: .seconds(1.5))
                    capture("2-quote-light")
                }
            }
            workspace.editor?.run(.summary(focus: []))
            // Barre de génération, pendant le résumé.
            try? await Task.sleep(for: .seconds(2))
            if workspace.editor?.isGenerating == true { capture("2-generating-light") }
            await waitForGeneration(workspace)
            workspace.editor?.run(.mindMap(focus: []))
            await waitForGeneration(workspace)
            try? await Task.sleep(for: .seconds(1.5))
            capture("2-meeting-light")
            if let mapID = workspace.editor?.blocks.first(where: { $0.kind == .mindMap })?.id {
                workspace.editor?.scrollTarget = mapID
            }
            try? await Task.sleep(for: .seconds(1.5))
            capture("3-mindmap-light")
        }

        // 3. Note d'aide, puis mode sombre
        workspace.isInspectorPresented = false
        workspace.openHelp()
        try? await Task.sleep(for: .seconds(1.5))
        capture("4-help-light")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .seconds(1.5))
        capture("4-help-dark")
        if let note = notes.first(where: { $0.title.contains("tons") }) {
            workspace.selectedNoteID = note.uid
        }
        try? await Task.sleep(for: .seconds(1.5))
        capture("5-note-dark")
        NSApp.appearance = nil
    }

    /// Avec Apple Intelligence, une génération prend plusieurs secondes.
    static func waitForGeneration(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(0.5))
        for _ in 0..<120 where workspace.editor?.isGenerating == true {
            try? await Task.sleep(for: .seconds(0.5))
        }
    }

    static func capture(_ name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "notitia-\(name).png")
        // Rendu de l'arbre de calques : capture aussi le contenu que SwiftUI dessine
        // directement dans ses calques (ce que `cacheDisplay` ignore).
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped || view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        NSColor.windowBackgroundColor.setFill()
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("📸 \(url.path)")
    }
}
#endif
