//! Musterinformationen gehören zum Eingabefeld, auch wenn die Suche keine Treffer hat.
use super::*;
use fastra_core::regex_groups::{self, Syntax};
use std::{rc::Weak, sync::Arc};
use unicode_segmentation::UnicodeSegmentation;
mod capsules;
pub(crate) use capsules::empty;
#[derive(Clone)]
pub(super) struct Snapshot {
    pub text: String,
    pub mode: u32,
    pub syntax: Option<Syntax>,
    pills: Vec<String>,
}
struct Row {
    view: glib::WeakRef<gtk::ListView>,
    model: gtk::StringList,
    snapshot: RefCell<Option<Arc<Snapshot>>>,
}
pub(super) struct Model {
    ui: Weak<Ui>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    current: RefCell<Option<Arc<Snapshot>>>,
    error: RefCell<Option<String>>,
    rows: RefCell<Vec<Row>>,
    panes: RefCell<Vec<Weak<approval::ApprovalPane>>>,
    fields: RefCell<Vec<glib::WeakRef<gtk::Entry>>>,
}
impl Drop for Model {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
    }
}
impl Model {
    fn changed(self: &Rc<Self>) {
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.current.borrow_mut().take();
        self.error.borrow_mut().take();
        self.refresh();
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let text = ui.find.text().to_string();
        let mode = ui.mode.selected();
        if mode == 0 || text.is_empty() {
            return;
        }
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let weak = Rc::downgrade(self);
        let lang = ui.lang;
        git_view::background(
            move || {
                (|| -> Result<Snapshot, fastra_core::Error> {
                    if text.len() > 65536 {
                        return Err(fastra_core::Error::Limit);
                    }
                    let syntax = if mode == 2 {
                        Some(regex_groups::tokenize(&text, &cancel)?)
                    } else {
                        None
                    };
                    let pills = if let Some(syntax) = &syntax {
                        if syntax.has_errors {
                            vec![]
                        } else {
                            syntax
                                .groups
                                .iter()
                                .map(|g| {
                                    let inner = &text[g.inner.clone()];
                                    let label = if let Some(name) = &g.name {
                                        name.clone()
                                    } else if inner.graphemes(true).count() > 14 {
                                        inner.graphemes(true).take(13).collect::<String>() + "…"
                                    } else {
                                        inner.into()
                                    };
                                    format!("${} {}", g.number, label)
                                })
                                .collect()
                        }
                    } else {
                        fastra_core::wildcard::compile_find(&text)?
                            .star_offsets
                            .iter()
                            .enumerate()
                            .map(|(i, _)| format!("${} *", i + 1))
                            .collect()
                    };
                    cancel.check()?;
                    Ok::<_, fastra_core::Error>(Snapshot {
                        text,
                        mode,
                        syntax,
                        pills,
                    })
                })()
                .map_err(|e| error_text(lang, &e))
            },
            move |result| {
                let Some(model) = weak.upgrade().filter(|m| m.generation.get() == generation)
                else {
                    return;
                };
                match result {
                    Ok(snapshot) => {
                        if snapshot.syntax.as_ref().is_some_and(|s| s.has_errors) {
                            *model.error.borrow_mut()=model.ui.upgrade().map(|ui|ui.lang.text("Die Gruppenbearbeitung unterstützt dieses Suchmuster nicht vollständig.","The group editor does not fully support this search pattern.").to_string());
                        }
                        *model.current.borrow_mut() = Some(Arc::new(snapshot));
                    }
                    Err(error) => {
                        *model.error.borrow_mut() = Some(error);
                    }
                }
                model.refresh();
            },
        );
    }
    pub(super) fn field(&self, field: &gtk::Entry) {
        self.fields.borrow_mut().push(field.downgrade());
        self.refresh();
    }
    pub(super) fn error(&self) -> Option<String> {
        self.error.borrow().clone()
    }
    pub(super) fn snapshot(&self) -> Option<Arc<Snapshot>> {
        self.current.borrow().clone()
    }
    pub(super) fn watch(&self, pane: &Rc<approval::ApprovalPane>) {
        self.panes.borrow_mut().push(Rc::downgrade(pane));
    }
    pub(super) fn row(&self, view: &gtk::ListView, field: &gtk::Entry) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let model = capsules::install(view, field, ui.lang);
        self.rows.borrow_mut().push(Row {
            view: view.downgrade(),
            model,
            snapshot: RefCell::new(None),
        });
        self.refresh();
    }
    fn refresh(&self) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let current = self.snapshot();
        let settings = ui.window.settings();
        let dark = settings.is_gtk_application_prefer_dark_theme()
            || std::env::var("GTK_THEME").is_ok_and(|s| s.ends_with(":dark"))
            || settings
                .gtk_theme_name()
                .is_some_and(|s| s.to_lowercase().contains("dark"));
        self.fields.borrow_mut().retain(|field| {
            let Some(field) = field.upgrade() else {
                return false;
            };
            let attrs = gtk::pango::AttrList::new();
            if let Some(syntax) = current.as_ref().and_then(|s| s.syntax.as_ref()) {
                for token in &syntax.tokens {
                    use regex_groups::Kind::*;
                    let colors = match token.kind {
                        Anchor => Some(((0xa3, 0x39, 0x2a), (0xe8, 0x8d, 0x7c))),
                        Class => Some(((0x2a, 0x66, 0xb5), (0x7f, 0xb0, 0xee))),
                        Quantifier => Some(((0xb5, 0x6c, 0x1a), (0xdf, 0xa2, 0x5a))),
                        Delimiter => Some(((0x70, 0x20, 0xa0), (0xc0, 0x8a, 0xe8))),
                        Alternation => Some(((0x1a, 0x40, 0x80), (0x86, 0xa9, 0xe0))),
                        Escape => Some(((0x2f, 0x5d, 0x3a), (0x94, 0xce, 0x9f))),
                        Backreference => Some(((0xa4, 0x66, 0xd9), (0xc0, 0x9a, 0xe8))),
                        Literal => None,
                    };
                    if let Some((light, night)) = colors {
                        let (r, g, b) = if dark { night } else { light };
                        let mut attr =
                            gtk::pango::AttrColor::new_foreground(r * 257, g * 257, b * 257);
                        attr.set_start_index(token.range.start as u32);
                        attr.set_end_index(token.range.end as u32);
                        attrs.insert(attr);
                    }
                }
            }
            field.set_attributes(&attrs);
            true
        });
        self.rows.borrow_mut().retain(|row| {
            let Some(view) = row.view.upgrade() else {
                return false;
            };
            let snapshot = current
                .as_ref()
                .filter(|s| s.mode == ui.mode.selected() && s.text == ui.find.text());
            if let Some(snapshot) = snapshot {
                if !row
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_some_and(|previous| Arc::ptr_eq(previous, snapshot))
                {
                    row.model.splice(
                        0,
                        row.model.n_items(),
                        &snapshot
                            .pills
                            .iter()
                            .map(String::as_str)
                            .collect::<Vec<_>>(),
                    );
                    *row.snapshot.borrow_mut() = Some(snapshot.clone());
                }
                view.set_visible(!snapshot.pills.is_empty());
            } else {
                row.model.splice(0, row.model.n_items(), &[]);
                row.snapshot.borrow_mut().take();
                view.set_visible(false);
            }
            true
        });
        self.panes.borrow_mut().retain(|pane| {
            if let Some(pane) = pane.upgrade() {
                pane.refresh_pattern();
                true
            } else {
                false
            }
        });
    }
}
pub(super) fn install(ui: &Rc<Ui>) {
    let model = Rc::new(Model {
        ui: Rc::downgrade(ui),
        generation: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
        current: RefCell::new(None),
        error: RefCell::new(None),
        rows: RefCell::new(vec![]),
        panes: RefCell::new(vec![]),
        fields: RefCell::new(vec![]),
    });
    let weak = Rc::downgrade(&model);
    ui.find.connect_changed(move |_| {
        if let Some(model) = weak.upgrade() {
            model.changed();
        }
    });
    let weak = Rc::downgrade(&model);
    ui.mode.connect_selected_notify(move |_| {
        if let Some(model) = weak.upgrade() {
            model.changed();
        }
    });
    for property in ["gtk-theme-name", "gtk-application-prefer-dark-theme"] {
        let weak = Rc::downgrade(&model);
        ui.window
            .settings()
            .connect_notify_local(Some(property), move |_, _| {
                if let Some(model) = weak.upgrade() {
                    model.refresh();
                }
            });
    }
    ui.captures
        .bind_property("visible", &ui.capture_scroll, "visible")
        .sync_create()
        .build();
    model.row(&ui.captures, &ui.replace);
    *ui.search_pattern.borrow_mut() = Some(model);
}

pub(super) fn capture_color(index: usize) -> gtk::gdk::RGBA {
    let colors = [(0.48, 0.70, 0.96), (0.35, 0.78, 0.78), (0.65, 0.40, 0.85)];
    let (r, g, b) = colors[index % colors.len()];
    gtk::gdk::RGBA::new(r, g, b, 0.35)
}
