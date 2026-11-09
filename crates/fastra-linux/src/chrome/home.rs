use super::*;

pub(super) fn reset(ui: &Rc<Ui>, project: Option<std::path::PathBuf>) {
    crate::editor_options::startup::interrupt(ui);
    let documents = ui.documents.borrow().clone();
    if documents.len() == 1 && is_pristine(&documents[0]) && ui.project.borrow().is_none() {
        if let Some(path) = project {
            project_view::open_path(ui, path);
        }
        return;
    }
    let valid_ui = Rc::downgrade(ui);
    let members = documents.clone();
    let activate_ui = Rc::downgrade(ui);
    let selection = close_protocol::TabSelection {
        keep: None,
        valid: Rc::new(move || {
            valid_ui.upgrade().is_some_and(|ui| {
                let current = ui.documents.borrow();
                current.len() == members.len()
                    && current.iter().zip(&members).all(|(a, b)| Rc::ptr_eq(a, b))
            })
        }),
        activate: Rc::new(move |doc| {
            if let Some(ui) = activate_ui.upgrade() {
                tab_close::activate(&ui, doc);
            }
        }),
    };
    let weak = Rc::downgrade(ui);
    let previous = ui.active();
    close_protocol::prepare_tabs(
        ui,
        selection,
        Box::new(move |result| {
            let Some(ui) = weak.upgrade() else {
                return;
            };
            let Ok(permit) = result else {
                if let Some(doc) = previous {
                    tab_close::activate(&ui, &doc);
                    tab_close::focus(&ui, &doc);
                }
                return;
            };
            // Sämtliche Antworten gelten derselben Dokumentmenge. Erst nach der
            // abschließenden Prüfung wird synchron umgeschaltet, niemals tabweise.
            if !permit.valid() || !permit.documents_valid() {
                permit.cancel();
                return;
            }
            permit.freeze();
            if !permit.valid() || !permit.documents_valid() {
                permit.cancel();
                return;
            }
            ui.add_document(ui.lang.text("Unbenannt", "Untitled"), "");
            let scratch = ui.active().unwrap();
            tab_close::remove_approved_others(&ui, &scratch, &documents);
            let old_project = ui.project.borrow_mut().take();
            if let Some(state) = old_project {
                state.close_for_transition();
            }
            if let Some(shell) = ui.chrome.borrow().as_ref() {
                while let Some(child) = shell.sidebar.first_child() {
                    shell.sidebar.remove(&child);
                }
                shell.sidebar.set_visible(false);
                shell.sidebar_toggle.set_sensitive(false);
            }
            ui.scope.set_selected(0);
            permit.cancel();
            tab_close::focus(&ui, &scratch);
            if let Some(path) = project {
                project_view::open_path(&ui, path);
            }
            refresh(&ui);
        }),
    );
}

#[cfg(debug_assertions)]
pub(crate) mod selftest;
