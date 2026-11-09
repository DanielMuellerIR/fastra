use super::*;

const MAX_RUNS: usize = 100_000;

pub(super) struct Snapshot {
    buffer: sourceview5::Buffer,
    offset: i32,
    runs: usize,
}
impl Snapshot {
    pub(super) fn new(input: &TextInput, lang: Language) -> Result<Option<Self>, String> {
        let Some(language) = input.syntax.as_ref().filter(|_| !input.hex) else {
            return Ok(None);
        };
        let scheme = crate::source_appearance::print_scheme().ok_or_else(|| {
            lang.text(
                "Der helle Druckfarbsatz konnte nicht geladen werden.",
                "The light print color scheme could not be loaded.",
            )
            .to_string()
        })?;
        // Eine eigene Textbasis verhindert Änderungen an Editor-Tags, Auswahl,
        // Undo oder dessen dunklem Farbsatz während der Druckvorbereitung.
        let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
        buffer.set_enable_undo(false);
        buffer.set_style_scheme(Some(&scheme));
        buffer.set_language(Some(language));
        buffer.set_highlight_syntax(true);
        buffer.set_text(&input.text);
        Ok(Some(Self {
            buffer,
            offset: 0,
            runs: 0,
        }))
    }
    pub(super) fn line(&mut self, text: &str, lang: Language) -> Result<pango::AttrList, String> {
        let bytes: Vec<_> = text
            .char_indices()
            .map(|(byte, _)| byte)
            .chain([text.len()])
            .collect();
        let length = (bytes.len() - 1) as i32;
        let mut iter = self.buffer.iter_at_offset(self.offset);
        let end = self.buffer.iter_at_offset(self.offset + length);
        self.buffer.ensure_highlight(&iter, &end);
        let attrs = pango::AttrList::new();
        while iter.offset() < end.offset() {
            self.runs += 1;
            if self.runs > MAX_RUNS {
                return Err(lang.text(
                    "Druckgrenze erreicht: höchstens 100.000 Syntaxbereiche. Syntaxfarben ausschalten oder einen kleineren Abschnitt drucken.",
                    "Print limit reached: at most 100,000 syntax ranges. Turn off syntax colors or print a smaller section.",
                ).into());
            }
            let mut next = iter;
            if !next.forward_to_tag_toggle(None::<&gtk::TextTag>) || next.offset() > end.offset() {
                next = end;
            }
            let range = bytes[(iter.offset() - self.offset) as usize] as u32
                ..bytes[(next.offset() - self.offset) as usize] as u32;
            let mut tags = iter.tags();
            tags.sort_by_key(|tag| tag.priority());
            let mut foreground = None;
            let mut weight = None;
            let mut style = None;
            for tag in tags {
                if tag.is_foreground_set() {
                    foreground = tag.foreground_rgba();
                }
                if tag.is_weight_set() {
                    weight = Some(tag.weight());
                }
                if tag.is_style_set() {
                    style = Some(tag.style());
                }
            }
            let insert = |attribute: pango::Attribute| {
                let mut attribute = attribute;
                attribute.set_start_index(range.start);
                attribute.set_end_index(range.end);
                attrs.insert(attribute);
            };
            if let Some(color) = foreground {
                let channel = |value: f32| (value.clamp(0., 1.) * u16::MAX as f32).round() as u16;
                insert(
                    pango::AttrColor::new_foreground(
                        channel(color.red()),
                        channel(color.green()),
                        channel(color.blue()),
                    )
                    .into(),
                );
            }
            if let Some(weight) = weight {
                insert(
                    pango::AttrInt::new_weight(unsafe { glib::translate::from_glib(weight) })
                        .into(),
                );
            }
            if let Some(style) = style {
                insert(pango::AttrInt::new_style(style).into());
            }
            iter = next;
        }
        self.offset += length + 1;
        Ok(attrs)
    }
}

#[cfg(debug_assertions)]
pub(super) fn check(lang: Language) {
    let text = "// Straße α\nfn main() { let name = \"café 🌈\"; }\n";
    let input = TextInput {
        title: "syntax.rs".into(),
        text: Arc::from(text),
        hex: false,
        syntax: Some(
            sourceview5::LanguageManager::default()
                .language("rust")
                .expect("Rust print grammar"),
        ),
    };
    let mut snapshot = Snapshot::new(&input, lang).unwrap().unwrap();
    let mut colored = 0;
    for line in text.split('\n') {
        let attrs = snapshot.line(line, lang).unwrap();
        let mut iterator = attrs.iterator();
        loop {
            for attribute in iterator.attrs() {
                assert!((attribute.end_index() as usize) <= line.len());
                assert!(line.is_char_boundary(attribute.start_index() as usize));
                assert!(line.is_char_boundary(attribute.end_index() as usize));
                if attribute.type_() == pango::AttrType::Foreground {
                    colored += 1;
                }
            }
            if !iterator.next_style_change() {
                break;
            }
        }
    }
    assert!(colored >= 3, "Rust print has no native syntax colors");
    assert_eq!(buffer_text(&snapshot.buffer), text);
}
