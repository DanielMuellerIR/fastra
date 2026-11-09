use super::*;
use std::time::Duration;
const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_ROWS: usize = 2001;

pub(crate) struct Request {
    clipboard: gtk::gdk::Clipboard,
    changed: Rc<Cell<bool>>,
    handler: Option<glib::SignalHandlerId>,
    view: sourceview5::View,
    unmap: Option<glib::SignalHandlerId>,
    window: Option<(gtk::Window, glib::SignalHandlerId)>,
    max_bytes: usize,
}
impl Request {
    pub(super) fn new(clipboard: gtk::gdk::Clipboard, view: sourceview5::View) -> Self {
        Self::bounded(clipboard, view, MAX_BYTES)
    }
    pub(crate) fn bounded(
        clipboard: gtk::gdk::Clipboard,
        view: sourceview5::View,
        max_bytes: usize,
    ) -> Self {
        let changed = Rc::new(Cell::new(false));
        let observed = changed.clone();
        let handler = clipboard.connect_changed(move |_| observed.set(true));
        let observed = changed.clone();
        let unmap = view.connect_unmap(move |_| observed.set(true));
        let observed = changed.clone();
        let window = view
            .root()
            .and_then(|root| root.downcast::<gtk::Window>().ok())
            .map(|window| {
                let handler = window.connect_is_active_notify(move |window| {
                    if !window.is_active() {
                        observed.set(true);
                    }
                });
                (window, handler)
            });
        Self {
            clipboard,
            changed,
            handler: Some(handler),
            view,
            unmap: Some(unmap),
            window,
            max_bytes,
        }
    }
    pub(crate) fn cancellation(&self) -> Rc<Cell<bool>> {
        self.changed.clone()
    }
    pub(crate) async fn read(self) -> Result<String, Error> {
        if self.changed.get() {
            return Err(Error::Clipboard);
        }
        let input = self.clipboard.clone();
        let cancelled = self.changed.clone();
        let max_bytes = self.max_bytes;
        let job = async move {
            let (stream, mime) = input
                .read_future(
                    &["text/plain;charset=utf-8", "text/plain"],
                    glib::Priority::DEFAULT,
                )
                .await
                .map_err(|_| Error::Clipboard)?;
            if !["text/plain;charset=utf-8", "text/plain"].contains(&mime.as_str()) {
                return Err(Error::Clipboard);
            }
            let mut bytes = Vec::new();
            loop {
                if cancelled.get() {
                    return Err(Error::Clipboard);
                }
                let part = stream
                    .read_bytes_future(8192, glib::Priority::DEFAULT)
                    .await
                    .map_err(|_| Error::Clipboard)?;
                if part.is_empty() {
                    break;
                }
                if bytes.len().saturating_add(part.len()) > max_bytes {
                    return Err(Error::Limit);
                }
                bytes.extend_from_slice(part.as_ref());
            }
            let text = String::from_utf8(bytes).map_err(|_| Error::Clipboard)?;
            if text.contains('\0') {
                return Err(Error::Clipboard);
            }
            Ok(text)
        };
        let result = glib::future_with_timeout(Duration::from_secs(5), job)
            .await
            .map_err(|_| Error::Clipboard)
            .and_then(|value| value);
        if self.changed.get()
            || !self
                .window
                .as_ref()
                .is_some_and(|(window, _)| window.is_active())
        {
            Err(Error::Clipboard)
        } else {
            result
        }
    }
}
impl Drop for Request {
    fn drop(&mut self) {
        if let Some(handler) = self.handler.take() {
            self.clipboard.disconnect(handler);
        }
        if let Some(handler) = self.unmap.take() {
            self.view.disconnect(handler);
        }
        if let Some((window, handler)) = self.window.take() {
            window.disconnect(handler);
        }
    }
}
struct Change {
    start: i32,
    end: i32,
    text: String,
    cursors: Vec<usize>,
}
impl Rectangle {
    fn padding(&self, current: i32, target: i32) -> String {
        let mut result = String::new();
        let mut column = current;
        if self
            .view
            .upgrade()
            .is_some_and(|view| !view.is_insert_spaces_instead_of_tabs())
        {
            while column < target {
                let next = self.next_column(column, '\t');
                if next > target {
                    break;
                }
                result.push('\t');
                column = next;
            }
        }
        result.push_str(&" ".repeat((target - column).max(0) as usize));
        result
    }
    pub(super) fn apply_clipboard(&self, value: &str, pad: bool) -> Result<(), Error> {
        if !self.is_selected() {
            return Ok(());
        }
        if value.len() > MAX_BYTES
            || value.contains('\0')
            || self.buffer.char_count() as usize > MAX_BYTES
        {
            return Err(Error::Limit);
        }
        let source = self
            .buffer
            .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true);
        if source.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        let normalized = value.replace("\r\n", "\n").replace('\r', "\n");
        let mut values: Vec<_> = normalized.split('\n').take(MAX_ROWS + 2).collect();
        if values.len() > 1 && values.last() == Some(&"") {
            values.pop();
        }
        if values.len() > MAX_ROWS {
            return Err(Error::Limit);
        }
        let rows: Vec<_> = self
            .marks
            .borrow()
            .iter()
            .map(|(a, b)| {
                let a = self.buffer.iter_at_mark(a);
                let b = self.buffer.iter_at_mark(b);
                (a.offset(), b.offset(), a.line(), self.position_column(&a))
            })
            .collect();
        let left = self.bounds.get().map_or(rows[0].3, |bounds| bounds.2);
        if !(0..=65536).contains(&left) {
            return Err(Error::Limit);
        }
        let count = if values.len() == 1 {
            rows.len()
        } else {
            rows.len().max(values.len())
        };
        if count > MAX_ROWS {
            return Err(Error::Limit);
        }
        let extra_line = rows.last().unwrap().2 + 1;
        let ending = (self.ending)().ok_or(Error::Clipboard)?;
        let separator = match ending {
            fastra_core::encoding::LineEnding::Lf => "\n",
            fastra_core::encoding::LineEnding::CrLf => "\r\n",
            fastra_core::encoding::LineEnding::Cr => "\r",
        };
        let mut changes: Vec<Change> = Vec::new();
        let mut appended = Change {
            start: self.buffer.char_count(),
            end: self.buffer.char_count(),
            text: String::new(),
            cursors: Vec::new(),
        };
        let mut estimated = source.len();
        for index in 0..count {
            let value = if values.len() == 1 {
                Some(values[0])
            } else {
                values.get(index).copied()
            };
            let row = if index < rows.len() {
                Some(rows[index])
            } else {
                let line = extra_line + (index - rows.len()) as i32;
                (line < self.buffer.line_count()).then(|| {
                    let (at, col) = self.offset(line, left, false);
                    (at.offset(), at.offset(), line, col)
                })
            };
            if let Some((a, b, _, column)) = row {
                if changes.last().is_some_and(|previous| a < previous.end) {
                    return Err(Error::Selection);
                }
                let prefix = if pad && value.is_some() {
                    self.padding(column, left)
                } else {
                    String::new()
                };
                let text = format!("{prefix}{}", value.unwrap_or(""));
                let old = self.buffer.text(
                    &self.buffer.iter_at_offset(a),
                    &self.buffer.iter_at_offset(b),
                    true,
                );
                estimated = estimated
                    .checked_sub(old.len())
                    .and_then(|n| n.checked_add(text.len()))
                    .ok_or(Error::Limit)?;
                if estimated > MAX_BYTES {
                    return Err(Error::Limit);
                }
                let chars = text.chars().count();
                changes.push(Change {
                    start: a,
                    end: b,
                    text,
                    cursors: vec![chars],
                });
            } else if let Some(value) = value {
                let addition = format!("{separator}{}{value}", self.padding(0, left));
                estimated = estimated.checked_add(addition.len()).ok_or(Error::Limit)?;
                if estimated > MAX_BYTES {
                    return Err(Error::Limit);
                }
                appended.text.push_str(&addition);
                appended.cursors.push(appended.text.chars().count());
            }
        }
        if !appended.text.is_empty() {
            changes.push(appended);
        }
        let byte_offsets: Vec<_> = source
            .char_indices()
            .map(|(offset, _)| offset)
            .chain(std::iter::once(source.len()))
            .collect();
        let mut planned = String::with_capacity(estimated);
        let mut copied = 0;
        for change in &changes {
            let start = *byte_offsets
                .get(change.start as usize)
                .ok_or(Error::Selection)?;
            let end = *byte_offsets
                .get(change.end as usize)
                .ok_or(Error::Selection)?;
            if start < copied || end < start {
                return Err(Error::Selection);
            }
            planned.push_str(&source[copied..start]);
            planned.push_str(&change.text);
            copied = end;
        }
        planned.push_str(&source[copied..]);
        if planned.len() > MAX_BYTES
            || planned
                .split(['\r', '\n'])
                .any(|line| line.len() > fastra_document::TEXT_SECTION_BYTES)
        {
            return Err(Error::Limit);
        }
        let mut delta = 0i64;
        let mut cursors = Vec::new();
        for change in &changes {
            for cursor in &change.cursors {
                let offset = i64::from(change.start) + delta + *cursor as i64;
                cursors.push(i32::try_from(offset).map_err(|_| Error::Limit)?);
            }
            delta += change.text.chars().count() as i64 - i64::from(change.end - change.start);
        }
        let final_count = i64::from(self.buffer.char_count()) + delta;
        if cursors
            .iter()
            .any(|offset| *offset < 0 || i64::from(*offset) > final_count)
        {
            return Err(Error::Limit);
        }
        self.editing.set(true);
        self.clear();
        self.buffer.begin_user_action();
        for change in changes.iter().rev() {
            let mut a = self.buffer.iter_at_offset(change.start);
            let mut b = self.buffer.iter_at_offset(change.end);
            self.buffer.delete(&mut a, &mut b);
            self.buffer.insert(&mut a, &change.text);
        }
        self.buffer.end_user_action();
        let mut seen = std::collections::HashSet::new();
        for offset in cursors.into_iter().filter(|offset| seen.insert(*offset)) {
            let at = self.buffer.iter_at_offset(offset);
            let a = self.buffer.create_mark(None, &at, true);
            a.set_visible(true);
            let b = self.buffer.create_mark(None, &at, false);
            self.marks.borrow_mut().push((a, b));
        }
        if let Some((_, mark)) = self.marks.borrow().last() {
            self.buffer.place_cursor(&self.buffer.iter_at_mark(mark));
        }
        self.editing.set(false);
        if let Some(view) = self
            .view
            .upgrade()
            .filter(|view| view.is_mapped() && view.is_sensitive())
        {
            view.grab_focus();
        }
        Ok(())
    }
}
