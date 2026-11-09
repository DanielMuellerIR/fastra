use super::*;

pub(crate) struct OutlineSnapshot {
    pub stamp: (String, u64),
    pub index: Option<usize>,
    pub levels: Vec<u8>,
}

impl RichEditor {
    pub(crate) fn outline_stamp(&self) -> Option<(String, u64)> {
        (self.ready.get() && !self.busy.get() && !self.failed.get() && self.focused())
            .then(|| (self.session.clone(), self.input_revision.get()))
    }
    pub(super) fn refresh_outline(&self) {
        if let Some(outline) = self.outline.borrow().as_ref() {
            outline.schedule();
        }
    }
    pub(crate) fn outline_prepare(
        self: &Rc<Self>,
        done: impl FnOnce(Option<OutlineSnapshot>) + 'static,
    ) {
        let Some(ui) = self.ui.upgrade() else {
            done(None);
            return;
        };
        let owner = ui.generation.get();
        let weak = Rc::downgrade(self);
        self.synchronize(
            false,
            Box::new(move |ok| {
                let Some(editor) = weak
                    .upgrade()
                    .filter(|e| ok && e.ui.upgrade().is_some_and(|u| u.generation.get() == owner))
                else {
                    done(None);
                    return;
                };
                editor.outline_snapshot(done);
            }),
        );
    }
    pub(crate) fn outline_snapshot(
        self: &Rc<Self>,
        done: impl FnOnce(Option<OutlineSnapshot>) + 'static,
    ) {
        let Some(stamp) = self.outline_stamp() else {
            done(None);
            return;
        };
        let owner = self.ui.upgrade().unwrap().generation.get();
        let weak = Rc::downgrade(self);
        self.evaluate(
            "return JSON.stringify(fastraVisual.outlineSnapshot());",
            move |value| {
                let Some(editor) = weak.upgrade().filter(|e| {
                    e.outline_stamp().as_ref() == Some(&stamp)
                        && e.ui.upgrade().is_some_and(|u| u.generation.get() == owner)
                }) else {
                    done(None);
                    return;
                };
                let parsed = value
                    .filter(|v| {
                        v["ok"] == true
                            && v["session"] == stamp.0
                            && v["revision"].as_u64() == Some(stamp.1)
                    })
                    .and_then(|v| {
                        let headings = v["headings"].as_array()?;
                        if headings.len() > 10_000 {
                            return None;
                        }
                        let mut bytes = 0;
                        let levels = headings
                            .iter()
                            .map(|h| {
                                let title = h["title"].as_str()?;
                                bytes += title.len();
                                let level = h["level"].as_u64()?;
                                (title.len() <= 16_384
                                    && bytes <= MAX_BYTES
                                    && (1..=6).contains(&level))
                                .then_some(level as u8)
                            })
                            .collect::<Option<Vec<_>>>()?;
                        Some(OutlineSnapshot {
                            stamp,
                            index: v["index"]
                                .as_i64()
                                .filter(|n| *n >= 0)
                                .map(|n| n as usize)
                                .filter(|n| *n < levels.len()),
                            levels,
                        })
                    });
                let _ = editor;
                done(parsed);
            },
        );
    }
    pub(crate) fn outline_reveal(
        self: &Rc<Self>,
        index: usize,
        levels: Vec<u8>,
        done: impl FnOnce(bool) + 'static,
    ) {
        let Some(stamp) = self.outline_stamp() else {
            done(false);
            return;
        };
        let owner = self.ui.upgrade().unwrap().generation.get();
        // WebKit prüft nochmals im selben Durchlauf wie die Auswahl: Eine inzwischen
        // eingetroffene Eingabe darf keinen Sprung in einen älteren Überschriftenbaum erhalten.
        let code = format!("const s=fastraVisual.outlineSnapshot();if(!s.ok || s.session!=={} || s.revision!=={} || JSON.stringify(s.headings.map(h=>h.level))!=={})return JSON.stringify(false);return JSON.stringify(fastraVisual.revealHeading({index}));", json!(stamp.0), stamp.1, json!(serde_json::to_string(&levels).unwrap()));
        let weak = Rc::downgrade(self);
        self.evaluate(&code, move |value| {
            let valid = value == Some(json!(true))
                && weak.upgrade().is_some_and(|e| {
                    e.outline_stamp().as_ref() == Some(&stamp)
                        && e.ui.upgrade().is_some_and(|u| u.generation.get() == owner)
                });
            done(valid);
        });
    }
    pub(crate) fn outline_source(self: &Rc<Self>, done: impl FnOnce(bool) + 'static) {
        let Some(doc) = self.current().filter(|_| self.outline_stamp().is_some()) else {
            done(false);
            return;
        };
        let Some(toggle) = doc
            .rich_toggle
            .borrow()
            .clone()
            .filter(|t| t.is_active() && t.is_sensitive())
        else {
            done(false);
            return;
        };
        if self.navigation_source_completion.borrow().is_some() {
            done(false);
            return;
        }
        *self.navigation_source_completion.borrow_mut() = Some(Box::new(done));
        toggle.set_active(false);
    }
}

pub(super) fn install(editor: &Rc<RichEditor>, toolbar: &gtk::FlowBox) {
    let (Some(ui), Some(doc)) = (editor.ui.upgrade(), editor.document.upgrade()) else {
        return;
    };
    let view = crate::markdown_navigation::View::new_rich(&ui, &doc, editor);
    toolbar.insert(&view.root, -1);
    *editor.outline.borrow_mut() = Some(view);
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) use gui_test::start as run_selftest;
