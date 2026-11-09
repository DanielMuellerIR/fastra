use super::*;
use sourceview5::prelude::*;
use std::time::{Duration, Instant};
pub(super) struct View {
    pub(super) lang: Language,
    pub root: gtk::Box,
    pub transfer: [gtk::Button; 2],
    pub refresh: gtk::Button,
    pub export: gtk::Button,
    pub previous: gtk::Button,
    pub next: gtk::Button,
    pub status: gtk::Label,
    pub names: [gtk::Label; 2],
    pub selection: gtk::SingleSelection,
    pub texts: [sourceview5::View; 2],
    model: gtk::StringList,
    pub(super) list: gtk::ListView,
    position: gtk::Label,
    description: gtk::Label,
    count: gtk::Label,
    display: gtk::Box,
    list_scroll: gtk::ScrolledWindow,
    pub(super) viewport: gtk::ScrolledWindow,
    pub(super) vertical: gtk::Scrollbar,
    pub(super) ruler: ruler::Ruler,
    following_user_scroll: Cell<bool>,
    pub(super) data: RefCell<Option<Rc<presentation::Presentation>>>,
    pub(super) render: Cell<u64>,
    pub(super) ready: Cell<bool>,
    pub(super) alignment: alignment::Alignment,
    pub(super) folding: folding::Folding,
    screen: gtk::Stack,
    spinner: gtk::Spinner,
    message_icon: gtk::Image,
    message_title: gtk::Label,
    message_detail: gtk::Label,
    message_options: gtk::Label,
    option_summary: gtk::Label,
    actions: gtk::Box,
    transfer_divider: gtk::Separator,
    gutters: [sourceview5::GutterRendererText; 2],
    scroll_selection: Cell<bool>,
    scrolls: [gtk::ScrolledWindow; 2],
    pub(super) columns: Rc<columns::Columns>,
}
impl View {
    pub fn new(lang: Language, owner: &impl IsA<gtk::Window>) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.set_vexpand(true);
        root.add_css_class("file-comparison");
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        actions.set_margin_top(8);
        actions.set_margin_bottom(4);
        actions.set_margin_start(8);
        actions.set_margin_end(8);
        let transfer = [
            gtk::Button::with_label(lang.text("← Nach links", "← To left")),
            gtk::Button::with_label(lang.text("Nach rechts →", "To right →")),
        ];
        let refresh = gtk::Button::with_label(lang.text("Neu berechnen", "Recalculate"));
        for button in [&transfer[0], &transfer[1], &refresh] {
            actions.append(button);
        }
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        actions.append(&spacer);
        let description = gtk::Label::new(None);
        description.add_css_class("dim-label");
        actions.append(&description);
        root.append(&actions);
        let status = support::label(lang.text("Übernehmen ist nur in zugeordnete offene editierbare Dokumente möglich. Dateien werden dabei nicht gespeichert.", "Transfers require an associated open editable document. Files are not saved."));
        status.add_css_class("dim-label");
        status.set_margin_start(8);
        status.set_margin_end(8);
        status.set_margin_bottom(6);
        root.append(&status);
        let transfer_divider = gtk::Separator::new(gtk::Orientation::Horizontal);
        root.append(&transfer_divider);
        let display = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        header.set_margin_start(12);
        header.set_margin_end(8);
        header.set_margin_top(7);
        header.set_margin_bottom(7);
        let names = std::array::from_fn(|_| {
            gtk::Label::builder()
                .ellipsize(gtk::pango::EllipsizeMode::Middle)
                .max_width_chars(35)
                .build()
        });
        names[0].add_css_class("diff-left-name");
        names[1].add_css_class("diff-right-name");
        header.append(&names[0]);
        header.append(&gtk::Label::new(Some("⇄")));
        header.append(&names[1]);
        let option_summary = gtk::Label::new(None);
        option_summary.add_css_class("dim-label");
        option_summary.set_ellipsize(gtk::pango::EllipsizeMode::End);
        header.append(&option_summary);
        let space = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        space.set_hexpand(true);
        header.append(&space);
        let export = chrome::icon(
            "fastra-share-symbolic",
            lang.text("Vergleich exportieren …", "Export comparison …"),
        );
        header.append(&export);
        let position = gtk::Label::new(None);
        position.add_css_class("dim-label");
        header.append(&position);
        let previous = chrome::icon(
            "go-up-symbolic",
            lang.text("Voriger Unterschied (Alt+↑)", "Previous difference (Alt+↑)"),
        );
        let next = chrome::icon(
            "go-down-symbolic",
            lang.text("Nächster Unterschied (Alt+↓)", "Next difference (Alt+↓)"),
        );
        header.append(&previous);
        header.append(&next);
        display.append(&header);
        display.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let texts = std::array::from_fn(|_| {
            let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
            buffer.set_enable_undo(false);
            let view = sourceview5::View::with_buffer(&buffer);
            view.set_editable(false);
            view.set_monospace(true);
            view.set_wrap_mode(gtk::WrapMode::WordChar);
            view.set_show_line_numbers(false);
            view.set_left_margin(6);
            view.set_right_margin(6);
            view.set_top_margin(0);
            view.set_pixels_above_lines(4);
            view.set_pixels_below_lines(4);
            view.set_bottom_margin(4);
            view.add_css_class("source-editor");
            crate::source_appearance::install(&view, &buffer);
            view
        });
        let scrolls = texts.each_ref().map(support::scroll);
        for scroll in &scrolls {
            scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::External);
        }
        let syncing = Rc::new(Cell::new(false));
        for (source, target) in [(&scrolls[0], &scrolls[1]), (&scrolls[1], &scrolls[0])] {
            let target = target.vadjustment();
            let syncing = syncing.clone();
            source.vadjustment().connect_value_changed(move |source| {
                if !syncing.replace(true) {
                    target.set_value(source.value());
                    syncing.set(false);
                }
            });
        }
        let folding = folding::Folding::new(&scrolls);
        let columns = columns::Columns::new(&folding.overlays, lang);
        let model = gtk::StringList::new(&[]);
        let selection = gtk::SingleSelection::new(Some(model.clone()));
        let ruler = ruler::Ruler::new(lang, &selection);
        columns.widget.set_size_request(919, -1);
        let viewport = gtk::ScrolledWindow::new();
        viewport.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Never);
        viewport.set_hexpand(true);
        viewport.set_vexpand(true);
        viewport.set_child(Some(&columns.widget));
        viewport.set_min_content_width(1);
        let vertical =
            gtk::Scrollbar::new(gtk::Orientation::Vertical, Some(&scrolls[0].vadjustment()));
        let body = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        body.set_vexpand(true);
        body.append(&viewport);
        body.append(&vertical);
        body.append(&gtk::Separator::new(gtk::Orientation::Vertical));
        body.append(&ruler.widget);
        let factory = gtk::SignalListItemFactory::new();
        factory.connect_setup(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            row.add_css_class("diff-list-entry");
            row.set_height_request(24);
            row.set_margin_start(12);
            row.set_margin_end(12);
            let icon = gtk::Image::new();
            icon.set_pixel_size(10);
            icon.set_size_request(14, -1);
            row.append(&icon);
            let label = gtk::Label::builder()
                .xalign(0.)
                .hexpand(true)
                .ellipsize(gtk::pango::EllipsizeMode::Middle)
                .build();
            row.append(&label);
            item.set_child(Some(&row));
        });
        factory.connect_bind(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let row = item.child().unwrap();
            let icon = row.first_child().unwrap().downcast::<gtk::Image>().unwrap();
            let label = row.last_child().unwrap().downcast::<gtk::Label>().unwrap();
            let text = item
                .item()
                .unwrap()
                .downcast::<gtk::StringObject>()
                .unwrap()
                .string();
            let (mark, description) = text.split_once(' ').unwrap_or(("", &text));
            icon.set_icon_name(Some(match mark {
                "+" => "fastra-plus-circle-symbolic",
                "−" => "fastra-diff-removed-symbolic",
                _ => "fastra-diff-changed-symbolic",
            }));
            for name in ["diff-added", "diff-removed", "diff-modified"] {
                icon.remove_css_class(name);
            }
            icon.add_css_class(match mark {
                "+" => "diff-added",
                "−" => "diff-removed",
                _ => "diff-modified",
            });
            label.set_text(description);
        });
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory));
        list.add_css_class("diff-list");
        list.update_property(&[gtk::accessible::Property::Label(
            lang.text("Liste der Unterschiede", "List of differences"),
        )]);
        let lower = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let label = gtk::Label::builder()
            .xalign(0.)
            .margin_start(12)
            .height_request(22)
            .build();
        let list_header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        list_header.add_css_class("diff-list-header");
        list_header.append(&label);
        lower.append(&list_header);
        lower.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let list_scroll = support::scroll(&list);
        list_scroll.set_vexpand(false);
        list_scroll.set_height_request(132);
        lower.append(&list_scroll);
        display.append(&body);
        display.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        display.append(&lower);
        let center = gtk::Box::new(gtk::Orientation::Vertical, 10);
        center.set_halign(gtk::Align::Center);
        center.set_valign(gtk::Align::Center);
        let spinner = gtk::Spinner::new();
        spinner.set_size_request(24, 24);
        center.append(&spinner);
        let message_icon = gtk::Image::from_icon_name("emblem-ok-symbolic");
        message_icon.set_pixel_size(24);
        message_icon.add_css_class("diff-right-name");
        center.append(&message_icon);
        let message_title = gtk::Label::new(None);
        message_title.add_css_class("heading");
        center.append(&message_title);
        let message_detail = gtk::Label::new(None);
        message_detail.add_css_class("dim-label");
        center.append(&message_detail);
        let message_options = gtk::Label::new(None);
        message_options.add_css_class("dim-label");
        center.append(&message_options);
        let message = gtk::Overlay::new();
        message.set_child(Some(&center));
        let summary_export = chrome::icon(
            "fastra-share-symbolic",
            lang.text("Vergleich exportieren …", "Export comparison …"),
        );
        summary_export.set_halign(gtk::Align::End);
        summary_export.set_valign(gtk::Align::Start);
        summary_export.set_margin_top(8);
        summary_export.set_margin_end(8);
        export
            .bind_property("sensitive", &summary_export, "sensitive")
            .sync_create()
            .build();
        let target = export.downgrade();
        summary_export.connect_clicked(move |_| {
            if let Some(button) = target.upgrade() {
                if button.is_sensitive() {
                    button.emit_clicked();
                }
            }
        });
        message.add_overlay(&summary_export);
        let screen = gtk::Stack::new();
        screen.set_vexpand(true);
        screen.add_named(&display, Some("comparison"));
        screen.add_named(&message, Some("message"));
        root.append(&screen);
        let view = Rc::new(Self {
            lang,
            root,
            transfer,
            refresh,
            export,
            previous,
            next,
            status,
            names,
            selection,
            texts,
            model,
            list,
            position,
            description,
            count: label,
            display,
            list_scroll,
            viewport,
            vertical,
            ruler,
            following_user_scroll: Cell::new(false),
            data: RefCell::new(None),
            render: Cell::new(0),
            ready: Cell::new(false),
            alignment: alignment::Alignment::default(),
            folding,
            screen,
            spinner,
            message_icon,
            message_title,
            message_detail,
            message_options,
            option_summary,
            actions,
            transfer_divider,
            gutters: std::array::from_fn(|_| sourceview5::GutterRendererText::new()),
            scroll_selection: Cell::new(true),
            scrolls: scrolls.clone(),
            columns,
        });
        let target = Rc::downgrade(&view);
        view.root.add_tick_callback(move |_, _| {
            let Some(view) = target.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let height = (view.display.height() / 4).clamp(24, 132);
            if view.list_scroll.height_request() != height {
                view.list_scroll.set_height_request(height);
            }
            view.ruler.update(
                if view.ready.get() {
                    view.model.n_items() as usize
                } else {
                    0
                },
                view.selection.selected() as usize,
            );
            let adjustment = view.scrolls[0].vadjustment();
            view.vertical
                .set_visible(adjustment.upper() > adjustment.page_size() + 0.5);
            view.position_selection();
            alignment::Alignment::request(&view);
            glib::ControlFlow::Continue
        });
        super::palette::watch(&view);
        let parent = owner.as_ref().downgrade();
        let target = Rc::downgrade(&view);
        view.columns.writer(move |ratio| {
            if let Some(parent) = parent.upgrade() {
                let target = target.clone();
                preferences::submit_window(
                    &parent,
                    Some(fastra_workflow::comparison_preferences::Change::SplitRatio(
                        ratio,
                    )),
                    move |result| {
                        if let (Err(error), Some(view)) = (result, target.upgrade()) {
                            view.error(&format!(
                                "{} {error}",
                                lang.text(
                                    "Spaltenteilung konnte nicht gespeichert werden:",
                                    "Could not save the column split:"
                                )
                            ));
                        }
                    },
                );
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let target = Rc::downgrade(&view);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if modifiers.contains(gtk::gdk::ModifierType::ALT_MASK)
                && !modifiers.intersects(
                    gtk::gdk::ModifierType::CONTROL_MASK
                        | gtk::gdk::ModifierType::SHIFT_MASK
                        | gtk::gdk::ModifierType::SUPER_MASK,
                )
            {
                if let Some(view) = target
                    .upgrade()
                    .filter(|view| view.ready.get() && view.model.n_items() > 0)
                {
                    let button = match key {
                        gtk::gdk::Key::Up => Some(&view.previous),
                        gtk::gdk::Key::Down => Some(&view.next),
                        _ => None,
                    };
                    if let Some(button) = button {
                        button.emit_clicked();
                        return glib::Propagation::Stop;
                    }
                }
            }
            glib::Propagation::Proceed
        });
        view.root.add_controller(keys);
        for widget in [
            view.viewport.clone().upcast::<gtk::Widget>(),
            view.vertical.clone().upcast(),
        ] {
            let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
            scroll.set_propagation_phase(gtk::PropagationPhase::Capture);
            let target = Rc::downgrade(&view);
            scroll.connect_scroll(move |_, _, dy| {
                if dy != 0. {
                    if let Some(view) = target.upgrade() {
                        view.following_user_scroll.set(true);
                    }
                }
                glib::Propagation::Proceed
            });
            widget.add_controller(scroll);
            let keys = gtk::EventControllerKey::new();
            keys.set_propagation_phase(gtk::PropagationPhase::Capture);
            let target = Rc::downgrade(&view);
            keys.connect_key_pressed(move |_, _, _, _| {
                if let Some(view) = target.upgrade() {
                    view.following_user_scroll.set(true);
                }
                glib::Propagation::Proceed
            });
            widget.add_controller(keys);
            let pointer = gtk::GestureClick::new();
            pointer.set_button(0);
            pointer.set_propagation_phase(gtk::PropagationPhase::Capture);
            let target = Rc::downgrade(&view);
            pointer.connect_pressed(move |_, _, _, _| {
                if let Some(view) = target.upgrade() {
                    view.following_user_scroll.set(true);
                }
            });
            widget.add_controller(pointer);
        }
        for scroll in &scrolls {
            let owner = Rc::downgrade(&view);
            scroll.vadjustment().connect_value_changed(move |_| {
                if let Some(view) = owner.upgrade() {
                    folding::Folding::redraw(&view);
                    view.follow_scroll();
                }
            });
            let owner = Rc::downgrade(&view);
            scroll.vadjustment().connect_changed(move |_| {
                if let Some(view) = owner.upgrade() {
                    folding::Folding::redraw(&view);
                }
            });
            let owner = Rc::downgrade(&view);
            scroll.hadjustment().connect_page_size_notify(move |_| {
                let owner = owner.clone();
                glib::idle_add_local_once(move || {
                    if let Some(view) = owner.upgrade() {
                        alignment::Alignment::request(&view);
                    }
                });
            });
        }
        for side in 0..2 {
            let gutter = &view.gutters[side];
            gutter.add_css_class("diff-line-number");
            gutter.set_size_request(48, -1);
            gutter.set_xalign(1.);
            gutter.set_xpad(6);
            let owner = Rc::downgrade(&view);
            gutter.connect_query_data(move |gutter, _, line| {
                if let Some(view) = owner.upgrade() {
                    let data = view.data.borrow();
                    let number = data
                        .as_ref()
                        .filter(|d| !view.folding.row_hidden(d, line as usize))
                        .and_then(|d| d.columns[side].lines.get(line as usize))
                        .and_then(|l| l.number);
                    gutter.set_text(&number.map(|n| n.to_string()).unwrap_or_default());
                }
            });
            sourceview5::prelude::ViewExt::gutter(&view.texts[side], gtk::TextWindowType::Left)
                .insert(gutter, 0);
            let owner = Rc::downgrade(&view);
            view.texts[side].connect_copy_clipboard(move |text| {
                text.stop_signal_emission_by_name("copy-clipboard");
                if let Some(view) = owner.upgrade() {
                    if let (Some(data), Some((a, b))) = (
                        view.data.borrow().as_ref(),
                        text.buffer().selection_bounds(),
                    ) {
                        text.clipboard().set_text(&data.columns[side].copy_visible(
                            a.offset().max(0) as usize..b.offset().max(0) as usize,
                            &view.folding.hidden(data),
                        ));
                    }
                }
            });
            let clicks = gtk::GestureClick::new();
            clicks.set_button(1);
            clicks.set_propagation_phase(gtk::PropagationPhase::Capture);
            let owner = Rc::downgrade(&view);
            clicks.connect_released(move |_, _, _, _| {
                let owner = owner.clone();
                glib::idle_add_local_once(move || {
                    let Some(view) = owner.upgrade().filter(|view| view.ready.get()) else {
                        return;
                    };
                    let buffer = view.texts[side].buffer();
                    if buffer.selection_bounds().is_some() {
                        return;
                    }
                    let row = buffer
                        .iter_at_offset(buffer.cursor_position())
                        .line()
                        .max(0) as usize;
                    let index = view.data.borrow().as_ref().and_then(|data| {
                        let index = data.blocks.partition_point(|block| block.end <= row);
                        data.blocks
                            .get(index)
                            .filter(|block| block.contains(&row))
                            .map(|_| index)
                    });
                    if let Some(index) = index {
                        view.scroll_selection.set(false);
                        view.selection.set_selected(index as u32);
                        view.scroll_selection.set(true);
                    }
                });
            });
            view.texts[side].add_controller(clicks);
        }
        for (button, direction) in [(&view.previous, -1), (&view.next, 1)] {
            let owner = Rc::downgrade(&view);
            button.connect_clicked(move |_| {
                if let Some(view) = owner.upgrade() {
                    let count = view.model.n_items();
                    if count > 0 {
                        view.selection.set_selected(
                            (view.selection.selected() as i64 + direction).rem_euclid(count as i64)
                                as u32,
                        );
                    }
                }
            });
        }
        let owner = Rc::downgrade(&view);
        view.selection.connect_selected_notify(move |_| {
            if let Some(view) = owner.upgrade() {
                view.follow(lang);
            }
        });
        view
    }
    fn follow(&self, lang: Language) {
        if !self.ready.get() {
            return;
        }
        let index = self.selection.selected() as usize;
        if self.list.is_mapped() && index < self.model.n_items() as usize {
            self.list
                .scroll_to(index as u32, gtk::ListScrollFlags::empty(), None);
        }
        let data = self.data.borrow();
        let Some(data) = data.as_ref() else { return };
        self.ruler.update(data.blocks.len(), index);
        if data.blocks.get(index).is_some() && self.scroll_selection.get() {
            self.following_user_scroll.set(false);
            self.position_selection();
        }
        self.description.set_text(
            &self
                .model
                .string(index as u32)
                .map(|text| {
                    text.split_once(' ')
                        .map(|(_, value)| value.to_owned())
                        .unwrap_or_default()
                })
                .unwrap_or_default(),
        );
        self.position.set_text(&if data.blocks.is_empty() {
            lang.text("Keine Unterschiede", "No differences").into()
        } else {
            format!(
                "{} {} {} {}",
                lang.text("Unterschied", "Difference"),
                index + 1,
                lang.text("von", "of"),
                data.blocks.len()
            )
        });
    }
    pub fn set_wrap(self: &Rc<Self>, enabled: bool) {
        self.viewport.queue_resize();
        for scroll in &self.scrolls {
            scroll.set_policy(
                if enabled {
                    gtk::PolicyType::Never
                } else {
                    gtk::PolicyType::External
                },
                gtk::PolicyType::External,
            );
        }
        for text in &self.texts {
            text.set_wrap_mode(if enabled {
                gtk::WrapMode::WordChar
            } else {
                gtk::WrapMode::None
            });
        }
        alignment::Alignment::request(self);
    }
    fn position_selection(&self) {
        let text = &self.texts[0];
        if !self.ready.get()
            || self.following_user_scroll.get()
            || !text.is_mapped()
            || text.height() <= 0
        {
            return;
        }
        let row = self.data.borrow().as_ref().and_then(|data| {
            data.blocks
                .get(self.selection.selected() as usize)
                .map(|block| block.start)
        });
        let Some(iter) = row.and_then(|row| text.buffer().iter_at_line(row as i32)) else {
            return;
        };
        let rect = text.iter_location(&iter);
        let adjustment = self.scrolls[0].vadjustment();
        let margin = adjustment.page_size() * 0.15;
        if f64::from(rect.y()) < adjustment.value() + margin
            || f64::from(rect.y() + rect.height())
                > adjustment.value() + adjustment.page_size() - margin
        {
            adjustment.clamp_page(
                (f64::from(rect.y()) - margin).max(0.),
                f64::from(rect.y() + rect.height()) + margin,
            );
        }
    }
    fn follow_scroll(&self) {
        if !self.ready.get() || !self.following_user_scroll.get() {
            return;
        }
        let index = {
            let data = self.data.borrow();
            let Some(data) = data.as_ref().filter(|data| !data.blocks.is_empty()) else {
                return;
            };
            let text = &self.texts[0];
            let row = text.line_at_y(text.visible_rect().y()).0.line().max(0) as usize;
            data.blocks
                .partition_point(|block| block.start <= row)
                .saturating_sub(1)
        };
        self.scroll_selection.set(false);
        self.selection.set_selected(index as u32);
        self.scroll_selection.set(true);
    }
    pub fn cancel_render(&self) {
        self.following_user_scroll.set(false);
        self.ready.set(false);
        self.alignment.clear(self);
        self.folding.clear(self);
        self.render.set(self.render.get().wrapping_add(1));
        self.data.borrow_mut().take();
        for text in &self.texts {
            text.buffer().set_text("");
        }
        self.model.splice(0, self.model.n_items(), &[]);
        self.position.set_text("");
    }
    pub fn loading(&self, lang: Language) {
        self.screen.set_visible_child_name("message");
        self.spinner.set_visible(true);
        self.spinner.start();
        self.message_icon.set_visible(false);
        self.message_title
            .set_text(lang.text("Vergleich wird berechnet …", "Calculating comparison …"));
        self.message_detail.set_text("");
        self.message_options.set_text("");
    }
    pub fn interactive(&self, value: bool) {
        self.list.set_sensitive(value);
        for text in &self.texts {
            text.set_sensitive(value);
        }
    }
    pub fn show_transfer_controls(&self, visible: bool) {
        self.actions.set_visible(visible);
        self.status.set_visible(visible);
        self.transfer_divider.set_visible(visible);
    }
    pub fn error(&self, text: &str) {
        self.status.set_text(text);
        self.status.set_visible(true);
        if !self.ready.get() {
            self.spinner.stop();
            self.spinner.set_visible(false);
            self.message_icon.set_visible(false);
            self.message_title.set_text(text);
            self.message_title.set_wrap(true);
            self.message_title.set_max_width_chars(70);
            self.message_detail.set_text("");
            self.message_options.set_text("");
            self.screen.set_visible_child_name("message");
        }
    }
    pub fn install(
        self: &Rc<Self>,
        data: presentation::Presentation,
        labels: Vec<String>,
        lang: Language,
        done: impl FnOnce() + 'static,
    ) {
        self.ready.set(false);
        self.alignment.clear(self);
        let generation = self.render.get().wrapping_add(1);
        self.render.set(generation);
        let data = Rc::new(data);
        *self.data.borrow_mut() = Some(data.clone());
        for (side, count) in [data.line_counts.0, data.line_counts.1]
            .into_iter()
            .enumerate()
        {
            let width = self.texts[side]
                .create_pango_layout(Some(&count.to_string()))
                .pixel_size()
                .0
                + 12;
            self.gutters[side].set_size_request(width.max(48), -1);
        }
        self.folding.setup(self);
        for text in &self.texts {
            text.buffer().set_text("");
        }
        self.model.splice(0, self.model.n_items(), &[]);
        let [normal_tags, tags, gap_tags, emphasis_tags] = super::palette::tags(&self.texts);
        let owner = Rc::downgrade(self);
        let mut offsets = if data.blocks.is_empty() {
            data.columns.each_ref().map(|column| column.display.len())
        } else {
            [0usize; 2]
        };
        let mut tag_index = data.columns.each_ref().map(|column| {
            if data.blocks.is_empty() {
                column.changed.len()
            } else {
                0
            }
        });
        let mut gap_index = data.columns.each_ref().map(|column| {
            if data.blocks.is_empty() {
                column.gaps.len()
            } else {
                0
            }
        });
        let mut emphasis_index = data.columns.each_ref().map(|column| {
            if data.blocks.is_empty() {
                column.emphasis.len()
            } else {
                0
            }
        });
        let mut fold_index = if data.blocks.is_empty() {
            data.folds.len()
        } else {
            0
        };
        let mut label_index = 0;
        let mut done = Some(done);
        glib::idle_add_local(move || {
            let Some(view) = owner.upgrade().filter(|v| v.render.get() == generation) else {
                return glib::ControlFlow::Break;
            };
            let started = Instant::now();
            loop {
                let side = if offsets[0] < data.columns[0].display.len() {
                    Some(0)
                } else if offsets[1] < data.columns[1].display.len() {
                    Some(1)
                } else {
                    None
                };
                if let Some(side) = side {
                    let text = &data.columns[side].display;
                    let start = offsets[side];
                    let mut end = (start + 16384).min(text.len());
                    while !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    view.texts[side]
                        .buffer()
                        .insert(&mut view.texts[side].buffer().end_iter(), &text[start..end]);
                    offsets[side] = end;
                } else if let Some(side) =
                    (0..2).find(|s| tag_index[*s] < data.columns[*s].changed.len())
                {
                    let span = &data.columns[side].changed[tag_index[side]];
                    let buffer = view.texts[side].buffer();
                    buffer.apply_tag(
                        &tags[side],
                        &buffer.iter_at_offset(span.start),
                        &buffer.iter_at_offset(span.end),
                    );
                    tag_index[side] += 1;
                } else if let Some(side) =
                    (0..2).find(|s| gap_index[*s] < data.columns[*s].gaps.len())
                {
                    let span = &data.columns[side].gaps[gap_index[side]];
                    let buffer = view.texts[side].buffer();
                    buffer.apply_tag(
                        &gap_tags[side],
                        &buffer.iter_at_offset(span.start),
                        &buffer.iter_at_offset(span.end),
                    );
                    gap_index[side] += 1;
                } else if let Some(side) =
                    (0..2).find(|s| emphasis_index[*s] < data.columns[*s].emphasis.len())
                {
                    let span = &data.columns[side].emphasis[emphasis_index[side]];
                    let buffer = view.texts[side].buffer();
                    buffer.apply_tag(
                        &emphasis_tags[side],
                        &buffer.iter_at_offset(span.start),
                        &buffer.iter_at_offset(span.end),
                    );
                    emphasis_index[side] += 1;
                } else if fold_index < data.folds.len() && !data.blocks.is_empty() {
                    view.folding.hide(&view, fold_index, true);
                    fold_index += 1;
                } else if label_index < labels.len() {
                    let end = (label_index + 256).min(labels.len());
                    let batch = labels[label_index..end]
                        .iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>();
                    view.model.splice(view.model.n_items(), 0, &batch);
                    label_index = end;
                } else {
                    view.ready.set(true);
                    alignment::Alignment::request(&view);
                    folding::Folding::redraw(&view);
                    let options = options_summary(data.options, lang);
                    view.option_summary.set_text(&options);
                    view.option_summary.set_tooltip_text(Some(&options));
                    view.spinner.stop();
                    if data.blocks.is_empty() {
                        view.spinner.set_visible(false);
                        view.message_icon.set_visible(true);
                        view.message_title
                            .set_text(&if data.line_counts.0 == data.line_counts.1 {
                                format!(
                                    "{} — {} {}",
                                    lang.text("Keine Unterschiede", "No differences"),
                                    data.line_counts.0,
                                    lang.text("Zeilen identisch.", "identical lines.")
                                )
                            } else {
                                format!(
                                    "{} — {} {}, {} {}.",
                                    lang.text("Keine Unterschiede", "No differences"),
                                    lang.text("links", "left"),
                                    data.line_counts.0,
                                    lang.text("rechts", "right"),
                                    data.line_counts.1
                                )
                            });
                        view.message_detail.set_text(&format!(
                            "{} {} {}",
                            view.names[0].text(),
                            lang.text("und", "and"),
                            view.names[1].text()
                        ));
                        view.message_options.set_text(&options);
                        view.screen.set_visible_child_name("message");
                    } else {
                        view.screen.set_visible_child_name("comparison");
                    }
                    view.count.set_text(&format!(
                        "{}: {}",
                        lang.text("Unterschiede", "Differences"),
                        data.blocks.len()
                    ));
                    view.follow(lang);
                    for text in &view.texts {
                        text.queue_draw();
                    }
                    for (side, tag) in normal_tags.iter().enumerate() {
                        let buffer = view.texts[side].buffer();
                        buffer.apply_tag(tag, &buffer.start_iter(), &buffer.end_iter());
                    }
                    if let Some(done) = done.take() {
                        done();
                    }
                    return glib::ControlFlow::Break;
                }
                if started.elapsed() >= Duration::from_millis(3) {
                    return glib::ControlFlow::Continue;
                }
            }
        });
    }
}

pub(super) fn options_summary(options: fastra_diff::Options, lang: Language) -> String {
    let mut parts = Vec::new();
    if options.ignore_all_whitespace {
        parts.push(lang.text("alle Leerraum-Unterschiede", "all whitespace differences"));
    } else if options.ignore_trailing_whitespace {
        parts.push(lang.text("Leerraum am Zeilenende", "trailing whitespace"));
    }
    if options.ignore_blank_lines {
        parts.push(lang.text("Leerzeilen", "blank lines"));
    }
    if options.ignore_case {
        parts.push(lang.text("Groß-/Kleinschreibung", "case"));
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!(
            "{}: {}",
            lang.text("Ignoriert", "Ignored"),
            parts.join(", ")
        )
    }
}
