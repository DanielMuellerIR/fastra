use super::check::{Notice, Status};
use crate::Language;
impl Notice {
    pub(super) fn text(self, lang: Language) -> &'static str {
        let (de,en)=match self {
            Self::Limit=>("Die Quelle überschreitet die Analysegrenze (10 MiB, 200.000 Umbruchzeichen oder Parserbudget).","The source exceeds the analysis limit (10 MiB, 200,000 line-break characters or parser budget)."),
            Self::Files=>("Die Grenze von 200 Markdown-Dateien wurde erreicht.","The limit of 200 Markdown files was reached."),
            Self::References=>("Die Grenze der Verweise oder Anker wurde erreicht.","The reference or anchor limit was reached."),
            Self::Budget=>("Die Quelle überschreitet die Datei- oder Lesebudgetgrenze.","The source exceeds the file or read-budget limit."),
            Self::UnsupportedHtml=>("Nicht unterstütztes HTML verhindert eine vollständige Verweis- oder Ankerprüfung.","Unsupported HTML prevents a complete reference or anchor check."),
            Self::ProjectList=>("Die Projektdateiliste konnte nicht vollständig gelesen werden.","The project file list could not be read completely."),
            Self::Read=>("Die lokale Quelle konnte nicht sicher gelesen werden.","The local source could not be read safely."),
            Self::LocalOnly=>("Nur Ziele auf lokalen Datenträgern werden geprüft.","Only targets on local volumes are checked."),
            Self::Changed=>("Die Quelle wurde während des Lesens geändert.","The source changed while it was being read."),
            Self::Encoding=>("Die Quelle konnte nicht als Text gelesen werden.","The source could not be read as text."),
            Self::Invalid=>("Der lokale Pfad oder Anker ist ungültig codiert.","The local path or anchor has invalid encoding."),
            Self::NeedsFile=>("Relative Ziele brauchen eine gespeicherte Datei als Ausgangspunkt.","Relative targets need a saved file as their starting point."),
            Self::MissingFile=>("Die lokale Zieldatei fehlt.","The local target file is missing."),
            Self::Special=>("Das Ziel ist keine normale Datei und kein Ordner.","The target is neither a regular file nor a folder."),
            Self::MarkdownOnly=>("Anker werden nur in Markdown-Dateien geprüft.","Anchors are checked only in Markdown files."),
            Self::Present=>("Das lokale Ziel ist vorhanden.","The local target exists."),
            Self::MissingAnchor=>("Der lokale Anker fehlt.","The local anchor is missing."),
            Self::Ambiguous=>("Mehrere Überschriften oder HTML-Ziele verwenden diesen Anker.","Multiple headings or HTML targets use this anchor."),
            Self::AnchorPresent=>("Der lokale Anker ist vorhanden.","The local anchor exists."),
            Self::IncompleteAnchors=>("Die Ankerliste ist unvollständig.","The anchor list is incomplete."),
            Self::SourceUnknown=>("Die Zielquelle konnte nicht geprüft werden.","The target source could not be checked."),
            Self::Cancelled=>("Abgebrochen – Ergebnis unvollständig.","Cancelled – result incomplete."),
        };
        lang.text(de, en)
    }
}
impl Status {
    pub(super) fn text(self, lang: Language) -> &'static str {
        let (de, en) = match self {
            Self::Valid => ("Ziel vorhanden", "Target Exists"),
            Self::Missing => ("Ziel fehlt", "Missing Target"),
            Self::Ambiguous => ("Anker mehrdeutig", "Ambiguous Anchor"),
            Self::Unverified => ("Nicht prüfbar", "Cannot Verify"),
        };
        lang.text(de, en)
    }
}
