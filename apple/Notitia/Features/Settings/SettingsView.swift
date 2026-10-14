import AppKit
import NotitiaKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralSettings() }
            Tab("Transcription", systemImage: "waveform") { TranscriptionSettings() }
            Tab("Intelligence", systemImage: "sparkles") { IntelligenceSettings() }
            Tab("Confidentialité", systemImage: "lock.shield") { PrivacySettings() }
        }
        .frame(width: 580)
        .scenePadding()
    }
}

// MARK: - Général

private struct GeneralSettings: View {
    @AppStorage(Preferences.Keys.noteSortOrder) private var sortOrder = NoteSortOrder.modified

    var body: some View {
        Form {
            Picker("Trier les notes par", selection: $sortOrder) {
                ForEach(NoteSortOrder.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Apparence") {
                Text("Suit le réglage du système (clair ou sombre) et votre couleur d'accent.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Moteurs

private struct EngineRow: View {
    let engine: EngineDescriptor

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                Text(engine.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if engine.requiresNetwork {
                Label("Réseau", systemImage: "network").font(.caption).foregroundStyle(.orange)
            } else {
                Label("Hors ligne", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(engine.isAvailable ? 1 : 0.5)
    }
}

private struct TranscriptionSettings: View {
    @AppStorage(Preferences.Keys.transcriptionEngine) private var engineID = EngineCatalog.defaultTranscriptionEngineID
    @AppStorage(Preferences.Keys.transcriptionLocale) private var localeID = "fr_FR"
    @AppStorage(Preferences.Keys.annotateSounds) private var annotateSounds = true
    @AppStorage(Preferences.Keys.analyzeTone) private var analyzeTone = false
    @State private var modelStatus: AppleSpeechTranscriptionEngine.ModelStatus?
    @State private var installProgress: Double?
    @State private var installError: String?

    private var usesAppleEngine: Bool { engineID == AppleSpeechTranscriptionEngine.descriptorValue.id }

    var body: some View {
        Form {
            Section {
                Picker("Moteur", selection: $engineID) {
                    ForEach(EngineCatalog.transcriptionEngines) { engine in
                        EngineRow(engine: engine).tag(engine.id).disabled(!engine.isAvailable)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Le moteur d'Apple reconnaît réellement la parole, sur ce Mac et sans Internet. Le moteur de démonstration rejoue un texte d'exemple, pour essayer l'application sans parler.")
            }
            Section {
                Picker("Langue parlée", selection: $localeID) {
                    ForEach(Preferences.transcriptionLocales, id: \.id) { Text($0.name).tag($0.id) }
                }
                if usesAppleEngine { modelRow }
            } footer: {
                if usesAppleEngine {
                    Text("Le modèle de chaque langue est fourni par macOS et installé une seule fois par le système. Notitia elle-même n'a toujours aucun accès à Internet.")
                }
            }
            Section {
                Toggle("Annoter les sons et le volume", isOn: $annotateSounds)
                Text("Rires, applaudissements, longs silences et passages au volume élevé, repérés pendant l'enregistrement.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Analyser le ton des passages", isOn: $analyzeTone)
                Text("Après l'enregistrement, à partir du texte seulement (par exemple « échange tendu sur le budget »). Utilise Apple Intelligence si elle est disponible.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Transcription enrichie")
            } footer: {
                Text("Les annotations décrivent un moment ou un passage, jamais une personne : Notitia ne déduit pas les émotions à partir de la voix, ce que le règlement européen sur l'IA interdit au travail et dans l'enseignement. Tout est analysé sur ce Mac, marqué « automatique », et peut être masqué.")
            }
        }
        .formStyle(.grouped)
        .task(id: localeID) { await refreshStatus() }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch modelStatus {
        case nil:
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Vérification du modèle…").foregroundStyle(.secondary)
            }
        case .installed:
            Label("Modèle installé sur ce Mac", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notInstalled, .downloading:
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Label("Modèle à installer avant d'enregistrer", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Installer le modèle") { install() }
                        .disabled(installProgress != nil || modelStatus == .downloading)
                }
                if let installProgress {
                    ProgressView(value: installProgress)
                } else if modelStatus == .downloading {
                    ProgressView().controlSize(.small)
                }
                if let installError {
                    Text(installError).font(.caption).foregroundStyle(.red)
                }
            }
        case .unsupportedLocale:
            Label("Cette langue n'est pas prise en charge par la transcription d'Apple.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .unavailableOnDevice:
            Label("La transcription sur l'appareil n'est pas disponible sur ce Mac.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func refreshStatus() async {
        modelStatus = nil
        modelStatus = await AppleSpeechTranscriptionEngine.modelStatus(for: Locale(identifier: localeID))
    }

    private func install() {
        installError = nil
        installProgress = 0
        let locale = Locale(identifier: localeID)
        let (progress, reporter) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            for await value in progress { installProgress = value }
        }
        Task {
            do {
                try await AppleSpeechTranscriptionEngine.installModel(for: locale) { reporter.yield($0) }
            } catch {
                installError = error.localizedDescription
            }
            reporter.finish()
            installProgress = nil
            await refreshStatus()
        }
    }
}

private struct IntelligenceSettings: View {
    @AppStorage(Preferences.Keys.aiService) private var serviceID = EngineCatalog.defaultAIServiceID
    @AppStorage(Preferences.Keys.transcriptionLocale) private var localeID = "fr_FR"

    private var unavailability: String? {
        FoundationModelsAIService.unavailabilityReason(for: Locale(identifier: localeID))
    }

    var body: some View {
        Form {
            Section {
                Picker("Moteur", selection: $serviceID) {
                    ForEach(EngineCatalog.aiServices) { engine in
                        EngineRow(engine: engine).tag(engine.id).disabled(!engine.isAvailable)
                    }
                }
                .pickerStyle(.radioGroup)
                if serviceID == FoundationModelsAIService.descriptorValue.id {
                    if let unavailability {
                        Label("\(unavailability) Le moteur local est utilisé en attendant.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Label("Apple Intelligence est disponible sur ce Mac", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } footer: {
                Text("Apple Intelligence reformule résumés et cartes mentales sur ce Mac, sans Internet. Chaque point doit citer une phrase de la source : les points dont la phrase est introuvable sont écartés, et un horodatage permet de réécouter la phrase. Le moteur local, lui, sélectionne les phrases telles quelles.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Confidentialité

private struct PrivacySettings: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @AppStorage(Preferences.Keys.askConsentBeforeRecording) private var askConsent = true
    @AppStorage(Preferences.Keys.audioRetentionDays) private var audioRetentionDays = 0
    @AppStorage(Preferences.Keys.hasCompletedWelcome) private var hasCompletedWelcome = true
    @State private var statistics = NotitiaStore.Statistics()
    @State private var confirmErase = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vos données restent sur ce Mac").font(.headline)
                        Text("Notes, transcriptions et enregistrements sont stockés uniquement dans le conteneur privé de Notitia. L'application n'a pas l'autorisation d'accéder à Internet : rien n'est envoyé, rien n'est collecté.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.tint).font(.title2)
                }
                InfoRow(label: "Notes", value: "\(statistics.notes) (dont \(statistics.trashed) dans la corbeille)")
                InfoRow(label: "Dossiers", value: "\(statistics.folders)")
                InfoRow(label: "Enregistrements", value: "\(statistics.recordings) (dont \(statistics.recordingsWithAudio) avec audio)")
                InfoRow(label: "Espace utilisé", value: ByteCountFormatter.string(fromByteCount: statistics.diskUsage, countStyle: .file))
                Button("Afficher les fichiers dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([services.paths.root])
                }
            }

            Section {
                Toggle("Rappeler l'obligation d'informer les participants avant chaque enregistrement", isOn: $askConsent)
                Picker("Conserver l'audio", selection: $audioRetentionDays) {
                    ForEach(RetentionPolicy.audioRetentionChoices, id: \.self) { days in
                        Text(RetentionPolicy.label(forAudioRetention: days)).tag(days ?? 0)
                    }
                }
                .onChange(of: audioRetentionDays) { services.runMaintenance(); refresh() }
            } header: {
                Text("Enregistrements")
            } footer: {
                Text("L'audio est chiffré (AES-256-GCM) avec une clé conservée dans le trousseau de ce Mac. Quand l'audio expire, la transcription est conservée.")
            }

            Section {
                InfoRow(label: "Corbeille", value: String(localized: "suppression définitive après \(RetentionPolicy.defaultTrashRetentionDays) jours"))
                InfoRow(label: "Outils d'écriture Apple", value: String(localized: "désactivés dans les notes"))
            } header: {
                Text("Conservation")
            }

            Section {
                Button("Exporter toutes mes données…", action: export)
                Button("Effacer toutes mes données…", role: .destructive) { confirmErase = true }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Vos droits")
            } footer: {
                Text("L'export contient toutes vos notes (Markdown et JSON), vos transcriptions et votre audio déchiffré. L'effacement supprime définitivement la base, l'audio, les images et la clé de chiffrement.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .confirmationDialog("Effacer toutes vos données ?", isPresented: $confirmErase) {
            Button("Tout effacer définitivement", role: .destructive, action: eraseEverything)
        } message: {
            Text("Toutes les notes, dossiers, tags, transcriptions et enregistrements seront supprimés de ce Mac. Cette action est irréversible. Pensez à exporter vos données avant.")
        }
    }

    private var store: NotitiaStore {
        NotitiaStore(context: context, paths: services.paths, vault: services.vault)
    }

    private func refresh() {
        statistics = store.statistics()
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Exporter ici")
        panel.message = String(localized: "Choisissez le dossier où créer l'export Notitia.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try context.save()
            let snapshot = try ExportSnapshot.make(context: context)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let folder = try DataExporter(paths: services.paths, vault: services.vault).export(snapshot, into: url)
            message = String(localized: "Export créé : \(folder.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            message = String(localized: "Échec de l'export : \(error.localizedDescription)")
        }
    }

    private func eraseEverything() {
        services.player.stop()
        do {
            try store.eraseEverything()
            hasCompletedWelcome = false
            message = String(localized: "Toutes les données ont été effacées.")
        } catch {
            message = String(localized: "Échec de l'effacement : \(error.localizedDescription)")
        }
        refresh()
    }
}
