use super::*;

pub(super) fn wordmark(size: f64) -> gtk::Label {
    let label = gtk::Label::new(None);
    label.set_markup(&format!(
        "Fastra<span size=\"40%\" rise=\"{}\">*</span>",
        (size * 0.5 * f64::from(gtk::pango::SCALE)) as i32
    ));
    label.update_property(&[gtk::accessible::Property::Label("Fastra")]);
    label
}
