use super::Language;
use serde_json::Value;
fn meaning(value: &Value, lang: Language) -> &'static str {
    match value.get("kind").and_then(Value::as_str) {
        Some("information") => lang.text("Information", "Information"),
        Some("contentLoss") => lang.text("Inhaltsverlust", "Content loss"),
        _ => lang.text(
            "Annäherung – bitte prüfen",
            "Approximation – review required",
        ),
    }
}
fn location(value: &Value, lang: Language) -> String {
    let mut fields = Vec::new();
    for (key, de, en) in [
        ("page", "Seite", "Page"),
        ("slide", "Folie", "Slide"),
        ("frame", "Bild", "Frame"),
        ("sheet", "Tabellenblatt", "Sheet"),
        ("cell", "Zelle", "Cell"),
        ("paragraph", "Quellabsatz", "Source paragraph"),
        ("message", "Nachricht", "Message"),
        ("note", "Notiz", "Note"),
        ("chapter", "Kapitel", "Chapter"),
    ] {
        if let Some(v) = value.get(key).filter(|v| !v.is_null()) {
            fields.push(format!(
                "{}: {}",
                lang.text(de, en),
                v.as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| v.to_string())
            ));
        }
    }
    if fields.is_empty() {
        lang.text("Fundstelle unbekannt", "Location unknown").into()
    } else {
        fields.join(" · ")
    }
}
pub(super) fn text(response: &fastra_import::Conversion, lang: Language) -> String {
    let mut out = String::new();
    for warning in response.warnings.as_deref().unwrap_or_default() {
        out.push_str(warning);
        out.push('\n');
    }
    let groups = response.diagnostic_groups.as_deref().unwrap_or_default();
    let diagnostics = response.diagnostics.as_deref().unwrap_or_default();
    for value in if groups.is_empty() {
        diagnostics
    } else {
        groups
    } {
        out.push_str(&format!("\n{}", meaning(value, lang)));
        if let Some(code) = value.get("code").and_then(Value::as_str) {
            out.push_str(&format!(" [{code}]"));
            if code == "richText.highlightColorApproximation" {
                out.push_str(lang.text(
                    "\nTextmarkierungen bleiben erhalten; ihre ursprünglichen Farben werden vereinheitlicht.",
                    "\nHighlights are retained; their original colors are flattened.",
                ));
            }
        }
        if let Some(count) = value.get("count").and_then(Value::as_u64) {
            out.push_str(&format!(
                " · {count} {}",
                lang.text("Meldungen", "diagnostics")
            ));
        }
        out.push('\n');
        if let Some(message) = value.get("message").and_then(Value::as_str) {
            out.push_str(message);
            out.push('\n');
        }
        for message in value
            .get("messages")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            out.push_str(message);
            out.push('\n');
        }
        if let Some(loc) = value.get("location").filter(|v| !v.is_null()) {
            out.push_str(&location(loc, lang));
            out.push('\n');
        } else if let Some(locations) = value
            .get("locations")
            .and_then(Value::as_array)
            .filter(|v| !v.is_empty())
        {
            for loc in locations {
                out.push_str(&location(loc, lang));
                out.push('\n');
            }
        } else {
            out.push_str(lang.text("Fundstelle unbekannt\n", "Location unknown\n"));
        }
        if let Some(count) = value
            .get("omittedCount")
            .and_then(Value::as_u64)
            .filter(|v| *v > 0)
        {
            out.push_str(&format!(
                "{count} {}\n",
                lang.text(
                    "weitere Meldungen ausgelassen",
                    "further diagnostics omitted"
                )
            ));
        }
    }
    if out.is_empty() {
        out.push_str(lang.text("Keine Warnungen gemeldet.\n", "No warnings reported.\n"));
    }
    out
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn meanings_locations_unknowns_and_omissions_stay_readable_in_both_languages() {
        let response=fastra_import::Conversion::decode(br#"{"ok":true,"markdownFile":"/a.md","diagnosticGroups":[{"code":"known.loss","kind":"contentLoss","count":3,"messages":["An attachment was omitted"],"locations":[{"page":2,"message":"<id>"}],"omittedCount":7},{"code":"future","kind":"futureMeaning","messages":["Review the source"]}]}"#,Default::default()).unwrap();
        let en = text(&response, Language(false));
        let de = text(&response, Language(true));
        assert!(en.contains("Content loss"));
        assert!(de.contains("Inhaltsverlust"));
        assert!(en.contains("Page: 2"));
        assert!(de.contains("Seite: 2"));
        assert!(en.contains("7 further diagnostics omitted"));
        assert!(en.contains("Approximation"));
        assert!(en.contains("Location unknown"));
        assert!(!en.contains("Page: 0"));
    }
}
