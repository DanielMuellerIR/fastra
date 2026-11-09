use super::*;
impl Controls {
    pub(super) fn run_next(self: &Rc<Self>) {
        if self.busy.replace(true) {
            return;
        }
        let Some(change) = self.queue.borrow_mut().pop_front() else {
            self.busy.set(false);
            return;
        };
        self.sets.set_sensitive(false);
        self.remove_set.set_sensitive(false);
        self.filter.set_sensitive(false);
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        git_view::background(
            move || {
                let store = Store::open(&config_root()?).map_err(|e| e.to_string())?;
                if let Some(Change::AddFolders(paths)) = change.as_ref() {
                    for path in paths {
                        if !std::fs::metadata(path).is_ok_and(|m| m.is_dir()) {
                            return Err(lang
                                .text(
                                    "Der ausgewählte Ordner ist nicht verfügbar.",
                                    "The selected folder is unavailable.",
                                )
                                .into());
                        }
                    }
                }
                match change {
                    Some(change) => store.apply(&change),
                    None => store.load(),
                }
                .map_err(|e| e.to_string())
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                s.busy.set(false);
                match result {
                    Ok(settings) => {
                        *s.settings.borrow_mut() = settings;
                        s.ready.set(true);
                        s.feedback.set_text("");
                        s.feedback.set_visible(false);
                        s.bind();
                    }
                    Err(error) => {
                        s.feedback.set_text(&format!(
                            "{} {error}",
                            s.lang().text(
                                "Suchquellen konnten nicht gespeichert oder gelesen werden.",
                                "Search sources could not be saved or loaded."
                            )
                        ));
                        s.feedback.set_visible(true);
                        if s.ready.get() {
                            s.bind();
                        }
                    }
                }
                (s.changed)();
                s.run_next();
            },
        );
    }
    fn bind(&self) {
        let settings = self.settings.borrow().clone();
        self.changing.set(true);
        if let Some(root) = self.project.as_ref() {
            let p = settings.project(root);
            let names = p
                .sets
                .iter()
                .map(|set| {
                    if set.name.is_empty() {
                        self.lang()
                            .text("Gesamtes Projekt", "Entire project")
                            .to_owned()
                    } else {
                        set.name.clone()
                    }
                })
                .collect::<Vec<_>>();
            let labels = names.iter().map(String::as_str).collect::<Vec<_>>();
            self.sets.set_model(Some(&gtk::StringList::new(&labels)));
            self.sets
                .set_selected(p.sets.iter().position(|set| set.id == p.active).unwrap() as u32);
            self.sets.set_tooltip_text(Some(&format!(
                "{} — {}",
                names[self.sets.selected() as usize],
                p.selected().paths.join(", ")
            )));
            self.remove_set.set_sensitive(p.sets.len() > 1);
            self.filter.set_selected(u32::from(!p.known_text));
            self.known.set_active(p.known_text);
            if self.exclusions_generation.get() == 0 {
                self.excludes.set_text(&p.exclusions);
            }
        } else {
            self.model
                .splice(0, self.model.n_items(), &vec![""; settings.folders.len()]);
            self.scroll
                .set_min_content_height((settings.folders.len().clamp(1, 7) * 24) as i32);
            self.scroll.set_max_content_height(168);
            self.filter.set_selected(u32::from(!settings.known_text));
            self.known.set_active(settings.known_text);
        }
        self.list.set_sensitive(true);
        self.sets.set_sensitive(true);
        self.filter.set_sensitive(true);
        self.changing.set(false);
    }
}
