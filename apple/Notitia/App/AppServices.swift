import Foundation
import NotitiaKit
import Observation
import SwiftData

/// Services partagés par toute l'application.
@Observable
final class AppServices {
    let paths: AppPaths
    let vault: AudioVault
    let container: ModelContainer
    let recorder: RecordingController
    let player: AudioPlaybackController
    /// Message affiché si la base n'a pas pu être ouverte (on travaille alors en mémoire).
    private(set) var storageError: String?

    init() {
        // `-NotitiaDemoMode YES` : base en mémoire pré-remplie (captures d'écran, démos, tests manuels).
        let demoMode = UserDefaults.standard.bool(forKey: "NotitiaDemoMode")
        let paths = demoMode
            ? AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "NotitiaDemo-\(UUID().uuidString)"))
            : AppPaths.default
        self.paths = paths
        self.vault = AudioVault(directory: paths.recordingsDirectory, keyStore: demoMode ? InMemoryKeyStore() : KeychainKeyStore())

        var container: ModelContainer
        do {
            container = try NotitiaSchema.makeContainer(paths: paths, inMemory: demoMode)
        } catch {
            storageError = error.localizedDescription
            container = try! NotitiaSchema.makeContainer(paths: paths, inMemory: true)
        }
        self.container = container
        self.recorder = RecordingController(vault: vault, paths: paths)
        self.player = AudioPlaybackController(vault: vault)

        if demoMode {
            try? paths.prepare()
            // `-NotitiaSnapshotTutorial YES` : on démarre sur le tutoriel (captures).
            let showTutorial = UserDefaults.standard.bool(forKey: "NotitiaSnapshotTutorial")
            if !showTutorial {
                SampleData.populate(container.mainContext)
                HelpContent.install(in: container.mainContext)
            }
            #if DEBUG
            // `-NotitiaDemoAudio <fichier>` : réunion de test créée à partir d'un fichier audio.
            Task { await DemoAudioImport.run(services: self) }
            #endif
            // Valeur volatile : le mode démo ne modifie pas les préférences réelles de l'utilisateur.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[Preferences.Keys.hasCompletedWelcome] = !showTutorial
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }

    var store: NotitiaStore {
        NotitiaStore(context: container.mainContext, paths: paths, vault: vault)
    }

    /// Applique la politique de conservation (corbeille et audio expirés).
    func runMaintenance() {
        _ = try? store.runMaintenance(policy: Preferences.retentionPolicy)
    }
}
