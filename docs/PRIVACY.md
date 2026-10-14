# Confidentialité, hors ligne et RGPD

> Document de travail de l'équipe. **Ce n'est pas un avis juridique** : il devra être relu
> (référent RGPD d'Epitech ou juriste) avant toute diffusion publique de l'application.

## 1. Engagements

1. **Hors ligne par construction.** L'application macOS est sandboxée **sans** l'autorisation
   `com.apple.security.network.client` : le système lui interdit toute connexion sortante.
   Aucune fonctionnalité ne dépend d'Internet.
2. **Aucune collecte.** Pas de compte, pas d'analytics, pas de télémétrie, pas de SDK tiers.
   Le manifeste `PrivacyInfo.xcprivacy` le déclare.
3. **Les données restent sur l'appareil**, dans le conteneur privé de l'application.
4. **L'audio est chiffré au repos.**
5. **L'utilisateur garde le contrôle** : export complet, suppression ciblée, effacement total.
6. **Aucune déduction d'émotion.** Les annotations décrivent ce qu'on entend (rires, applaudissements, silences,
   volume) ou le ton d'un passage de **texte**, jamais l'état d'une personne (voir §6).

## 2. Registre des traitements (art. 30)

Notitia fonctionne entièrement en local. L'éditeur du logiciel ne reçoit **aucune** donnée :
l'utilisateur est seul maître de ses données. Ce registre décrit ce que fait le logiciel, pour transparence.

| Traitement | Données | Finalité | Base légale (pour l'utilisateur qui enregistre) | Conservation | Destinataires |
|---|---|---|---|---|---|
| Prise de notes | Texte, images | Organisation personnelle | Usage personnel | Jusqu'à suppression (corbeille : 30 j) | Aucun |
| Enregistrement de réunion | **Voix des participants** (audio) | Transcription | Consentement / intérêt légitime, **avec information préalable des participants** | Réglable : 7 j, 30 j, 3 mois, 1 an ou manuel | Aucun |
| Transcription | Texte transcrit, noms de locuteurs | Notes de réunion | idem | Jusqu'à suppression (survit à l'audio) | Aucun |
| Résumé, carte mentale | Dérivés du texte | Synthèse | idem | Comme la note | Aucun (Foundation Models sur l'appareil, ou moteur extractif local) |
| Annotation des sons et du volume (activée par défaut, désactivable) | Événements horodatés : rires, applaudissements, longs silences, volume élevé. **Aucune attribution à une personne** | Compte rendu fidèle | idem | Comme la transcription | Aucun (SoundAnalysis, sur l'appareil) |
| Ton des passages (**opt-in**) | Libellé du ton d'un passage, déduit du **texte** seul | Compte rendu fidèle | idem | Comme la transcription | Aucun (NaturalLanguage ou Foundation Models, sur l'appareil) |

**Sous-traitants : aucun.** Si un moteur cloud est ajouté (voir §5), ce tableau devra être mis à jour.

## 3. Mesures techniques

| Mesure | Mise en œuvre | Code |
|---|---|---|
| Pas d'accès réseau | Entitlements sans `network.client` | `apple/Config/Notitia.entitlements` |
| Chiffrement de l'audio | AES-256-GCM (CryptoKit). Clé aléatoire stockée dans le trousseau, `WhenUnlockedThisDeviceOnly` (ni iCloud, ni sauvegarde) | `NotitiaKit/Privacy/AudioVault.swift`, `KeyStore.swift` |
| Fichier en clair éphémère | L'enregistrement est écrit en clair dans le dossier temporaire, chiffré à l'arrêt puis supprimé. La lecture déchiffre dans un fichier temporaire supprimé à l'arrêt | `RecordingController`, `AudioPlaybackController` |
| Consentement | Feuille de rappel avant chaque enregistrement ; horodatage stocké (`Recording.consentConfirmedAt`) | `RecordingViews.swift` |
| Indicateur d'enregistrement | Barre d'enregistrement toujours visible, et indicateur micro du système | `RecordingBar` |
| Limitation de conservation | Purge auto de la corbeille (30 j) et de l'audio expiré, au lancement puis toutes les 6 h | `NotitiaStore.runMaintenance`, `RetentionPolicy` |
| Suppression réelle | Supprimer une note supprime ses enregistrements, leur audio et ses images | `NotitiaStore.deletePermanently` |
| Outils d'écriture Apple | Désactivés dans l'éditeur (ils peuvent utiliser le Private Cloud Compute d'Apple) | `BlockTextView.make()` |
| Aucun secret dans le code | Les futures clés éventuelles iront dans le trousseau | — |
| Transcription sur l'appareil | SpeechAnalyzer (macOS 26). Le modèle de chaque langue est fourni et installé par macOS (`AssetInventory`) ; l'app reste sans `network.client`. Jamais de téléchargement pendant un enregistrement | `AppleSpeechTranscriptionEngine` |
| Pas d'inférence d'émotion | Seuls des sons (classifieur intégré d'Apple), le volume mesuré et le ton du **texte** sont annotés. Les mesures de la voix (`SFVoiceAnalytics`) ne sont pas utilisées | `SoundEventDetector`, `LevelAnalyzer`, `ToneAnalyzer` |
| Modèle de langage local uniquement | Foundation Models via `SystemLanguageModel` (sur l'appareil). `PrivateCloudComputeLanguageModel` n'est **jamais** utilisé | `ToneAnalyzer`, `FoundationModelsAIService` |
| Résumés vérifiables | Chaque point d'un résumé ou d'une carte mentale reformulés doit citer sa phrase source ; un point dont la citation est introuvable est écarté. Les points renvoient à l'instant de l'enregistrement | `SourceVerifier`, `SourceLocator`, `SummaryAssembler` |
| Annotations transparentes | Chaque annotation est marquée « automatique » avec sa source et sa confiance ; elle peut être masquée (l'original est conservé) | `TranscriptAnnotation`, `TranscriptBlockView` |
| Transcription d'origine | Lecture seule ; empreinte SHA-256 calculée à l'arrêt, état affiché dans l'inspecteur. Détecte une modification de la base, **n'est pas une preuve** opposable | `TranscriptIntegrity` |
| Citations dans leur contexte | « Citer avec le contexte » insère la phrase, la précédente, la suivante, les annotations et des horodatages qui rejouent l'audio | `TranscriptTimeline.quoteBlocks` |

Les images insérées dans les notes ne sont pas chiffrées par l'application (elles bénéficient du sandbox et
de FileVault). À réévaluer si des documents sensibles sont visés.

## 4. Droits de l'utilisateur (Réglages › Confidentialité)

| Droit | Implémentation |
|---|---|
| Accès et portabilité (art. 15, 20) | **Exporter toutes mes données** : `notitia-export.json` (format structuré), notes en Markdown rangées par dossier, audio déchiffré, images, `LISEZMOI.txt` |
| Effacement (art. 17) | Suppression d'un audio (texte conservé), d'un enregistrement, d'une note, ou **Effacer toutes mes données** (base, audio, images **et clé de chiffrement**) |
| Information (art. 13) | Panneau Confidentialité : ce qui est stocké, où, combien de temps, espace utilisé |
| Limitation | Réglage de la durée de conservation de l'audio |

Le droit à l'information des **participants** enregistrés relève de l'utilisateur qui enregistre :
l'application le lui rappelle avant chaque enregistrement.

## 5. Règles pour toute évolution

Avant d'ajouter une fonctionnalité qui envoie des données hors de l'appareil (moteur cloud, synchronisation) :

- [ ] Elle est **désactivée par défaut** et activée par un **consentement explicite** (opt-in), révocable.
- [ ] L'écran d'activation nomme le sous-traitant, son pays d'hébergement (**UE en priorité**) et les données envoyées.
- [ ] Un contrat de sous-traitance (DPA, art. 28) existe ; le registre (§2) est mis à jour.
- [ ] L'option `network.client` n'est ajoutée qu'à ce moment-là, et l'application reste utilisable hors ligne.
- [ ] Pour une synchronisation : chiffrement de bout en bout envisagé, suppression propagée au serveur.
- [ ] Les secrets éventuels sont dans le trousseau, jamais dans le dépôt.

## 6. Annotations, émotions et AI Act

Le règlement européen sur l'IA (UE 2024/1689, **art. 5 §1 f**, applicable depuis le 2 février 2025) **interdit**
les systèmes qui déduisent les émotions d'une personne **sur le lieu de travail et dans les établissements
d'enseignement**, c'est-à-dire les deux usages de Notitia (réunions, cours). La définition (art. 3 §39) vise les
émotions déduites de **données biométriques**, dont la voix.

Ce que fait Notitia, et pourquoi c'est hors de ce champ (à faire valider, voir l'avertissement en tête) :

| Annotation | Base | Pourquoi ce n'est pas une reconnaissance d'émotions |
|---|---|---|
| Rires, applaudissements | Classifieur de **sons** (SoundAnalysis) | Événement audible, noté comme dans des sous-titres ; aucun état intérieur n'est déduit, aucune personne n'est désignée |
| Volume élevé, long silence | **Mesure** du niveau sonore | Grandeur physique ; libellé « volume élevé », jamais « énervé » |
| Ton d'un passage | **Texte** de la transcription | Le texte n'est pas une donnée biométrique ; le libellé qualifie l'échange (« désaccord sur le budget »), jamais une personne |

Règles à conserver dans toute évolution :
- ne jamais déduire une émotion, une intention ou un trait de caractère à partir de la voix ou du visage ;
- ne jamais attribuer une annotation à un locuteur ;
- toujours marquer une annotation comme automatique, avec sa source, et permettre de la masquer ;
- le ton est **désactivé par défaut** (opt-in, Réglages › Transcription) ; le rappel de consentement mentionne
  les analyses actives.

## 7. Ébauche de politique de confidentialité

> **Notitia ne collecte aucune donnée.** Vos notes, transcriptions et enregistrements sont stockés
> uniquement sur votre appareil, où se fait aussi la reconnaissance vocale. L'application ne se connecte pas à Internet. Les enregistrements audio
> sont chiffrés. Vous pouvez à tout moment exporter l'intégralité de vos données ou les effacer
> définitivement depuis Réglages › Confidentialité. Si vous enregistrez une conversation, vous devez
> en informer les participants et obtenir leur accord.

## 8. Héritage de l'ancienne application

L'application Flutter contenait des **clés d'API en clair dans le code, versionnées dans git**
(Anthropic, Google Gemini ×2, Mistral, Deepgram). Elles doivent être **révoquées** chez chaque fournisseur
et considérées comme compromises, même si le code est abandonné : l'historique git les conserve.
