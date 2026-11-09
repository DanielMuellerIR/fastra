//! Vorlagenauswahl liest die gemeinsame Sammlung frisch und füllt nur das Besitzerformular.
use super::*;
#[cfg(debug_assertions)]
pub(super) mod selftest;
use fastra_workflow::patterns::{self, Pattern, Store};
use std::rc::Weak;
use unicode_segmentation::UnicodeSegmentation;

pub(super) struct Menu {
    ui: Weak<Ui>,
    owner: glib::WeakRef<gtk::Window>,
    button: glib::WeakRef<gtk::MenuButton>,
    model: gio::Menu,
    action: gio::SimpleAction,
    values: RefCell<Vec<(Pattern, bool)>>,
    busy: Cell<bool>,
}
pub(super) fn library_changed<'a>(ui: &Ui, values: impl Iterator<Item = (&'a Pattern, bool)>) {
    let id = ui.template_choice.borrow().as_ref().map(|p| p.0.clone());
    if let Some(id) = id {
        *ui.template_choice.borrow_mut() =
            values
                .into_iter()
                .find(|(p, _)| p.id == id)
                .map(|(p, builtin)| {
                    (
                        p.id.clone(),
                        if builtin {
                            pattern_view::builtin_title(p, ui.lang)
                        } else {
                            p.name.clone()
                        },
                    )
                });
        refresh_caption(ui);
    }
}
pub(super) fn adopt(ui: &Ui, pattern: &Pattern, builtin: bool) {
    let title = if builtin {
        pattern_view::builtin_title(pattern, ui.lang)
    } else {
        pattern.name.clone()
    };
    *ui.template_choice.borrow_mut() = Some((pattern.id.clone(), title));
    refresh_caption(ui);
    ui.invalidate();
    ui.find.set_text(&pattern.regex);
    if let Some(replacement) = &pattern.default_replacement {
        ui.replace.set_text(replacement);
    }
    ui.mode.set_selected(2);
}
fn refresh_caption(ui: &Ui) {
    let choice = ui.template_choice.borrow();
    let title = choice
        .as_ref()
        .map_or(ui.lang.text("Vorlage", "Template"), |p| &p.1);
    let characters = title.graphemes(true).collect::<Vec<_>>();
    let caption = if characters.len() <= 24 {
        title.to_owned()
    } else {
        format!(
            "{}…{}",
            characters[..12].concat(),
            characters[characters.len() - 11..].concat()
        )
    };
    ui.template_menus.borrow_mut().retain(|menu| {
        if let Some(button) = menu.button.upgrade() {
            button.set_label(&caption);
            button.set_tooltip_text(Some(title));
            true
        } else {
            false
        }
    });
}
pub(super) fn controls(ui: &Rc<Ui>, owner: &gtk::Window) -> gtk::Box {
    let root = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let button = gtk::MenuButton::new();
    button.set_widget_name("fastra-template-menu");
    button.add_css_class("search-template");
    let model = gio::Menu::new();
    model.append(
        Some(
            ui.lang
                .text("Vorlagen werden geladen…", "Loading templates…"),
        ),
        None,
    );
    let popover = gtk::PopoverMenu::from_model(Some(&model));
    button.set_popover(Some(&popover));
    let action =
        gio::SimpleAction::new_stateful("choose", Some(glib::VariantTy::STRING), &"".to_variant());
    let group = gio::SimpleActionGroup::new();
    group.add_action(&action);
    let manage = gio::SimpleAction::new("manage", None);
    let weak = Rc::downgrade(ui);
    manage.connect_activate(move |_, _| {
        if let Some(ui) = weak.upgrade() {
            pattern_view::show(&ui);
        }
    });
    group.add_action(&manage);
    button.insert_action_group("template", Some(&group));
    let menu = Rc::new(Menu {
        ui: Rc::downgrade(ui),
        owner: owner.downgrade(),
        button: button.downgrade(),
        model,
        action: action.clone(),
        values: RefCell::new(Vec::new()),
        busy: Cell::new(false),
    });
    let weak = Rc::downgrade(&menu);
    popover.connect_visible_notify(move |popover| {
        if popover.is_visible() {
            if let Some(menu) = weak.upgrade() {
                menu.load();
            }
        }
    });
    let weak = Rc::downgrade(&menu);
    action.connect_activate(move |_, value| {
        if let (Some(menu), Some(id)) = (weak.upgrade(), value.and_then(|v| v.str())) {
            menu.choose(id);
        }
    });
    ui.template_menus.borrow_mut().push(menu);
    refresh_caption(ui);
    root.append(&button);
    let settings = chrome::icon(
        "fastra-sliders-symbolic",
        ui.lang.text("Vorlagen verwalten…", "Manage templates…"),
    );
    settings.set_widget_name("fastra-template-manage");
    let weak = Rc::downgrade(ui);
    settings.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            pattern_view::show(&ui);
        }
    });
    root.append(&settings);
    root
}
impl Menu {
    fn load(self: &Rc<Self>) {
        if self.busy.replace(true) {
            return;
        }
        self.action.set_enabled(false);
        let weak = Rc::downgrade(self);
        let lang = self.ui.upgrade().map_or(Language(false), |ui| ui.lang);
        git_view::background(
            move || {
                (|| {
                    let cancel = Cancellation::default();
                    let mut values = patterns::builtins()?
                        .into_iter()
                        .map(|p| (p, true))
                        .collect::<Vec<_>>();
                    let snapshot = Store::open(&pattern_view::config()?)?.load(&cancel)?;
                    values.extend(snapshot.collection.0.into_iter().map(|p| (p, false)));
                    Ok::<_, fastra_workflow::Error>(values)
                })()
                .map_err(|error| pattern_view::message(&error, lang))
            },
            move |result| {
                let Some(menu) = weak.upgrade() else {
                    return;
                };
                menu.busy.set(false);
                menu.model.remove_all();
                match result {
                    Ok(values) => {
                        if let Some(ui) = menu.ui.upgrade() {
                            library_changed(&ui, values.iter().map(|(p, builtin)| (p, *builtin)));
                        }
                        *menu.values.borrow_mut() = values;
                        menu.populate();
                        menu.action.set_enabled(true);
                        let weak = Rc::downgrade(&menu);
                        glib::timeout_add_local_once(Duration::from_millis(40), move || {
                            if let Some(popover) = weak
                                .upgrade()
                                .and_then(|m| m.button.upgrade())
                                .and_then(|b| b.popover())
                                .filter(|p| p.is_visible())
                            {
                                // Der vorherige Ladehinweis war deaktiviert; die neue Liste braucht nach dem Layout den Tastaturfokus.
                                popover.child_focus(gtk::DirectionType::TabForward);
                            }
                        });
                    }
                    Err(error) => {
                        menu.values.borrow_mut().clear();
                        if let Some(ui) = menu.ui.upgrade() {
                            ui.status.set_text(&error);
                            menu.model.append(
                                Some(ui.lang.text(
                                    "Sammlung nicht verfügbar – Verwaltung öffnen…",
                                    "Collection unavailable – open manager…",
                                )),
                                Some("template.manage"),
                            );
                        }
                    }
                }
            },
        );
    }
    fn populate(&self) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let id = ui
            .template_choice
            .borrow()
            .as_ref()
            .map(|p| p.0.clone())
            .unwrap_or_default();
        self.action.set_state(&id.to_variant());
        let item = gio::MenuItem::new(Some(ui.lang.text("— Keine —", "— None —")), None);
        item.set_action_and_target_value(Some("template.choose"), Some(&"".to_variant()));
        self.model.append_item(&item);
        let values = self.values.borrow();
        for category in patterns::CATEGORIES
            .iter()
            .copied()
            .chain(std::iter::once("own"))
        {
            let section = gio::Menu::new();
            for (p, builtin) in values.iter().filter(|(p, builtin)| {
                if category == "own" {
                    !builtin
                } else {
                    *builtin && p.category == category
                }
            }) {
                let title = if *builtin {
                    pattern_view::builtin_title(p, ui.lang)
                } else {
                    p.name.clone()
                };
                let item = gio::MenuItem::new(Some(&title), None);
                item.set_action_and_target_value(Some("template.choose"), Some(&p.id.to_variant()));
                section.append_item(&item);
            }
            if section.n_items() > 0 {
                let title = if category == "own" {
                    ui.lang.text("Eigene Vorlagen", "User templates")
                } else {
                    pattern_view::category_title(category, ui.lang)
                };
                self.model.append_section(Some(title), &section);
            }
        }
        let section = gio::Menu::new();
        section.append(
            Some(ui.lang.text("Vorlagen verwalten…", "Manage templates…")),
            Some("template.manage"),
        );
        self.model.append_section(None, &section);
    }
    fn choose(self: &Rc<Self>, id: &str) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        if self.busy.get() {
            return;
        }
        if id.is_empty() {
            ui.template_choice.borrow_mut().take();
            refresh_caption(&ui);
            self.action.set_state(&"".to_variant());
            return;
        }
        let Some((pattern, builtin)) = self
            .values
            .borrow()
            .iter()
            .find(|(p, _)| p.id == id)
            .cloned()
        else {
            return;
        };
        let generation = ui.generation.get();
        self.busy.set(true);
        self.action.set_enabled(false);
        let weak = Rc::downgrade(self);
        let lang = ui.lang;
        git_view::background(
            move || {
                pattern
                    .usable(&Cancellation::default())
                    .map(|_| pattern)
                    .map_err(|error| pattern_view::message(&error, lang))
            },
            move |result| {
                let Some(menu) = weak.upgrade() else {
                    return;
                };
                menu.busy.set(false);
                menu.action.set_enabled(true);
                let Some(ui) = menu
                    .ui
                    .upgrade()
                    .filter(|_| menu.owner.upgrade().is_some_and(|w| w.is_visible()))
                else {
                    return;
                };
                match result {
                Ok(pattern) if ui.generation.get() == generation => {
                    adopt(&ui, &pattern, builtin);
                    menu.action.set_state(&pattern.id.to_variant());
                }
                Ok(_) => ui.status.set_text(ui.lang.text("Suchformular inzwischen geändert. Vorlage erneut wählen; nichts übernommen.", "The search form changed meanwhile. Choose the template again; nothing was adopted.")),
                Err(error) => ui.status.set_text(&error),
            }
            },
        );
    }
}
