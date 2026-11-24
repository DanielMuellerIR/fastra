#[derive(Clone, Copy)]
pub(crate) struct Language(pub(crate) bool);

impl Language {
    pub(crate) fn from_environment() -> Self {
        let preferences = std::env::var("LANGUAGE").ok();
        let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
            .into_iter()
            .find_map(|name| {
                std::env::var(name)
                    .ok()
                    .filter(|value| !value.trim().is_empty())
            });
        Self::from_locales(preferences.as_deref(), locale.as_deref())
    }

    fn from_locales(preferences: Option<&str>, locale: Option<&str>) -> Self {
        fn language_code(value: &str) -> &str {
            value.trim().split(['_', '-', '.', '@']).next().unwrap_or("")
        }
        if matches!(locale.map(language_code), Some("C" | "POSIX")) {
            return Self(false);
        }
        let german = preferences
            .into_iter()
            .flat_map(|value| value.split(':'))
            .chain(locale)
            .find_map(
                |value| match language_code(value) {
                    "de" => Some(true),
                    "en" | "C" | "POSIX" => Some(false),
                    _ => None,
                },
            );
        Self(german.unwrap_or(false))
    }

    pub(crate) fn text(self, de: &'static str, en: &'static str) -> &'static str {
        if self.0 {
            de
        } else {
            en
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Language;

    #[test]
    fn empty_language_keeps_the_desktop_locale() {
        assert_eq!(
            Language::from_locales(Some(""), Some("de_DE.UTF-8")).text("DE", "EN"),
            "DE"
        );
        assert_eq!(
            Language::from_locales(None, Some("en_GB.UTF-8")).text("DE", "EN"),
            "EN"
        );
    }

    #[test]
    fn c_locale_and_language_fallback_use_english() {
        for locale in ["C", "POSIX", "C.UTF-8"] {
            assert_eq!(Language::from_locales(Some("de"), Some(locale)).text("DE", "EN"), "EN");
        }
        assert_eq!(Language::from_locales(Some("fr:C:de"), Some("de_DE")).text("DE", "EN"), "EN");
    }

    #[test]
    fn explicit_languages_take_priority_in_order() {
        assert_eq!(
            Language::from_locales(Some("en_GB:de"), Some("de_DE")).text("DE", "EN"),
            "EN"
        );
        assert_eq!(
            Language::from_locales(Some("fr:de:en"), Some("en_GB")).text("DE", "EN"),
            "DE"
        );
        assert_eq!(
            Language::from_locales(None, Some("C.UTF-8")).text("DE", "EN"),
            "EN"
        );
    }
}
