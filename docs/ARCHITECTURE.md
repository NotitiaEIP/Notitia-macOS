# Architecture

## Vue d'ensemble

```
┌────────────────────────── Notitia (app macOS) ──────────────────────────┐
│  SwiftUI : barre latérale · liste · éditeur · inspecteur · réglages       │
│  AppKit  : BlockTextView (NSTextView) pour le texte des blocs             │
│  Contrôleurs : Workspace (fenêtre) · NoteEditorModel · RecordingController│
└──────────────────────────────┬───────────────────────────────────────────┘
                               │
┌──────────────────────────── NotitiaKit (package Swift) ──────────────────┐
│ Models   : RichText, Block, NoteDocument, MindMap, TranscriptSegment,     │
│            TranscriptAnnotation,                                          │
│            Folder / Note / Tag / Recording (SwiftData)                    │
│ Editor   : BlockOperations, MarkdownShortcut, MindMapLayout,              │
│            TranscriptTimeline (pur, testé)                                │
│ AI       : TranscriptionEngine, AnnotationDetector, NoteAIService         │
│            (protocoles) + SpeechAnalyzer, SoundAnalysis, ToneAnalyzer,    │
│            FoundationModelsAIService (+ vérification des sources)         │
│ Audio    : AudioRecorder (AVAudioEngine)                                  │
│ Privacy  : AudioVault (AES-GCM), KeyStore (trousseau), RetentionPolicy,   │
│            TranscriptIntegrity (empreinte SHA-256)                        │
│ Storage  : AppPaths, NotitiaStore (suppression réelle, maintenance), SampleData │
│ Export   : MarkdownRenderer, DataExporter (portabilité RGPD)              │
│ Search   : NoteSearch                                                     │
└───────────────────────────────────────────────────────────────────────────┘
```

**Règle** : tout ce qui n'est pas de l'affichage va dans `NotitiaKit`, sous forme de fonctions pures
quand c'est possible, et avec des tests. L'app iOS réutilisera ce package tel quel.

## Où est quoi (par fonctionnalité)

Chemins relatifs à `apple/`. App = `Notitia/`, Kit = `NotitiaKit/Sources/NotitiaKit/`,
Tests = `NotitiaKit/Tests/NotitiaKitTests/`.

| Fonctionnalité | App (interface) | Kit (logique) | Tests |
|---|---|---|---|
| Démarrage, fenêtre, menus | `App/NotitiaApp`, `RootView`, `Workspace` (sélection, glisser-déposer, alertes), `AppCommands`, `AppServices` (services partagés), `Preferences` | — | — |
| Organisation (dossiers, tags, corbeille) | `Features/Sidebar/SidebarView`, `Features/NoteList/NoteListView`, `Features/Inspector/InspectorView` | `Models/PersistentModels` (`Folder`, `Note`, `Tag`, `Recording`), `Storage/NotitiaStore` | `PrivacyTests` (« Base de données et RGPD ») |
| Recherche, ouverture rapide (⌘K) | `Features/Welcome/QuickOpenView` | `Search/NoteSearch` | `AITests` (« Recherche ») |
| Éditeur par blocs | `Features/Editor/NoteEditorView`, `NoteEditorModel`, `BlockRowView` (rendu d'un bloc, menu `/`, images), `BlockTextView` (NSTextView), `RichTextView`, `RichTextConverter` | `Models/Block` (`BlockKind`, `NoteDocument`), `Models/RichText`, `Models/NoteColor`, `Editor/BlockOperations`, `Editor/MarkdownShortcut` | `BlockOperationsTests`, `RichTextTests` |
| Enregistrement et transcription | `Features/Recording/RecordingController` (un flux micro → toutes les analyses), `RecordingViews` (consentement, barre, bloc transcription), `AudioPlaybackController` | `Audio/AudioRecorder`, `Models/TranscriptSegment`, `AI/AIProtocols` (`TranscriptionEngine`, `EngineCatalog`), `AI/AppleSpeechTranscriptionEngine` (SpeechAnalyzer), `AI/DemoTranscriptionEngine` | `TranscriptAnnotationTests` (« Transcription Apple et ton »), `AITests`, `AppleEnginesIntegrationTests` |
| Transcription enrichie (sons, volume, ton, citations, empreinte) | `RecordingViews` (`TranscriptBlockView` : puces, bandeau de ton, « Citer avec le contexte »), `Features/Inspector/InspectorView` (état de l'empreinte), `Features/Settings/SettingsView` (`TranscriptionSettings`) | `Models/TranscriptAnnotation`, `AI/AnnotationDetectors` (`SoundEventDetector`, `LevelAnnotationDetector`), `AI/SoundEventAggregator` (+ `LevelAnalyzer`), `AI/ToneAnalyzer` (+ `TonePassages`), `Editor/TranscriptTimeline` (+ `TranscriptLink`), `Privacy/TranscriptIntegrity` | `TranscriptAnnotationTests`, `AppleEnginesIntegrationTests` |
| IA locale (résumé, mots-clés, carte mentale) | `Features/Editor/GenerationBar` (avancement, annulation), `Features/MindMap/MindMapViews`, `Features/Settings/SettingsView` (`IntelligenceSettings`), `Features/Editor/NoteEditorModel` (`aiSource`, `run`) | `AI/AIProtocols` (`NoteAIService`, `AISource`), `AI/FoundationModelsAIService` (par défaut), `AI/SourceGrounding` (`TextChunker`, `SourceVerifier`, `SourceLocator`), `AI/SummaryAssembler`, `AI/LocalExtractiveAIService` (repli), `AI/TextAnalysis`, `Models/MindMap`, `Editor/MindMapLayout` | `FoundationModelsAITests`, `AITests`, `AppleEnginesIntegrationTests` |
| Confidentialité, RGPD | `Features/Settings/SettingsView` (`PrivacySettings`), `Config/Notitia.entitlements`, `Resources/PrivacyInfo.xcprivacy` | `Privacy/AudioVault`, `Privacy/KeyStore`, `Privacy/RetentionPolicy`, `Export/DataExporter`, `Export/MarkdownRenderer`, `Storage/AppPaths` | `PrivacyTests` |
| Prise en main (tutoriel, note « Aide ») | `Features/Welcome/TutorialView` | `Storage/HelpContent`, `Storage/SampleData` (mode démo) | `HelpContentTests` |
| Identité visuelle | `DesignSystem/Theme` (jetons), `DesignSystem/Components`, `Resources/Assets.xcassets` | — | — |
| Captures (Debug) | `App/DebugSnapshots` | — | — |

Pour brancher un nouveau moteur de transcription ou d'IA :
1. ajouter son implémentation dans `AI/` (avec ses tests) ;
2. l'ajouter à `EngineCatalog.transcriptionEngines` / `aiServices` (les Réglages listent ce catalogue et grisent
   les moteurs indisponibles) ;
3. le choisir selon l'`id` dans `EngineCatalog.transcriptionEngine(id:)` / `aiService(id:)`.

## Format de données portable

Le contenu d'une note est un `NoteDocument` sérialisé en **JSON versionné**, stocké dans `Note.contentData` :

```json
{
  "version": 1,
  "blocks": [
    { "id": "…", "kind": "heading1", "text": [{ "text": "Les tons" }] },
    { "id": "…", "kind": "todo", "isChecked": true, "indent": 1,
      "text": [{ "text": "Réviser " }, { "text": "jeudi", "style": { "bold": true, "highlight": "yellow" } }] },
    { "id": "…", "kind": "transcript", "recordingID": "…" },
    { "id": "…", "kind": "mindMap", "mindMap": { "title": "…", "root": { … } } }
  ]
}
```

Les enregistrements (`Recording`) portent aussi deux champs JSON hors du document :
`segmentsData` (`[TranscriptSegment]`) et `annotationsData` (`[TranscriptAnnotation]`, facultatif) :

```json
[
  { "id": "…", "kind": "laughter", "source": "soundAnalysis", "start": 18.2, "end": 19.1, "confidence": 0.86, "isHidden": false },
  { "id": "…", "kind": "tone", "source": "foundationModels", "start": 19.0, "end": 29.4, "confidence": 0.7,
    "label": "désaccord sur le budget", "polarity": -0.8, "isHidden": false }
]
```

`kind` : `laughter`, `applause`, `raisedVoice`, `longSilence`, `tone` (un type inconnu se lit `unknown`).
Les temps sont en secondes depuis le début de l'enregistrement, pauses exclues : la même horloge que les segments.

`integrityHash` vaut `v1:` suivi du SHA-256 (hexadécimal) d'une **représentation canonique** que chaque plateforme
doit reproduire à l'identique (`TranscriptIntegrity.canonical`). Chaque champ s'écrit `<longueur en octets UTF-8>:<valeur>;`,
les temps en millisecondes entières, dans cet ordre : l'en-tête `notitia-transcript-v1`, puis pour chaque segment
définitif non vide `S`, début, fin, locuteur (ou vide), texte, puis pour chaque annotation **observée** (pas le ton),
triée par début, fin et type : `A`, type, source, début, fin. `isHidden`, la confiance et le ton n'entrent pas
dans l'empreinte.

Ce format est **le contrat commun à toutes les plateformes** :
- le texte riche est une liste de fragments (`runs`) et de styles **sémantiques** (`bold`, `color: "blue"`…),
  et non des attributs propres à une plateforme ;
- les positions sont en **unités UTF-16**, comme dans `NSString`, Java/Kotlin et C# ;
- les couleurs sont des **noms** (`NoteColor`), traduits par chaque plateforme en couleur système ;
- un type de bloc inconnu est lu comme un paragraphe : une ancienne version ne casse pas une note récente.

Les futures apps Android, Windows et Linux doivent lire et écrire exactement ce format (et ré-implémenter
`BlockOperations` avec les mêmes tests).

## Persistance

- **SwiftData**, base locale dans le conteneur sandbox : `Application Support/Notitia/Notitia.store`.
- `Folder` est arborescent (`parent` / `children`, cascade). `Note` → `Folder` (nullify), `Tag` (N–N),
  `Recording` (cascade).
- Audio : `Application Support/Notitia/Recordings/<uuid>.naudio`, **chiffré** (voir PRIVACY.md).
- Images : `Application Support/Notitia/Attachments/`.
- `NotitiaStore` centralise les suppressions pour qu'elles touchent **à la fois** la base et les fichiers.

## Éditeur par blocs

- `NoteEditorModel` garde les blocs en mémoire. Chaque modification passe par `BlockOperations`
  (split, merge, indent, convert, move…) puis est enregistrée dans la note avec un délai de 0,5 s.
- **Choix de `NSTextView` plutôt que `TextEditor`.** Le plan prévoyait `TextEditor` (macOS 26) avec
  `NSTextView` en repli. Nous avons pris directement le repli : un éditeur par blocs doit intercepter
  Entrée, Retour arrière, Tab et les flèches *avant* le traitement du texte (`textView(_:doCommandBy:)`),
  ce que `TextEditor` ne permet pas de façon fiable sur macOS.
- `RichTextConverter` traduit `RichText` ↔ `NSAttributedString`. Le style d'origine est porté par un attribut
  privé (`com.notitia.style`) : la relecture ne dépend jamais du rendu (un titre est en gras visuellement
  sans que son texte soit « gras »).
- Chaque bloc a son propre `UndoManager` (⌘Z agit sur le bloc actif).
- Mise en forme : les menus envoient des actions dans la chaîne des répondeurs (`NSApp.sendAction`),
  reçues par le `BlockTextView` qui a le focus.
- Mesure de hauteur : un `NSLayoutManager` de mesure séparé, et des réponses de taille indépendantes du
  cadre courant. Sinon, boucle de mise en page avec Auto Layout (bogue rencontré et corrigé pendant le développement).

## Transcription et IA

```swift
protocol TranscriptionEngine: Sendable {
    var descriptor: EngineDescriptor { get }   // nom, hors ligne ?, disponible ?
    func transcribe(audio: AsyncStream<AudioChunk>, locale: Locale) -> AsyncThrowingStream<TranscriptSegment, any Error>
}

protocol NoteAIService: Sendable {
    func summarize(_ source: AISource, focus: [String]) async throws -> [Block]
    func keywords(_ source: AISource, limit: Int) async throws -> [String]
    func mindMap(_ source: AISource, focus: [String]) async throws -> MindMapDocument
}
```

protocol AnnotationDetector: Sendable {
    func detect(audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptAnnotation, any Error>
}
```

- `AudioRecorder` capture le micro, écrit un `.m4a` temporaire (chiffré à l'arrêt) et publie des
  `AudioChunk` (échantillons copiés, donc `Sendable`), horodatés par leur position dans le fichier (`time`).
- **Une capture, plusieurs analyses, une seule chronologie.** `RecordingController` envoie chaque bloc au moteur
  de transcription et aux détecteurs d'annotations ; tous horodatent sur `AudioChunk.time`. À l'arrêt :
  fusion des annotations (`mergingOverlaps`), empreinte (`Recording.seal()`), puis ton des passages si activé.

```
AudioRecorder → AudioChunk ─┬─▶ TranscriptionEngine (SpeechAnalyzer ou démo) ─▶ segments
                            ├─▶ SoundEventDetector (SoundAnalysis) ──────────▶ rires, applaudissements, cris
                            └─▶ LevelAnnotationDetector (niveau) ────────────▶ silences, volume élevé
                         à l'arrêt : empreinte SHA-256, puis ToneAnalyzer (texte) ─▶ ton des passages
```

- Implémentations :
  - `AppleSpeechTranscriptionEngine` : **SpeechAnalyzer + SpeechTranscriber**, sur l'appareil. Résultats provisoires
    puis définitifs (`SpeechResultTracker`, pur et testé), conversion vers le format du modèle (16 kHz Int16 sur
    ce Mac), tags de la note passés comme `contextualStrings`. Moteur par défaut.
  - `DemoTranscriptionEngine` rejoue un script au rythme de l'audio, pour essayer l'app sans parler.
  - `SoundEventDetector` : classifieur intégré (`SNClassifierIdentifier.version1`, fenêtres de 1,5 s), puis
    `SoundEventAggregator` (seuils, hystérésis, fusion). `LevelAnnotationDetector` : `LevelAnalyzer`, pur.
  - `ToneAnalyzer` : passages de quelques phrases (`TonePassages`) ; Foundation Models (`@Generable` : catégorie +
    sujet, le libellé est construit par Notitia) si disponible, sinon `NLTagger` (polarité, seuil 0,6).
  - `FoundationModelsAIService` (moteur de synthèse par défaut) : **reformule** résumés, mots-clés et cartes
    mentales. La source est découpée (`TextChunker`, taille tirée de `SystemLanguageModel.contextSize`), chaque
    morceau passe dans une session distincte avec une sortie `@Generable`, et chaque élément doit citer sa phrase.
    `SourceVerifier` écarte les citations introuvables ; `SourceLocator` relie la phrase à l'instant de
    l'enregistrement (repère `[mm:ss]` cliquable) ; `SummaryAssembler` produit les mêmes blocs que le moteur
    extractif. Repli automatique sur `LocalExtractiveAIService` si Apple Intelligence est indisponible ou
    n'aboutit pas. Piège rencontré : un type `@Generable` réutilisé par plusieurs listes faisait recopier au
    modèle la référence du schéma (`#/$defs/…`) au lieu de la citation ; d'où une liste unique avec une catégorie,
    et la citation demandée avant la reformulation.
  - `LocalExtractiveAIService` produit de vrais résultats hors ligne : sélection des phrases par fréquence des
    termes, repérage des décisions, actions et questions, entités nommées et dates (NaturalLanguage,
    NSDataDetector).
- Les résultats IA sont toujours des **blocs éditables** ; les annotations sont marquées « automatique » et
  masquables, la transcription d'origine reste en lecture seule.

## Ce qui vient de l'ancienne application (Flutter)

Seuls des **concepts** ont été repris, pas de code : la taxonomie des nœuds de carte mentale et la règle
« chaque nœud cite son passage source », la structure du résumé riche, les paramètres Deepgram.
NFC, réunions LAN, mascotte, abonnement et authentification Supabase ont été abandonnés pour cette version.
