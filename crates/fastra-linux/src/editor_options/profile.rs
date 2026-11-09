use super::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, VecDeque};

#[derive(Clone, Default, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub(super) struct Patch {
    pub(super) tab: Option<u32>,
    pub(super) indent: Option<i32>,
    pub(super) spaces: Option<bool>,
    pub(super) wrap: Option<bool>,
    pub(super) wrap_target: Option<super::soft_wrap::Target>,
    pub(super) wrap_column: Option<u32>,
    pub(super) wrap_indentation: Option<super::soft_wrap::Indentation>,
}
impl Patch {
    fn merge(&mut self, other: &Self) {
        if other.wrap_target.is_some() {
            self.wrap_target = other.wrap_target;
        }
        if other.wrap_column.is_some() {
            self.wrap_column = other.wrap_column;
        }
        if other.wrap_indentation.is_some() {
            self.wrap_indentation = other.wrap_indentation;
        }
        if other.tab.is_some() {
            self.tab = other.tab;
        }
        if other.indent.is_some() {
            self.indent = other.indent;
        }
        if other.spaces.is_some() {
            self.spaces = other.spaces;
        }
        if other.wrap.is_some() {
            self.wrap = other.wrap;
        }
    }
    fn valid(&self) -> bool {
        self.wrap_column.is_none_or(|n| (20..=500).contains(&n))
            && self.tab.is_none_or(|n| (1..=16).contains(&n))
            && self.indent.is_none_or(|n| (1..=16).contains(&n))
    }
    fn factory(key: &str) -> Self {
        Self {
            tab: Some(4),
            indent: Some(4),
            spaces: Some(true),
            wrap_target: Some(super::soft_wrap::Target::Window),
            wrap_column: Some(80),
            wrap_indentation: Some(super::soft_wrap::Indentation::FirstLine),
            wrap: Some(matches!(
                key,
                "plain-text" | "html" | "json" | "markdown" | "xml" | "diff" | "file-comparison"
            )),
        }
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    version: u32,
    formats: BTreeMap<String, Patch>,
    #[serde(default, skip_serializing_if = "super::page_guide::Patch::empty")]
    guide: super::page_guide::Patch,
}
fn read(store: &store::Store) -> Result<Payload, String> {
    let Some(bytes) = store.bytes("profiles.json")? else {
        return Ok(Payload {
            version: 1,
            formats: BTreeMap::new(),
            guide: super::page_guide::Patch::default(),
        });
    };
    let payload: Payload = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    if !payload.guide.valid()
        || !(1..=2).contains(&payload.version)
        || payload.formats.len() > 300
        || payload
            .formats
            .iter()
            .any(|(k, p)| k.is_empty() || k.len() > 128 || k.contains('\0') || !p.valid())
    {
        return Err("Invalid editor profiles; existing data retained".into());
    }
    Ok(payload)
}
pub(super) fn get(root: &std::path::Path, key: &str) -> Result<Patch, String> {
    let store = store::Store::open(root)?;
    let _lock = store.wait_lock()?;
    let mut result = Patch::factory(key);
    if let Some(profile) = read(&store)?.formats.get(key) {
        result.merge(profile);
    }
    Ok(result)
}
fn set(root: &std::path::Path, key: &str, patch: &Patch) -> Result<(), String> {
    let store = store::Store::open(root)?;
    let lock = store.wait_lock()?;
    let mut payload = read(&store)?;
    if key.is_empty() || key.len() > 128 || key.contains('\0') || !patch.valid() {
        return Err("Invalid editor profile".into());
    }
    payload
        .formats
        .entry(key.to_owned())
        .or_default()
        .merge(patch);
    if payload.formats.len() > 300 {
        return Err("Editor profile limit reached".into());
    }
    payload.version = 2;
    let bytes = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
    store.write("profiles.json", &bytes, &lock)
}
pub(super) fn get_guide(root: &std::path::Path) -> Result<super::page_guide::Patch, String> {
    let store = store::Store::open(root)?;
    let _lock = store.wait_lock()?;
    Ok(read(&store)?.guide)
}
fn set_guide(root: &std::path::Path, patch: &super::page_guide::Patch) -> Result<(), String> {
    if !patch.valid() {
        return Err("Invalid page guide".into());
    }
    let store = store::Store::open(root)?;
    let lock = store.wait_lock()?;
    let mut payload = read(&store)?;
    payload.guide.merge(patch);
    payload.version = 2;
    let bytes = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
    store.write("profiles.json", &bytes, &lock)
}
#[derive(Clone)]
enum Change {
    Format { key: String, patch: Patch },
    Guide(super::page_guide::Patch),
}
#[derive(Clone)]
struct Write {
    change: Change,
    owner: Weak<Options>,
}
thread_local! {
    static OWNERS: RefCell<Vec<Weak<Options>>> = const { RefCell::new(Vec::new()) };
    // Feldweise Überlagerung schützt neue Tabs auch während einer noch laufenden Speicherung.
    static EDITS: RefCell<HashMap<String,Patch>> = RefCell::new(HashMap::new());
    static WRITES: RefCell<VecDeque<Write>> = const { RefCell::new(VecDeque::new()) };
    static WRITING: Cell<bool> = const { Cell::new(false) };
    static CLOSE_HELD: Cell<bool> = const { Cell::new(false) };
    static WRITE_ERROR: RefCell<Option<String>> = const {RefCell::new(None)};
}
pub(super) fn pending() -> bool {
    WRITING.with(Cell::get) || WRITES.with(|q| !q.borrow().is_empty())
}
pub(super) fn guide_status() -> (bool, bool, Option<String>) {
    (WRITING.with(Cell::get), pending(), WRITE_ERROR.with(|slot| slot.borrow().clone()))
}
pub(super) fn retry() {
    next_write();
}
pub(super) fn owners() -> Vec<Rc<Options>> {
    OWNERS.with(|owners| owners.borrow().iter().filter_map(Weak::upgrade).collect())
}
fn notify_held(error: Option<&str>) {
    for owner in owners() {
        if let Some(ui) = owner.ui.upgrade().filter(|ui| ui.window.is_visible()) {
            let message = ui.lang.text(
                "Formatprofile konnten noch nicht gespeichert werden. Schließen bleibt angehalten.",
                "Format profiles have not been saved yet. Close remains held.",
            );
            ui.status.set_text(
                &error.map_or_else(|| message.to_owned(), |error| format!("{message} {error}")),
            );
        }
    }
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    CLOSE_HELD.with(|held| held.set(true));
    let error = WRITE_ERROR.with(|error| error.borrow().clone());
    let message=ui.lang.text("Formatprofile werden noch gespeichert. Schließen angehalten; nach Abschluss erneut wählen.","Format profiles are still being saved. Close held; request it again after completion.");
    ui.status
        .set_text(&error.map_or_else(|| message.to_owned(), |error| format!("{message} {error}")));
    // Ein fehlgeschlagener Auftrag bleibt erhalten und wird nur ausdrücklich erneut versucht.
    next_write();
    false
}
fn finish_write(result: Result<(), String>) {
    WRITING.with(|writing| writing.set(false));
    if let Err(error) = result {
        WRITE_ERROR.with(|slot| *slot.borrow_mut() = Some(error.clone()));
        super::page_guide::refresh_forms();
        if CLOSE_HELD.with(Cell::get) {
            notify_held(Some(&error));
        } else if let Some(owner) =
            WRITES.with(|q| q.borrow().front().and_then(|write| write.owner.upgrade()))
        {
            owner.report(error);
        }
        return;
    }
    WRITES.with(|q| q.borrow_mut().pop_front());
    EDITS.with(|edits| {
        let mut edits = edits.borrow_mut();
        edits.clear();
        WRITES.with(|queue| {
            for write in queue.borrow().iter() {
                if let Change::Format { key, patch } = &write.change {
                    edits.entry(key.clone()).or_default().merge(patch);
                }
            }
        });
    });
    if !pending() {
        WRITE_ERROR.with(|slot| slot.borrow_mut().take());
        if CLOSE_HELD.with(|held| held.replace(false)) {
            for owner in owners() {
                if let Some(ui) = owner.ui.upgrade().filter(|ui| ui.window.is_visible()) {
                    ui.status.set_text(ui.lang.text(
                        "Formatprofile gespeichert. Schließen kann erneut gewählt werden.",
                        "Format profiles saved. Close can be requested again.",
                    ));
                }
            }
        }
    }
    next_write();
}
fn next_write() {
    if WRITING.with(|w| w.replace(true)) {
        return;
    }
    let Some(write) = WRITES.with(|q| q.borrow().front().cloned()) else {
        WRITING.with(|w| w.set(false));
        super::page_guide::refresh_forms();
        return;
    };
    super::page_guide::refresh_forms();
    let held = gtk::gio::Application::default().map(|app| app.hold());
    super::super::git_view::background(
        move || match write.change {
            Change::Format { key, patch } => set(&config_root()?, &key, &patch),
            Change::Guide(patch) => set_guide(&config_root()?, &patch),
        },
        move |result| {
            let receipt = move || {
                let _held = held;
                finish_write(result);
            };
            #[cfg(debug_assertions)]
            if let Some(root) = std::env::var_os("FASTRA_PROFILE_WRITE_TEST_DIR").map(PathBuf::from)
            {
                if root.join("pause-main").exists() {
                    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                    std::fs::write(
                        root.join("ready-main"),
                        b"worker returned; Main receipt pending",
                    )
                    .unwrap();
                    let mut receipt = Some(receipt);
                    let start = std::time::Instant::now();
                    glib::timeout_add_local(std::time::Duration::from_millis(20), move || {
                        assert!(start.elapsed() < std::time::Duration::from_secs(30));
                        if root.join("release-main").exists() {
                            receipt.take().unwrap()();
                            glib::ControlFlow::Break
                        } else {
                            glib::ControlFlow::Continue
                        }
                    });
                    return;
                }
            }
            receipt();
        },
    );
}
pub(super) fn queue_guide(state: Option<&Rc<Options>>, patch: super::page_guide::Patch) {
    WRITES.with(|q| {
        q.borrow_mut().push_back(Write {
            change: Change::Guide(patch),
            owner: state.map_or_else(Weak::new, Rc::downgrade),
        })
    });
    next_write();
}
pub(super) fn install(state: &Rc<Options>) {
    OWNERS.with(|owners| {
        let mut owners = owners.borrow_mut();
        owners.retain(|w| w.strong_count() > 0);
        owners.push(Rc::downgrade(state));
    });
    let weak = Rc::downgrade(state);
    if let Some(doc) = state.doc.upgrade() {
        doc.buffer.connect_language_notify(move |_| {
            if let Some(state) = weak.upgrade() {
                state.load_profile();
            }
        });
    }
    state.load_profile();
}
impl Options {
    fn format_key(&self) -> String {
        if self.doc.upgrade().is_some_and(|doc| doc.comparison.borrow().is_some()) {
            return "file-comparison".into();
        }
        self.doc
            .upgrade()
            .and_then(|d| d.buffer.language())
            .map(|l| l.id().to_string())
            .unwrap_or_else(|| "plain-text".into())
    }
    fn apply_profile(&self, profile: &Patch) {
        let updating = self.updating.replace(true);
        for view in self.views.iter().filter_map(|v| v.upgrade()) {
            if let Some(n) = profile.tab {
                if view.tab_width() != n {
                    view.set_tab_width(n);
                }
            }
            if let Some(n) = profile.indent {
                if view.indent_width() != n {
                    view.set_indent_width(n);
                }
            }
            if let Some(v) = profile.spaces {
                if view.is_insert_spaces_instead_of_tabs() != v {
                    view.set_insert_spaces_instead_of_tabs(v);
                }
            }
            if let Some(v) = profile.wrap {
                view.set_wrap_mode(if v {
                    gtk::WrapMode::WordChar
                } else {
                    gtk::WrapMode::None
                });
            }
        }
        if let Some(enabled)=profile.wrap {
            if let Some(doc)=self.doc.upgrade(){if let Some(comparison)=doc.comparison.borrow().as_ref(){comparison.set_wrap(enabled);}}
        }
        if let Some(w) = self.wrap_widget.borrow().as_ref().and_then(|w| w.upgrade()) {
            if let Some(v) = profile.wrap {
                w.set_active(v);
            }
        }
        for (widget, kind) in self.profile_spins.borrow().iter() {
            if let Some(w) = widget.upgrade() {
                let v = if *kind == 0 {
                    profile.tab.map(|v| v as f64)
                } else {
                    profile.indent.map(|v| v as f64)
                };
                if let Some(v) = v {
                    w.set_value(v);
                }
            }
        }
        if let Some(w) = self
            .spaces_widget
            .borrow()
            .as_ref()
            .and_then(|w| w.upgrade())
        {
            if let Some(v) = profile.spaces {
                w.set_active(v);
            }
        }
        self.soft_wrap.update(profile);
        super::soft_wrap::sync_controls(self);
        self.updating.set(updating);
        self.profile_readiness();
    }
    pub(super) fn profile_readiness(&self) {
        let ready = !self.language_pending.get();
        super::soft_wrap::readiness(self, ready);
        let spaces = self
            .views
            .iter()
            .find_map(|v| v.upgrade())
            .is_none_or(|v| v.is_insert_spaces_instead_of_tabs());
        for (widget, kind) in self.profile_spins.borrow().iter() {
            if let Some(widget) = widget.upgrade() {
                widget.set_sensitive(ready && (*kind == 0 || spaces));
            }
        }
        if let Some(widget) = self
            .spaces_widget
            .borrow()
            .as_ref()
            .and_then(|w| w.upgrade())
        {
            widget.set_sensitive(ready);
        }
        if let Some(widget) = self.wrap_widget.borrow().as_ref().and_then(|w| w.upgrade()) {
            widget.set_sensitive(ready);
            let ui = self.ui.upgrade();
            widget.set_tooltip_text(if ready {
                None
            } else {
                ui.as_ref().map(|ui| {
                    ui.lang.text(
                        "Syntaxformat wird wiederhergestellt …",
                        "Restoring syntax format …",
                    )
                })
            });
        }
        if let Some(label) = self
            .profile_status
            .borrow()
            .as_ref()
            .and_then(|w| w.upgrade())
        {
            label.set_visible(!ready);
        }
    }
    pub(super) fn begin_language_read(&self) -> u64 {
        self.language_read
            .set(self.language_read.get().wrapping_add(1));
        self.language_pending.set(true);
        self.profile_generation
            .set(self.profile_generation.get().wrapping_add(1));
        self.profile_key.borrow_mut().clear();
        self.profile_readiness();
        self.language_read.get()
    }
    pub(super) fn finish_language_read(&self) {
        self.language_read
            .set(self.language_read.get().wrapping_add(1));
        self.language_pending.set(false);
        self.profile_readiness();
    }
    pub(super) fn load_profile(self: &Rc<Self>) {
        if self.language_pending.get() {
            return;
        }
        let key = self.format_key();
        if *self.profile_key.borrow() == key {
            return;
        }
        *self.profile_key.borrow_mut() = key.clone();
        self.profile_generation
            .set(self.profile_generation.get().wrapping_add(1));
        let generation = self.profile_generation.get();
        *self.profile_edits.borrow_mut() =
            EDITS.with(|edits| edits.borrow().get(&key).cloned().unwrap_or_default());
        let mut factory = Patch::factory(&key);
        factory.merge(&self.profile_edits.borrow());
        self.apply_profile(&factory);
        let weak = Rc::downgrade(self);
        super::super::git_view::background(
            move || get(&config_root()?, &key),
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                state.finish_profile(generation, result);
            },
        );
    }
    pub(super) fn finish_profile(&self, generation: u64, result: Result<Patch, String>) -> bool {
        if self.profile_generation.get() != generation {
            return false;
        }
        match result {
            Ok(mut profile) => {
                profile.merge(&self.profile_edits.borrow());
                self.apply_profile(&profile);
            }
            Err(error) => self.report(error),
        }
        true
    }
    pub(super) fn change_profile(self: &Rc<Self>, patch: Patch) {
        if self.updating.get()
            || self.language_pending.get()
            || self.profile_key.borrow().is_empty()
        {
            return;
        }
        let key = self.profile_key.borrow().clone();
        EDITS.with(|edits| {
            edits
                .borrow_mut()
                .entry(key.clone())
                .or_default()
                .merge(&patch)
        });
        let owners = OWNERS.with(|owners| {
            owners
                .borrow()
                .iter()
                .filter_map(Weak::upgrade)
                .collect::<Vec<_>>()
        });
        for owner in owners {
            if *owner.profile_key.borrow() == key {
                owner.profile_edits.borrow_mut().merge(&patch);
                owner.apply_profile(&patch);
            }
        }
        WRITES.with(|q| {
            q.borrow_mut().push_back(Write {
                change: Change::Format { key, patch },
                owner: Rc::downgrade(self),
            })
        });
        next_write();
    }
}
pub(super) fn wrap(doc: &Document, widget: &gtk::CheckButton) {
    let Some(state) = doc.editor_options.borrow().clone() else {
        return;
    };
    *state.wrap_widget.borrow_mut() = Some(widget.downgrade());
    widget.set_active(
        state
            .views
            .iter()
            .find_map(|v| v.upgrade())
            .is_some_and(|v| v.wrap_mode() != gtk::WrapMode::None),
    );
    let weak = Rc::downgrade(&state);
    state.profile_readiness();
    widget.connect_toggled(move |button| {
        if let Some(state) = weak.upgrade() {
            state.change_profile(Patch {
                wrap: Some(button.is_active()),
                ..Patch::default()
            });
        }
    });
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn independent_fields_fresh_merge_and_legacy_languages() {
        let root = tempfile::tempdir().unwrap();
        let path = std::path::Path::new("/old");
        store::set(root.path(), path, Some("rust")).unwrap();
        let old = std::fs::read(root.path().join("fastra-editor/languages.json")).unwrap();
        set(
            root.path(),
            "rust",
            &Patch {
                tab: Some(8),
                ..Patch::default()
            },
        )
        .unwrap();
        set(
            root.path(),
            "rust",
            &Patch {
                indent: Some(2),
                ..Patch::default()
            },
        )
        .unwrap();
        set(
            root.path(),
            "markdown",
            &Patch {
                spaces: Some(false),
                ..Patch::default()
            },
        )
        .unwrap();
        let p = get(root.path(), "rust").unwrap();
        assert_eq!(p.tab, Some(8));
        assert_eq!(p.indent, Some(2));
        assert_eq!(p.spaces, Some(true));
        assert_eq!(p.wrap, Some(false));
        assert_eq!(
            std::fs::read(root.path().join("fastra-editor/languages.json")).unwrap(),
            old
        );
        assert_eq!(
            store::get(root.path(), path).unwrap().as_deref(),
            Some("rust")
        );
        assert_eq!(get(root.path(), "markdown").unwrap().spaces, Some(false));
    }
    #[test]
    fn invalid_width_does_not_replace_valid_profile() {
        let root = tempfile::tempdir().unwrap();
        set(
            root.path(),
            "rust",
            &Patch {
                tab: Some(8),
                ..Patch::default()
            },
        )
        .unwrap();
        assert!(
            set(
                root.path(),
                "rust",
                &Patch {
                    indent: Some(0),
                    ..Patch::default()
                }
            )
            .is_err()
        );
        assert_eq!(get(root.path(), "rust").unwrap().tab, Some(8));
    }
    #[test]
    fn concurrent_windows_merge_independent_fields_and_language_writes() {
        let root = tempfile::tempdir().unwrap();
        store::Store::open(root.path()).unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
        std::thread::scope(|scope| {
            for patch in [
                Patch {
                    tab: Some(8),
                    ..Patch::default()
                },
                Patch {
                    indent: Some(2),
                    ..Patch::default()
                },
            ] {
                let barrier = barrier.clone();
                let path = root.path();
                scope.spawn(move || {
                    barrier.wait();
                    set(path, "rust", &patch).unwrap();
                });
            }
            barrier.wait();
            store::set(root.path(), std::path::Path::new("/legacy"), Some("rust")).unwrap();
        });
        let p = get(root.path(), "rust").unwrap();
        assert_eq!((p.tab, p.indent), (Some(8), Some(2)));
        assert_eq!(
            store::get(root.path(), std::path::Path::new("/legacy"))
                .unwrap()
                .as_deref(),
            Some("rust")
        );
        for (key, wrap) in [
            ("plain-text", true),
            ("markdown", true),
            ("diff", true),
            ("rust", false),
            ("future-language", false),
        ] {
            assert_eq!(get(root.path(), key).unwrap().wrap, Some(wrap));
        }
    }
    #[test]
    fn unsafe_profile_does_not_overwrite_its_target_or_language_choices() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        store::set(root.path(), std::path::Path::new("/legacy"), Some("rust")).unwrap();
        let target = root.path().join("target");
        std::fs::write(&target, b"keep").unwrap();
        symlink(&target, root.path().join("fastra-editor/profiles.json")).unwrap();
        assert!(
            set(
                root.path(),
                "rust",
                &Patch {
                    tab: Some(8),
                    ..Patch::default()
                }
            )
            .is_err()
        );
        assert_eq!(std::fs::read(target).unwrap(), b"keep");
        assert_eq!(
            store::get(root.path(), std::path::Path::new("/legacy"))
                .unwrap()
                .as_deref(),
            Some("rust")
        );
    }
}

#[cfg(test)]
mod guide_tests {
    use super::super::page_guide::Patch as Guide;
    use super::*;
    #[test]
    fn guide_merges_app_fields_formats_and_legacy_languages() {
        let root = tempfile::tempdir().unwrap();
        store::set(root.path(), std::path::Path::new("/legacy"), Some("rust")).unwrap();
        let language = std::fs::read(root.path().join("fastra-editor/languages.json")).unwrap();
        set(
            root.path(),
            "rust",
            &Patch {
                tab: Some(2),
                ..Patch::default()
            },
        )
        .unwrap();
        assert_eq!(get_guide(root.path()).unwrap(), Guide::default());
        set_guide(
            root.path(),
            &Guide {
                column: Some(120),
                visible: None,
            },
        )
        .unwrap();
        set(
            root.path(),
            "markdown",
            &Patch {
                indent: Some(8),
                ..Patch::default()
            },
        )
        .unwrap();
        set_guide(
            root.path(),
            &Guide {
                column: None,
                visible: Some(true),
            },
        )
        .unwrap();
        assert_eq!(
            get_guide(root.path()).unwrap(),
            Guide {
                column: Some(120),
                visible: Some(true)
            }
        );
        assert_eq!(get(root.path(), "rust").unwrap().tab, Some(2));
        assert_eq!(get(root.path(), "markdown").unwrap().indent, Some(8));
        assert_eq!(
            std::fs::read(root.path().join("fastra-editor/languages.json")).unwrap(),
            language
        );
        let before = std::fs::read(root.path().join("fastra-editor/profiles.json")).unwrap();
        for column in [0, 19, 501, u32::MAX] {
            assert!(
                set_guide(
                    root.path(),
                    &Guide {
                        column: Some(column),
                        visible: None
                    }
                )
                .is_err()
            );
        }
        assert_eq!(
            std::fs::read(root.path().join("fastra-editor/profiles.json")).unwrap(),
            before
        );
    }
}

#[cfg(test)]
mod wrap_tests {
    use super::super::soft_wrap::{Indentation, Target};
    use super::*;
    #[test]
    fn v1_migrates_only_on_write_and_keeps_fields_and_guide() {
        let root = tempfile::tempdir().unwrap();
        set(
            root.path(),
            "rust",
            &Patch {
                tab: Some(8),
                ..Default::default()
            },
        )
        .unwrap();
        let path = root.path().join("fastra-editor/profiles.json");
        std::fs::write(&path,br#"{"version":1,"formats":{"rust":{"tab":8,"wrap":true}},"guide":{"column":120,"visible":true}}"#).unwrap();
        let before = std::fs::read(&path).unwrap();
        let legacy = get(root.path(), "rust").unwrap();
        assert_eq!(legacy.tab, Some(8));
        assert_eq!(legacy.wrap_target, Some(Target::Window));
        assert_eq!(legacy.wrap_indentation, Some(Indentation::FirstLine));
        assert_eq!(std::fs::read(&path).unwrap(), before);
        set(
            root.path(),
            "rust",
            &Patch {
                wrap_target: Some(Target::FixedColumn),
                wrap_column: Some(20),
                wrap_indentation: Some(Indentation::Reverse),
                ..Default::default()
            },
        )
        .unwrap();
        let p = get(root.path(), "rust").unwrap();
        assert_eq!(p.tab, Some(8));
        assert_eq!(p.wrap, Some(true));
        assert_eq!(p.wrap_column, Some(20));
        assert_eq!(p.wrap_indentation, Some(Indentation::Reverse));
        assert_eq!(get_guide(root.path()).unwrap().column, Some(120));
        let payload: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(payload["version"], 2);
        let before = std::fs::read(&path).unwrap();
        for column in [0, 19, 501, u32::MAX] {
            assert!(set(
                root.path(),
                "rust",
                &Patch {
                    wrap_column: Some(column),
                    ..Default::default()
                }
            )
            .is_err());
        }
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(
            get(root.path(), "markdown").unwrap().wrap_target,
            Some(Target::Window)
        );
    }
}
