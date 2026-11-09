use super::*;

pub(super) struct View {
    pub root: gtk::Box,
    left: gtk::TextView,
    right: gtk::TextView,
    count: gtk::Label,
    position: Cell<usize>,
    blocks: RefCell<Vec<i32>>,
    tags: [gtk::TextTag; 2],
    fallback: Cell<bool>,
}
pub(super) struct Prepared {
    annotated: bool,
    fallback: bool,
    text: [String; 2],
    offsets: [usize; 2],
    marks: std::vec::IntoIter<[(i32, i32); 2]>,
    blocks: Vec<i32>,
}
impl View {
    pub fn new(lang: Language) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.set_vexpand(true);
        root.add_css_class("review-diff");
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let count = gtk::Label::new(None);
        count.set_xalign(0.);
        count.set_wrap(true);
        count.set_hexpand(true);
        header.append(&count);
        let previous = chrome::icon(
            "go-up-symbolic",
            lang.text("Voriger Unterschied", "Previous difference"),
        );
        let next = chrome::icon(
            "go-down-symbolic",
            lang.text("Nächster Unterschied", "Next difference"),
        );
        header.append(&previous);
        header.append(&next);
        root.append(&header);
        let left = git_view::output();
        let right = git_view::output();
        for (view, title) in [
            (&left, lang.text("Vorher", "Before")),
            (&right, lang.text("Nachher", "After")),
        ] {
            view.set_wrap_mode(gtk::WrapMode::None);
            view.update_property(&[gtk::accessible::Property::Label(title)]);
        }
        let left_scroll = git_view::scroll(&left);
        let right_scroll = git_view::scroll(&right);
        let syncing = Rc::new(Cell::new(false));
        for (source, target) in [(&left_scroll, &right_scroll), (&right_scroll, &left_scroll)] {
            let target = target.vadjustment();
            let syncing = syncing.clone();
            source.vadjustment().connect_value_changed(move |source| {
                if !syncing.replace(true) {
                    target.set_value(source.value());
                    syncing.set(false);
                }
            });
        }
        let panes = gtk::Paned::new(gtk::Orientation::Horizontal);
        for (scroll, title, start) in [
            (&left_scroll, lang.text("Vorher", "Before"), true),
            (&right_scroll, lang.text("Nachher", "After"), false),
        ] {
            let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
            let label = gtk::Label::new(Some(title));
            label.add_css_class("diff-column-title");
            column.append(&label);
            column.append(scroll);
            if start {
                panes.set_start_child(Some(&column));
            } else {
                panes.set_end_child(Some(&column));
            }
        }
        git_view::balance_panes(&panes);
        panes.set_vexpand(true);
        root.append(&panes);
        let dark = gtk::Settings::default()
            .is_some_and(|s| s.is_gtk_application_prefer_dark_theme())
            || std::env::var("GTK_THEME").is_ok_and(|v| v.contains("dark"));
        let tags = [
            left.buffer()
                .create_tag(
                    Some("removed"),
                    &[(
                        "paragraph-background",
                        &if dark { "#46241F" } else { "#F7E4E0" },
                    )],
                )
                .unwrap(),
            right
                .buffer()
                .create_tag(
                    Some("added"),
                    &[(
                        "paragraph-background",
                        &if dark { "#1F3A26" } else { "#E2EFE3" },
                    )],
                )
                .unwrap(),
        ];
        let view = Rc::new(Self {
            root,
            left,
            right,
            count,
            position: Cell::new(0),
            blocks: RefCell::new(vec![]),
            tags,
            fallback: Cell::new(false),
        });
        for (button, direction) in [(previous, -1), (next, 1)] {
            let weak = Rc::downgrade(&view);
            button.connect_clicked(move |_| {
                if let Some(view) = weak.upgrade() {
                    view.navigate(direction);
                }
            });
        }
        view
    }
    #[cfg(debug_assertions)]
    pub fn test_visible(&self) -> bool {
        self.left.is_mapped()
            && self.right.is_mapped()
            && self.left.width() >= 180
            && self.left.height() >= 80
    }
    #[cfg(debug_assertions)]
    pub(super) fn test_texts(&self) -> [String; 2] {
        [
            buffer_text(&self.left.buffer()),
            buffer_text(&self.right.buffer()),
        ]
    }
    #[cfg(debug_assertions)]
    pub(super) fn test_content(&self, side: usize) -> String {
        let text = buffer_text(&if side == 0 {
            self.left.buffer()
        } else {
            self.right.buffer()
        });
        if self.fallback.get() {
            return text;
        }
        text.split_terminator('\n')
            .filter_map(|line| {
                let (prefix, content) = line.trim_start_matches(' ').split_once("  ")?;
                prefix.trim().parse::<usize>().ok()?;
                Some(content)
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    pub fn clear(&self) {
        self.left.buffer().set_text("");
        self.right.buffer().set_text("");
        self.blocks.borrow_mut().clear();
        self.count.set_text("");
        self.position.set(0);
    }
    fn navigate(&self, direction: i32) {
        let blocks = self.blocks.borrow();
        if blocks.is_empty() {
            return;
        }
        let index =
            (self.position.get() as i32 + direction).rem_euclid(blocks.len() as i32) as usize;
        self.position.set(index);
        for view in [&self.left, &self.right] {
            view.scroll_to_iter(
                &mut view.buffer().iter_at_line(blocks[index]).unwrap(),
                0.,
                true,
                0.,
                0.1,
            );
        }
    }
}
pub(super) fn prepare(
    before: &str,
    after: &str,
    cancel: &fastra_diff::Cancellation,
) -> Result<Prepared, String> {
    prepare_display(before, after, cancel, false)
}
fn prepare_display(
    before: &str,
    after: &str,
    cancel: &fastra_diff::Cancellation,
    annotated: bool,
) -> Result<Prepared, String> {
    let snapshot = |name: &str, text: &str| fastra_diff::TextSnapshot {
        document_id: name.into(),
        revision: 0,
        text: text.into(),
    };
    let comparison = match fastra_diff::Comparison::compare(
        snapshot("before", before),
        snapshot("after", after),
        0,
        fastra_diff::Options::default(),
        fastra_diff::Limits::default(),
        cancel,
    ) {
        Ok(comparison) => comparison,
        // Die Vergleichsgrenze darf eine bisher vollständig darstellbare
        // Freigabe nicht abschaffen. Beide Originalseiten bleiben vollständig;
        // die Oberfläche benennt ausdrücklich die fehlende Zeilenzuordnung.
        Err(fastra_diff::Error::Limit(_)) => {
            if before.len().saturating_add(after.len()) > 32 * 1024 * 1024 {
                return Err("Complete text display exceeds 32 MiB".into());
            }
            return Ok(Prepared {
                annotated,
                fallback: true,
                text: [before.into(), after.into()],
                offsets: [0, 0],
                marks: vec![[
                    (0, before.chars().count() as i32),
                    (0, after.chars().count() as i32),
                ]]
                .into_iter(),
                blocks: if before == after { vec![] } else { vec![0] },
            });
        }
        Err(error) => return Err(error.to_string()),
    };
    // Normalisierte Vergleichsschlüssel dürfen unsichtbare Byteänderungen nicht
    // verdecken. Diese Fälle erhalten automatisch die vollständige Escape-Ansicht.
    if !annotated
        && comparison.rows().iter().any(|row| {
            row.terminators_differ
                || (row.kind == fastra_diff::RowKind::Unchanged
                    && row.left_line.zip(row.right_line).is_some_and(|(a, b)| {
                        comparison.content(true, a) != comparison.content(false, b)
                    }))
        })
    {
        let escaped = |input| {
            fastra_core::display::escaped_text(input, &Cancellation::default(), 16 * 1024 * 1024)
                .map_err(|error| error.to_string())
        };
        let mut result = prepare_display(&escaped(before)?, &escaped(after)?, cancel, true)?;
        result.annotated = true;
        return Ok(result);
    }
    let mut text = [String::new(), String::new()];
    let mut offsets = [0i32; 2];
    let mut marks = Vec::new();
    for row in comparison.rows() {
        cancel.check().map_err(|e| e.to_string())?;
        let mut ranges = [(0, 0); 2];
        for (index, number) in [row.left_line, row.right_line].into_iter().enumerate() {
            let content = number.map_or_else(String::new, |n| {
                format!(
                    "{n:>5}  {}",
                    comparison.content(index == 0, n).unwrap_or_default()
                )
            });
            ranges[index].0 = offsets[index];
            offsets[index] += content.chars().count() as i32 + 1;
            text[index].push_str(&content);
            text[index].push('\n');
            ranges[index].1 = offsets[index];
        }
        if row.kind != fastra_diff::RowKind::Unchanged {
            marks.push(ranges);
        }
        if text.iter().map(String::len).sum::<usize>() > 32 * 1024 * 1024 {
            return Err("Complete diff display exceeds 32 MiB".into());
        }
    }
    let blocks = comparison
        .blocks()
        .iter()
        .map(|block| block.rows.start as i32)
        .collect();
    Ok(Prepared {
        annotated,
        fallback: false,
        text,
        offsets: [0, 0],
        marks: marks.into_iter(),
        blocks,
    })
}
impl Prepared {
    pub fn step(&mut self, view: &View, lang: Language) -> bool {
        view.fallback.set(self.fallback);
        for (index, buffer) in [view.left.buffer(), view.right.buffer()].iter().enumerate() {
            if self.offsets[index] < self.text[index].len() {
                append_chunk(buffer, &self.text[index], &mut self.offsets[index]);
                return false;
            }
        }
        for _ in 0..96 {
            let Some(ranges) = self.marks.next() else {
                *view.blocks.borrow_mut() = std::mem::take(&mut self.blocks);
                view.count.set_text(&format!(
                    "{} {}",
                    view.blocks.borrow().len(),
                    lang.text(
                        if view.blocks.borrow().len() == 1 {
                            "Unterschied"
                        } else {
                            "Unterschiede"
                        },
                        if view.blocks.borrow().len() == 1 {
                            "difference"
                        } else {
                            "differences"
                        }
                    )
                ));
                if self.fallback {
                    view.count.set_text(lang.text(
                        "Vollständige Texte · Zeilenzuordnung überschreitet die Vergleichsgrenze",
                        "Complete texts · line alignment exceeds the comparison budget",
                    ));
                }
                if self.annotated {
                    view.count.set_text(&format!(
                        "{} · {}",
                        lang.text(
                            "Exakte Unicode-/Zeilenendansicht; Marker werden nicht eingefügt",
                            "Exact Unicode/line-ending display; markers are not inserted"
                        ),
                        view.count.text()
                    ));
                }
                return true;
            };
            for (index, buffer) in [view.left.buffer(), view.right.buffer()].iter().enumerate() {
                let (start, end) = ranges[index];
                buffer.apply_tag(
                    &view.tags[index],
                    &buffer.iter_at_offset(start),
                    &buffer.iter_at_offset(end),
                );
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn comparison_limit_retains_complete_review_pages() {
        let before = "cat\n".repeat(30_001);
        let after = "dog\n".repeat(30_001);
        let result = prepare(&before, &after, &fastra_diff::Cancellation::default()).unwrap();
        assert!(result.fallback);
        assert_eq!(result.text, [before, after]);
        assert_eq!(result.blocks, vec![0]);
    }
    #[test]
    fn aligned_insertions_unicode_and_no_source_mutation() {
        let cancel = fastra_diff::Cancellation::default();
        let result = prepare("雪\nold\nend", "雪\nnew\nextra\nend", &cancel).unwrap();
        assert_eq!(result.text[0], "    1  雪\n    2  old\n\n    3  end\n");
        assert_eq!(
            result.text[1],
            "    1  雪\n    2  new\n    3  extra\n    4  end\n"
        );
        assert_eq!(result.blocks, vec![1]);
        for (before, after) in [
            ("é\nold", "e\u{301}\nnew"),
            ("x\r\ny", "x\ny"),
            ("foo\n", "foo"),
        ] {
            let exact = prepare(before, after, &cancel).unwrap();
            assert!(exact.annotated);
            assert!(!exact.blocks.is_empty());
            assert!(exact.text[0].contains('\\'));
        }
        cancel.cancel();
        assert!(prepare("a", "b", &cancel).is_err());
    }
}
