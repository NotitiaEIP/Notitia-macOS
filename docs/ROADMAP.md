# Feuille de route

## Fait — macOS, itération 1

- [x] Socle : dépôt, projet Xcode (dossiers synchronisés), package `NotitiaKit`, 66 tests
- [x] Identité « Natif Apple », icône provisoire
- [x] Organisation : dossiers imbriqués, couleurs, icônes, glisser-déposer, épinglage, tags, corbeille, recherche, ⌘K
- [x] Éditeur par blocs : 12 types de blocs, menu `/`, raccourcis Markdown, mise en forme, images, autosave
- [x] Enregistrement : micro, transcription en direct (moteur de démonstration), lecture synchronisée
- [x] IA locale : résumé, mots-clés, carte mentale interactive, réécriture par mots-clés
- [x] Confidentialité : hors ligne, audio chiffré, consentement, conservation, export, effacement total
- [x] Prise en main : tutoriel au premier lancement, note « Aide » complète, menu Aide

## Fait — macOS, itération 2 : transcription réelle et enrichie

- [x] Transcription réelle sur l'appareil : **SpeechAnalyzer** (moteur par défaut), installation du modèle de
      langue depuis les Réglages, tags de la note comme vocabulaire
- [x] Sons (SoundAnalysis) et volume : rires, applaudissements, cris, longs silences, volume élevé
- [x] Ton des passages, à partir du texte : Foundation Models (sur l'appareil), repli NaturalLanguage ; opt-in
- [x] Fidélité au contexte : transcription d'origine en lecture seule avec empreinte, annotations masquables,
      « Citer avec le contexte » (horodatages cliquables qui rejouent l'audio)
- [x] Aucune déduction d'émotion (AI Act, voir PRIVACY.md §6) ; 95 tests + 3 tests d'intégration

## Fait — macOS, itération 3 : résumés reformulés

- [x] Résumés, mots-clés et cartes mentales reformulés par **Foundation Models**, sur l'appareil, moteur par défaut
- [x] Chaque point cite sa phrase source, vérifiée par le code ; repère `[mm:ss]` cliquable vers l'audio
- [x] Découpage des longues sources, repli automatique sur le moteur extractif
- [x] Barre de génération (étape en cours, moteur réellement utilisé, Annuler) ; 114 tests + 4 tests d'intégration

## Prochaines étapes (ordre conseillé)

1. **Tests réels de la transcription enrichie** : une vraie réunion en français, sur plusieurs Mac (micro intégré,
   casque, permission refusée). Vérifier dans l'app sandboxée l'installation du modèle depuis les Réglages
   (sans `network.client`) et régler les seuils des sons et du volume (`SoundEventAggregator`, `LevelAnalyzer`)
   sur de vrais enregistrements, rires compris.
2. **Résumés sur de vraies réunions longues** (1 h et plus) : mesurer la durée et vérifier la qualité des
   regroupements entre morceaux (la barre de génération affiche déjà l'étape en cours).
3. **Séparation des locuteurs** : SpeechAnalyzer ne la fournit pas ; à étudier (sur l'appareil uniquement).
4. **Éditeur** : annulation des opérations structurelles (aujourd'hui ⌘Z agit dans un bloc), collage
   multi-lignes en plusieurs blocs, sélection sur plusieurs blocs, tableaux, export PDF d'une note.
5. **Localisation anglaise** : les textes sont en français (langue source) ; remplir `Localizable.xcstrings`,
   et traduire la note d'aide (`NotitiaKit/Storage/HelpContent.swift`).
6. **Icône Liquid Glass** (Icon Composer) et vérification d'accessibilité (VoiceOver, contraste, taille du texte).
7. **iOS / iPadOS** : nouvelle cible qui réutilise `NotitiaKit` ; Apple Pencil (PencilKit) pour l'écriture manuscrite.
8. **Synchronisation** entre appareils (local-first), à concevoir avec les contraintes de PRIVACY.md §5.
   Une empreinte signée et partagée entre participants rendrait la transcription d'origine vérifiable par tous.
9. **Android (Kotlin)**, **Windows (C#/WinUI 3)**, **Linux** : ré-implémenter le format `NoteDocument`,
   les annotations, l'empreinte canonique et `BlockOperations` avec les mêmes tests (voir ARCHITECTURE.md).
10. **Questions sur toutes les notes** (RAG local) : embeddings sur l'appareil, en reprenant le découpage de
    l'ancienne app.
