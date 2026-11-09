use super::*;
struct Saved {
    document: std::rc::Weak<Document>,
    revision: u64,
    value: Value,
}
thread_local! { static SAVED: RefCell<Vec<Saved>> = const { RefCell::new(Vec::new()) }; }
pub(super) fn get(doc: &Rc<Document>) -> Option<Value> {
    SAVED.with(|items| {
        let mut items = items.borrow_mut();
        items.retain(|item| item.document.strong_count() > 0);
        items
            .iter()
            .find(|item| {
                item.revision == doc.revision.get()
                    && item
                        .document
                        .upgrade()
                        .is_some_and(|old| Rc::ptr_eq(&old, doc))
            })
            .map(|item| item.value.clone())
    })
}
pub(super) fn remember(doc: &Rc<Document>, value: &Value) {
    let Some(x) = value["x"].as_f64() else {
        return;
    };
    let Some(y) = value["y"].as_f64() else {
        return;
    };
    if ![x, y]
        .iter()
        .all(|n| n.is_finite() && (0.0..=100_000_000.0).contains(n))
    {
        return;
    }
    SAVED.with(|items| {
        let mut items = items.borrow_mut();
        items.retain(|item| {
            item.document
                .upgrade()
                .is_some_and(|old| !Rc::ptr_eq(&old, doc))
        });
        if items.len() >= 128 {
            items.remove(0);
        }
        items.push(Saved {
            document: Rc::downgrade(doc),
            revision: doc.revision.get(),
            value: json!({"x":x,"y":y}),
        });
    });
}
