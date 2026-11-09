use super::*;
use std::{fs::OpenOptions, io::Read, os::unix::fs::OpenOptionsExt, path::Path};
fn read_archive(path: &Path, cancel: &Cancellation) -> Result<Vec<u8>, Error> {
    cancel.check()?;
    let path = std::fs::canonicalize(path)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > patterns::MAX_BYTES as u64 {
        return Err(Error::Limit);
    }
    let mut bytes = Vec::new();
    file.take(patterns::MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > patterns::MAX_BYTES {
        return Err(Error::Limit);
    }
    cancel.check()?;
    Ok(bytes)
}
fn json_text<T: serde::Serialize>(value: &T, lang: Language) -> Result<String, Error> {
    let text = serde_json::to_string_pretty(value)?;
    crate::text_limits::validate(&text, lang).map_err(Error::Invalid)?;
    Ok(text)
}
impl View {
    pub(super) fn inspect(self: &Rc<Self>) {
        let pattern = match self.read_draft() {
            Ok(p) => p,
            Err(e) => {
                self.status.set_text(&message(&e, self.lang));
                return;
            }
        };
        let lang = self.lang;
        self.run(false,move|cancel|{cancel.check()?;json_text(&pattern,lang)},|v,text|{let Some(ui)=v.ui.upgrade()else{return;};let dialog=window(&ui,v.lang.text("Vollständige Vorlagendefinition","Complete template definition"),true);dialog.set_transient_for(Some(&v.window));let body=column();body.append(&label(v.lang.text("Originale Felder einschließlich unbekannter Angaben. Diese Ansicht ändert nichts.","Original fields including unknown data. This view makes no changes.")));let view=git_view::output();view.buffer().set_text(&text);body.append(&git_view::scroll(&view));dialog.set_child(Some(&body));dialog.present();});
    }
    pub(super) fn import_file(self: &Rc<Self>) {
        self.busy.set(true);
        self.writing.set(true);
        self.refresh();
        let weak = Rc::downgrade(self);
        gtk::FileDialog::new().open(
            Some(&self.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Some(v) = weak.upgrade() else {
                    return;
                };
                v.busy.set(false);
                v.writing.set(false);
                let path = match result {
                    Ok(file) => match file.path() {
                        Some(path) => path,
                        None => {
                            v.status.set_text(v.lang.text(
                                "Bitte eine lokale JSON-Datei wählen.",
                                "Choose a local JSON file.",
                            ));
                            v.refresh();
                            return;
                        }
                    },
                    Err(_) => {
                        v.refresh();
                        return;
                    }
                };
                let Some(snapshot) = v.snapshot.borrow().clone() else {
                    return;
                };
                let lang = v.lang;
                v.run(
                    false,
                    move |cancel| {
                        let bytes = read_archive(&path, &cancel)?;
                        let incoming = Collection::decode(&bytes, &cancel)?;
                        let replacements = incoming
                            .0
                            .iter()
                            .filter(|p| snapshot.collection.0.iter().any(|old| old.id == p.id))
                            .count();
                        let merged = snapshot.collection.merged(&incoming, &cancel)?;
                        let text = json_text(&merged, lang)?;
                        Ok((merged, text, replacements))
                    },
                    |v, (merged, text, replacements)| v.confirm_import(merged, text, replacements),
                );
            },
        );
    }
    fn confirm_import(self: &Rc<Self>, merged: Collection, text: String, replacements: usize) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let dialog = window(
            &ui,
            self.lang.text(
                "Suchvorlagen vor Import prüfen",
                "Review search templates before import",
            ),
            true,
        );
        dialog.set_transient_for(Some(&self.window));
        let body = column();
        body.append(&label(&format!("{} {} · {} {}. {}",merged.0.len(),self.lang.text("Vorlagen nach Import","templates after import"),replacements,self.lang.text("bestehende IDs werden ersetzt","existing IDs will be replaced"),self.lang.text("Unten steht die vollständige resultierende Sammlung. Andere IDs bleiben erhalten; unbekannte Felder werden bewahrt. Formular und Dokument bleiben unverändert.","The complete resulting collection is below. Other IDs are retained; unknown fields are preserved. The form and document stay unchanged."))));
        let view = git_view::output();
        view.buffer().set_text(&text);
        body.append(&git_view::scroll(&view));
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let cancel = gtk::Button::with_label(self.lang.text("Abbrechen", "Cancel"));
        let accept =
            gtk::Button::with_label(self.lang.text("Sammlung importieren", "Import collection"));
        buttons.append(&cancel);
        buttons.append(&accept);
        body.append(&buttons);
        dialog.set_child(Some(&body));
        self.busy.set(true);
        self.writing.set(true);
        self.refresh();
        let copy = dialog.clone();
        cancel.connect_clicked(move |_| copy.close());
        let weak = Rc::downgrade(self);
        dialog.connect_close_request(move |_| {
            if let Some(v) = weak.upgrade() {
                v.busy.set(false);
                v.writing.set(false);
                v.refresh();
            }
            glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(self);
        let copy = dialog.clone();
        let collection = RefCell::new(Some(merged));
        accept.connect_clicked(move |_|{let Some(v)=weak.upgrade()else{return;};let Some(collection)=collection.borrow_mut().take()else{return;};let selected=collection.0.last().map(|p|p.id.clone());copy.close();v.save_collection(collection,selected,v.lang.text("Sammlung vollständig importiert. Suchformular und Dokument bleiben unverändert.","Collection imported completely. The search form and document stay unchanged."));});
        dialog.present();
    }
    pub(super) fn export_file(self: &Rc<Self>) {
        let Some(snapshot) = self.snapshot.borrow().clone() else {
            return;
        };
        let dialog = gtk::FileDialog::new();
        dialog.set_initial_name(Some("fastra-patterns.json"));
        self.busy.set(true);
        self.writing.set(true);
        self.refresh();
        let weak = Rc::downgrade(self);
        dialog.save(Some(&self.window),None::<&gio::Cancellable>,move|result|{let Some(v)=weak.upgrade()else{return;};v.busy.set(false);v.writing.set(false);let path=match result{Ok(file)=>match file.path(){Some(path)=>path,None=>{v.status.set_text(v.lang.text("Bitte ein lokales Ziel wählen.","Choose a local target."));v.refresh();return;}},Err(_)=>{v.refresh();return;}};let lang=v.lang;v.run(true,move|cancel|{let bytes=snapshot.collection.encode(&cancel)?;fastra_io::Transaction::save_new_document(&path,&bytes,&cancel).map(|_|()).map_err(|e|Error::Invalid(format!("{} {e}",lang.text("Export legt eine neue Datei an. Bei vorhandenem Ziel anderen Namen wählen.","Export creates a new file. Choose another name if the target exists."))))},|v,()|v.status.set_text(v.lang.text("Eigene Sammlung als originales Swift-Arrayformat exportiert; Zusatzfelder erhalten. Keine bestehende Datei überschrieben.","User collection exported in the original Swift array format; extra fields preserved. No existing file overwritten.")));});
    }
}
