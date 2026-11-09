//! Eine Quelle für App-Befehle und die gegen Makros geschützten Editor-Tasten.
use gtk::gdk::Key;
use std::collections::HashSet;
#[derive(Clone, Copy)]
pub(super) enum Command {
    Open,
    Goto,
    Save,
    Print,
    CloseWindow,
    CloseTab,
    NewTab,
    Find,
    Search,
}
pub(super) fn command(key: Key) -> Option<Command> {
    Some(match key {
        Key::o => Command::Open,
        Key::l => Command::Goto,
        Key::s => Command::Save,
        Key::p => Command::Print,
        Key::q => Command::CloseWindow,
        Key::w => Command::CloseTab,
        Key::n | Key::t => Command::NewTab,
        Key::f => Command::Find,
        Key::Return => Command::Search,
        _ => return None,
    })
}
pub(super) fn reserved_macro_keys() -> HashSet<String> {
    // Neben App-Befehlen behalten auch die dokumentierten GTK-Editorbefehle ihre Tasten.
    let mut keys: HashSet<String> = "abcd eghkruvxyz"
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| c.to_string())
        .collect();
    for key in [
        Key::o,
        Key::l,
        Key::s,
        Key::p,
        Key::q,
        Key::w,
        Key::n,
        Key::t,
        Key::f,
    ] {
        if command(key).is_some() {
            if let Some(c) = key.to_unicode() {
                keys.insert(c.to_string());
            }
        }
    }
    keys
}
#[cfg(test)]
mod tests {
    #[test]
    fn all_app_and_editor_chords_are_reserved() {
        for key in [
            'o', 'l', 's', 'p', 'q', 'w', 'n', 't', 'f', 'a', 'c', 'v', 'x', 'z', 'y', 'g', 'h',
        ] {
            assert!(super::reserved_macro_keys().contains(&key.to_string()));
        }
        assert!(!super::reserved_macro_keys().contains("#"));
    }
}
