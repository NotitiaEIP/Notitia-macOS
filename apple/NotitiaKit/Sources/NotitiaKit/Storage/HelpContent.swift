import Foundation
import SwiftData

/// Note « Aide » : un mode d'emploi qui montre lui-même chaque possibilité de l'éditeur.
///
/// Elle a un identifiant fixe, ce qui permet de la retrouver (menu Aide) sans jamais la dupliquer.
@MainActor
public enum HelpContent {
    public static let noteID = UUID(uuidString: "00000000-0000-4000-8000-0000000A11DE")!
    public static let title = "Aide — Bien démarrer avec Notitia"

    /// Renvoie la note d'aide, en la créant si elle n'existe pas et en la restaurant si elle est à la corbeille.
    @discardableResult
    public static func install(in context: ModelContext) -> Note {
        let id = noteID
        if let existing = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.uid == id })).first {
            if existing.isTrashed { existing.trashedAt = nil }
            return existing
        }
        let note = Note(title: title, document: document)
        note.uid = noteID
        note.isPinned = true
        context.insert(note)
        try? context.save()
        return note
    }

    // MARK: Contenu

    private static let bold = TextStyle(bold: true)
    private static let code = TextStyle(code: true)
    private static let muted = TextStyle(italic: true, color: .gray)

    /// Texte où les fragments entre accents graves (`…`) sont affichés en code.
    private static func t(_ string: String) -> RichText {
        var runs: [TextRun] = []
        for (index, part) in string.components(separatedBy: "`").enumerated() where !part.isEmpty {
            runs.append(TextRun(part, style: index.isMultiple(of: 2) ? .plain : code))
        }
        return RichText(runs: runs)
    }

    /// Libellé en gras suivi d'une explication.
    private static func term(_ label: String, _ rest: String) -> RichText {
        RichText(runs: [TextRun(label, style: bold)]).appending(t(rest))
    }

    private static func shortcut(_ keys: String, _ action: String) -> Block {
        Block(kind: .bulleted, text: RichText(runs: [TextRun(keys, style: code), TextRun("  " + action)]))
    }

    public static var document: NoteDocument {
        NoteDocument(blocks: introduction + writing + formatting + organizing + recording + intelligence + privacy + shortcuts)
    }

    private static var introduction: [Block] {
        [
            Block(kind: .callout, text: RichText(runs: [
                TextRun("Cette note est la vôtre. ", style: bold),
                TextRun("Modifiez-la, essayez tout ce qui est décrit ici. Vous la retrouverez à tout moment avec le menu "),
                TextRun("Aide › Aide de Notitia", style: bold),
                TextRun(", et le tutoriel avec "),
                TextRun("Aide › Revoir le tutoriel", style: bold),
                TextRun("."),
            ])),
        ]
    }

    private static var writing: [Block] {
        [
            Block(kind: .heading1, text: "1. Écrire"),
            Block(text: t("Chaque paragraphe d'une note est un bloc. `Entrée` crée un nouveau bloc, `⇧ Entrée` passe à la ligne dans le même bloc. Les flèches passent d'un bloc à l'autre.")),

            Block(kind: .heading2, text: "Le menu « / »"),
            Block(text: t("Dans un bloc vide, tapez `/` puis le début du nom d'un bloc : « titre », « tâche », « code »… Choisissez avec `↑` `↓`, validez avec `Entrée`, fermez avec `Échap`.")),

            Block(kind: .heading2, text: "Les types de blocs"),
            Block(text: t("Chaque bloc ci-dessous indique le raccourci qui le crée : tapez-le au début d'un bloc vide, suivi d'une espace.")),

            Block(kind: .heading3, text: "Titres"),
            Block(text: t("Trois niveaux : `#` Titre 1, `##` Titre 2, `###` Titre 3. Ils structurent la note, comme ceux de cette page.")),

            Block(kind: .heading3, text: "Listes"),
            Block(kind: .bulleted, text: t("Liste à puces : `-`")),
            Block(kind: .bulleted, text: t("`Tab` imbrique un élément, `⇧ Tab` le remonte"), indent: 1),
            Block(kind: .bulleted, text: "Jusqu'à six niveaux d'imbrication", indent: 2),
            Block(kind: .bulleted, text: t("`Entrée` sur un élément vide termine la liste")),
            Block(kind: .numbered, text: t("Liste numérotée : `1.`")),
            Block(kind: .numbered, text: "La numérotation se met à jour toute seule"),
            Block(kind: .numbered, text: "Elle reprend à 1 après un autre bloc"),
            Block(kind: .todo, text: t("Liste de tâches : `[]`"), isChecked: true),
            Block(kind: .todo, text: t("Cochez d'un clic sur la case, ou avec `⌘ Entrée`")),
            Block(kind: .todo, text: "Une tâche cochée est barrée et grisée"),

            Block(kind: .heading3, text: "Citations, encadrés et code"),
            Block(kind: .quote, text: t("Citation : `>`. Pour une phrase d'auteur, un extrait de cours ou une parole rapportée.")),
            Block(kind: .callout, text: RichText(runs: [
                TextRun("Encadré : ", style: bold),
                TextRun("tapez "), TextRun("!", style: code),
                TextRun(". Idéal pour une définition, une formule ou un point à retenir pour l'examen."),
            ])),
            Block(kind: .code, text: "// Bloc de code : tapez ``` dans un bloc vide.\n// Entrée va à la ligne ; ↓ sur la dernière ligne sort du bloc.\nfunc bonjour() {\n    print(\"Bonjour Notitia\")\n}"),
            Block(kind: .divider),
            Block(text: t("Ci-dessus, un séparateur : `---`. Pour une image, tapez `/image` puis choisissez un fichier, ou glissez une image sur le bloc.")),

            Block(kind: .heading2, text: "Réorganiser les blocs"),
            Block(kind: .bulleted, text: term("Poignée ≡ : ", "survolez un bloc, elle apparaît à gauche. Glissez-la pour déplacer le bloc ; cliquez-la pour le transformer, le dupliquer ou le supprimer.")),
            Block(kind: .bulleted, text: term("Clavier : ", "`⌥⌘↑` et `⌥⌘↓` montent et descendent le bloc courant.")),
            Block(kind: .bulleted, text: term("Retour arrière ", "au début d'un bloc le transforme d'abord en texte simple, puis le fusionne avec le bloc précédent.")),
        ]
    }

    private static var formatting: [Block] {
        [
            Block(kind: .heading1, text: "2. Mettre en forme"),
            Block(text: RichText(runs: [
                TextRun("Sélectionnez du texte puis utilisez la barre d'outils, le menu Format ou les raccourcis : "),
                TextRun("gras", style: TextStyle(bold: true)), TextRun(" ("), TextRun("⌘B", style: code), TextRun("), "),
                TextRun("italique", style: TextStyle(italic: true)), TextRun(" ("), TextRun("⌘I", style: code), TextRun("), "),
                TextRun("souligné", style: TextStyle(underline: true)), TextRun(" ("), TextRun("⌘U", style: code), TextRun("), "),
                TextRun("barré", style: TextStyle(strikethrough: true)), TextRun(" ("), TextRun("⇧⌘X", style: code), TextRun(") et "),
                TextRun("code", style: code), TextRun(" ("), TextRun("⌘E", style: code), TextRun(")."),
            ])),
            Block(text: RichText(runs: [
                TextRun("Le bouton palette change la "),
                TextRun("couleur", style: TextStyle(color: .red)), TextRun(" "),
                TextRun("du", style: TextStyle(color: .blue)), TextRun(" "),
                TextRun("texte", style: TextStyle(color: .green)), TextRun(", permet de "),
                TextRun("surligner", style: TextStyle(highlight: .yellow)), TextRun(" un passage ou d'ajouter un "),
                TextRun("lien", style: TextStyle(link: "https://www.epitech.eu")), TextRun(" ("),
                TextRun("⇧⌘L", style: code), TextRun(")."),
            ])),
            Block(text: t("Sans sélection, le style choisi s'applique au texte que vous allez taper. Le menu Format change aussi le type du bloc : `⌥⌘0` texte, `⌥⌘1` à `⌥⌘3` titres.")),
            Block(text: RichText("Les styles se combinent : vous pouvez avoir du texte gras, bleu et surligné à la fois.", style: TextStyle(bold: true, color: .blue, highlight: .yellow))),
        ]
    }

    private static var organizing: [Block] {
        [
            Block(kind: .heading1, text: "3. Organiser ses notes"),
            Block(kind: .bulleted, text: term("Dossiers : ", "`⇧⌘N` ou le bouton + de la barre latérale. Clic droit sur un dossier pour créer un sous-dossier, le renommer ou changer son icône et sa couleur.")),
            Block(kind: .bulleted, text: term("Ranger : ", "glissez une note sur un dossier, ou un dossier sur un autre pour l'imbriquer, par exemple Cours › Chinois. Clic droit sur une note › Déplacer vers fonctionne aussi.")),
            Block(kind: .bulleted, text: "Un dossier affiche aussi les notes de ses sous-dossiers.", indent: 1),
            Block(kind: .bulleted, text: term("Épingler : ", "clic droit › Épingler. Les notes épinglées restent en haut de la liste, comme celle-ci.")),
            Block(kind: .bulleted, text: term("Tags : ", "dans l'inspecteur (`⌥⌘I`), pour regrouper des notes de dossiers différents, par exemple « Révisions ».")),
            Block(kind: .bulleted, text: term("Corbeille : ", "une note supprimée y reste 30 jours, le temps de la restaurer (clic droit › Restaurer).")),
            Block(kind: .bulleted, text: term("Trier : ", "le bouton ⇅ de la liste trie par date de modification, de création ou par titre.")),

            Block(kind: .heading2, text: "Retrouver une note"),
            Block(kind: .bulleted, text: term("Recherche : ", "`⌥⌘F` ou le champ en haut à droite. Elle porte sur les titres et le contenu de toutes les notes, sans tenir compte des majuscules ni des accents.")),
            Block(kind: .bulleted, text: term("Ouverture rapide : ", "`⌘K`, tapez quelques lettres du titre, puis `Entrée`.")),
        ]
    }

    private static var recording: [Block] {
        [
            Block(kind: .heading1, text: "4. Enregistrer une réunion ou un cours"),
            Block(kind: .numbered, text: t("Cliquez sur le micro de la barre d'outils ou tapez `⇧⌘R`. Sans note ouverte, une note « Réunion du … » est créée.")),
            Block(kind: .numbered, text: "Confirmez que les participants sont informés de l'enregistrement : c'est une obligation légale."),
            Block(kind: .numbered, text: t("La transcription s'écrit en direct dans la note. `⇧⌘P` met en pause.")),
            Block(kind: .numbered, text: t("Arrêtez avec `⇧⌘R` : l'audio est chiffré et rangé avec la note.")),
            Block(text: t("Ensuite, cliquez sur un horodatage de la transcription pour réécouter ce passage. Le menu ⋯ du bloc permet de copier la transcription en texte modifiable, d'analyser le ton des passages, ou de supprimer l'audio en gardant le texte.")),
            Block(kind: .heading3, text: "Transcription enrichie"),
            Block(kind: .bulleted, text: term("Sons et volume : ", "les rires, applaudissements, longs silences et passages au volume élevé apparaissent à leur place, marqués « automatique ».")),
            Block(kind: .bulleted, text: term("Ton des passages : ", "après l'enregistrement, un bandeau peut résumer le ton d'un échange (« désaccord sur le budget »), à partir du texte seulement. À activer dans Réglages › Transcription.")),
            Block(kind: .bulleted, text: term("Citer avec le contexte : ", "survolez une phrase et cliquez sur la bulle de citation : la phrase est insérée avec la précédente, la suivante et les horodatages, pour qu'elle ne soit jamais sortie de son contexte.")),
            Block(kind: .bulleted, text: term("Transcription d'origine : ", "la transcription n'est pas modifiable ; l'inspecteur indique si elle a été altérée depuis l'enregistrement. Une annotation erronée se masque d'un clic droit.")),
            Block(kind: .callout, text: RichText(runs: [
                TextRun("Ce que Notitia ne fait pas : ", style: bold),
                TextRun("deviner les émotions d'une personne à partir de sa voix. Les annotations décrivent un moment ou un passage, jamais quelqu'un. La reconnaissance vocale et toutes les analyses ont lieu sur ce Mac, sans Internet ; le modèle de chaque langue s'installe dans Réglages › Transcription."),
            ])),
        ]
    }

    private static var intelligence: [Block] {
        [
            Block(kind: .heading1, text: "5. Résumer et cartographier"),
            Block(text: t("Ouvrez l'inspecteur (`⌥⌘I`), section Intelligence. Les actions s'appliquent à la transcription de la note, ou à son texte s'il n'y en a pas.")),
            Block(kind: .bulleted, text: term("Résumer : ", "points clés, décisions, actions (sous forme de tâches) et questions ouvertes.")),
            Block(kind: .bulleted, text: term("Extraire les mots-clés : ", "les termes les plus importants de la note.")),
            Block(kind: .bulleted, text: term("Créer une carte mentale : ", "les thèmes, idées, personnes et échéances. Cliquez sur un nœud pour retrouver la phrase d'origine dans la transcription, double-cliquez pour le renommer, utilisez ⊖ pour replier une branche, « Agrandir » pour la voir en grand.")),
            Block(kind: .bulleted, text: term("Réécrire avec mes mots-clés : ", "saisissez vos propres mots-clés, séparés par des virgules, pour obtenir une synthèse ou une carte organisée autour d'eux.")),
            Block(kind: .callout, text: RichText(runs: [
                TextRun("Avec Apple Intelligence : ", style: bold),
                TextRun("si elle est activée sur ce Mac, les résumés et cartes mentales sont reformulés, sans Internet. Chaque point doit venir d'une phrase réellement écrite ou prononcée : sinon, il est écarté. Le repère [00:00] d'un point rejoue cette phrase. Sans Apple Intelligence, Notitia sélectionne les phrases telles quelles."),
            ])),
            Block(text: "Les résultats sont ajoutés à la fin de la note sous forme de blocs ordinaires : vous pouvez les corriger, les compléter ou les supprimer. Voici une carte mentale d'exemple :"),
            Block(kind: .mindMap, mindMap: featureMap),
        ]
    }

    private static var privacy: [Block] {
        [
            Block(kind: .heading1, text: "6. Vos données"),
            Block(kind: .bulleted, text: term("Hors ligne : ", "tout reste sur ce Mac. Notitia n'a pas l'autorisation d'accéder à Internet.")),
            Block(kind: .bulleted, text: term("Audio chiffré : ", "les enregistrements sont chiffrés avec une clé conservée dans le trousseau de ce Mac.")),
            Block(kind: .bulleted, text: term("Vos droits : ", "Réglages (`⌘,`) › Confidentialité pour choisir la durée de conservation de l'audio, exporter toutes vos données ou tout effacer.")),
        ]
    }

    private static var shortcuts: [Block] {
        [
            Block(kind: .heading1, text: "Raccourcis clavier"),
            Block(kind: .heading3, text: "Général"),
            shortcut("⌘N", "Nouvelle note"),
            shortcut("⇧⌘N", "Nouveau dossier"),
            shortcut("⌘K", "Ouverture rapide"),
            shortcut("⌥⌘F", "Rechercher dans les notes"),
            shortcut("⌥⌘I", "Afficher l'inspecteur"),
            shortcut("⌘,", "Réglages"),
            Block(kind: .heading3, text: "Éditeur"),
            shortcut("/", "Menu des blocs (dans un bloc vide)"),
            shortcut("⌘B  ⌘I  ⌘U", "Gras, italique, souligné"),
            shortcut("⇧⌘X  ⌘E  ⇧⌘L", "Barré, code, lien"),
            shortcut("⌥⌘0 … ⌥⌘3", "Texte, titres 1 à 3"),
            shortcut("⇧⌘8  ⇧⌘7  ⇧⌘T", "Liste à puces, numérotée, de tâches"),
            shortcut("⌘ Entrée", "Cocher ou décocher une tâche"),
            shortcut("Tab  ⇧ Tab", "Indenter, désindenter"),
            shortcut("⌥⌘↑  ⌥⌘↓", "Déplacer le bloc"),
            shortcut("⌘Z", "Annuler (dans le bloc en cours)"),
            Block(kind: .heading3, text: "Enregistrement"),
            shortcut("⇧⌘R", "Démarrer ou arrêter"),
            shortcut("⇧⌘P", "Pause ou reprise"),
            Block(kind: .divider),
            Block(text: RichText("Bonne prise de notes !", style: muted)),
        ]
    }

    private static var featureMap: MindMapDocument {
        func node(_ label: String, _ kind: MindMapNodeKind, _ children: [MindMapNode] = []) -> MindMapNode {
            MindMapNode(label: label, kind: kind, children: children)
        }
        return MindMapDocument(title: "Notitia", root: node("Notitia", .root, [
            node("Écrire", .topic, [node("12 types de blocs", .idea), node("Menu « / »", .idea), node("Mise en forme", .idea)]),
            node("Organiser", .topic, [node("Dossiers imbriqués", .idea), node("Tags", .idea), node("Recherche", .idea)]),
            node("Réunions", .topic, [node("Enregistrer", .action), node("Transcrire", .action), node("Réécouter", .action)]),
            node("Intelligence", .topic, [node("Résumé", .idea), node("Mots-clés", .idea), node("Carte mentale", .idea)]),
            node("Confidentialité", .topic, [node("Hors ligne", .decision), node("Audio chiffré", .decision), node("Export", .decision)]),
        ]))
    }
}
