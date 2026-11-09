use super::Language;

pub(super) fn validate(text: &str, lang: Language) -> Result<(), String> {
    if text.contains('\0') {
        return Err(lang.text("U+0000 ist im Texteditor nicht verlustfrei darstellbar. Keine Änderung übernommen.", "U+0000 cannot be displayed losslessly in the text editor. No change was applied.").into());
    }
    if text.len() > fastra_document::EDITABLE_BYTES
        || text
            .split(['\r', '\n'])
            .any(|line| line.len() > fastra_document::TEXT_SECTION_BYTES)
    {
        return Err(lang.text("Das Ergebnis überschreitet die Texteditorgrenze von 32 MiB oder 64 KiB je logischer Zeile. Keine Änderung übernommen.", "The result exceeds the text editor limit of 32 MiB or 64 KiB per logical line. No change was applied.").into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extraction_can_exceed_editor_line_limit_without_exceeding_export_limit() {
        let values = vec!["x".repeat(1024); 100];
        let text = fastra_core::hit_extraction::content(
            &values,
            &fastra_core::hit_extraction::Options {
                separator: ",".into(),
                append_newline: false,
                quoting: fastra_core::hit_extraction::Quoting::None,
                deduplicate: false,
            },
            16 * 1024 * 1024,
            &fastra_core::Cancellation::default(),
        )
        .unwrap();
        assert_eq!(text.len(), 102499);
        assert!(validate(&text, Language(false)).is_err());
        assert!(validate(&values.join("\n"), Language(false)).is_ok());
    }
    #[test]
    fn exact_line_bytes_unicode_crlf_and_nul_are_checked() {
        assert!(validate(&"é".repeat(32768), Language(false)).is_ok());
        assert!(validate(&"é".repeat(32769), Language(false)).is_err());
        assert!(validate(
            &format!("{}\r\n{}", "x".repeat(65536), "y".repeat(65536)),
            Language(true)
        )
        .is_ok());
        assert!(validate("visible\0hidden", Language(false)).is_err());
    }
}
