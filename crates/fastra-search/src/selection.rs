use super::*;

pub(super) struct Selection(Option<Vec<PathBuf>>);
impl Selection {
    pub fn new(paths: Option<&[PathBuf]>, roots: usize) -> Result<Self> {
        let Some(paths) = paths else {
            return Ok(Self(None));
        };
        if roots != 1 || paths.is_empty() || paths.len() > 10_000 {
            return Err(Error::InvalidRoots);
        }
        let mut normalized = Vec::new();
        for path in paths {
            if path.as_os_str().is_empty() || path.as_os_str().as_bytes().len() > 4096 {
                return Err(Error::InvalidRoots);
            }
            let mut result = PathBuf::new();
            for part in path.components() {
                match part {
                    Component::Normal(name) => result.push(name),
                    Component::CurDir => {}
                    _ => return Err(Error::InvalidRoots),
                }
            }
            if !normalized.contains(&result) {
                normalized.push(result);
            }
        }
        Ok(Self(Some(normalized)))
    }
    pub fn visit(&self, relative: &Path, directory: bool) -> bool {
        self.0.as_ref().is_none_or(|paths| {
            paths
                .iter()
                .any(|path| relative.starts_with(path) || directory && path.starts_with(relative))
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn project_paths_are_relative_component_ranges_with_no_empty_fallback() {
        let selected = Selection::new(Some(&["src/part".into(), "one.txt".into()]), 1).unwrap();
        for (path, dir, yes) in [
            ("src", true, true),
            ("src", false, false),
            ("src/part/a.txt", false, true),
            ("src/partial/a", false, false),
            ("one.txt", false, true),
            ("one.txt.bak", false, false),
            ("other", true, false),
        ] {
            assert_eq!(selected.visit(Path::new(path), dir), yes, "{path}");
        }
        for paths in [
            vec![],
            vec!["".into()],
            vec!["../outside".into()],
            vec!["src/../outside".into()],
            vec!["/absolute".into()],
        ] {
            assert!(Selection::new(Some(&paths), 1).is_err());
        }
        assert!(Selection::new(Some(&[".".into()]), 2).is_err());
        assert!(Selection::new(Some(&[".".into()]), 1)
            .unwrap()
            .visit(Path::new("anywhere"), false));
        assert!(Selection::new(None, 2)
            .unwrap()
            .visit(Path::new("anywhere"), false));
    }
}
