use super::*;
use std::io::Write;
use std::{os::unix::fs::MetadataExt, path::Path};

fn protect_sources(
    sources: &[PathBuf],
    identities: &[fastra_io::FileIdentity],
    destination: &Path,
    lang: Language,
) -> Result<(), String> {
    let resolve = |path: &Path| -> std::io::Result<PathBuf> {
        match std::fs::canonicalize(path) {
            Ok(path) => Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let parent = path.parent().ok_or(error)?;
                Ok(std::fs::canonicalize(parent)?
                    .join(path.file_name().ok_or(std::io::ErrorKind::InvalidInput)?))
            }
            Err(error) => Err(error),
        }
    };
    let target = resolve(destination).map_err(|e| e.to_string())?;
    let identity = |path: &Path| -> Result<Option<fastra_io::FileIdentity>, String> {
        match std::fs::metadata(path) {
            Ok(m) => Ok(Some(fastra_io::FileIdentity {
                device: m.dev(),
                inode: m.ino(),
            })),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    };
    let rejected = || {
        lang.text(
            "Der Bericht darf keine Vergleichsquelle überschreiben. Wähle eine andere Datei.",
            "The report must not overwrite a comparison source. Choose another file.",
        )
        .to_owned()
    };
    let target_id = identity(&target)?;
    // Gespeicherte Identitäten bleiben auch nach Umbenennen oder Entfernen des Quellordners gültig.
    if target_id.is_some_and(|id| identities.contains(&id)) {
        return Err(rejected());
    }
    for source in sources {
        let resolved = match resolve(source) {
            Ok(path) => Some(path),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.to_string()),
        };
        let current_id = identity(source)?;
        if source == destination
            || resolved.as_ref() == Some(&target)
            || target_id.is_some_and(|id| current_id == Some(id))
        {
            return Err(rejected());
        }
    }
    Ok(())
}
pub(super) fn report(
    comparison: &fastra_diff::Comparison,
    names: &[String; 2],
    paths: &[Option<PathBuf>; 2],
    file_sources: [bool; 2],
    limit: usize,
    lang: Language,
) -> Result<String, String> {
    let mut output = String::new();
    let mut append = |text: &str| -> Result<(), String> {
        if output.len().saturating_add(text.len()) > limit {
            return Err(lang
                .text(
                    "Der vollständige Bericht überschreitet die unterstützte Größe. Nichts exportiert.",
                    "The complete report exceeds the supported size. Nothing exported.",
                )
                .into());
        }
        output.push_str(text);
        Ok(())
    };
    append(lang.text("Fastra — Differenzen-Liste\nBericht aus der fertigen Vergleichsbasis; gefaltete Zeilen ändern die Liste nicht.\n\n", "Fastra — Difference list\nReport from the completed comparison; folded lines do not change the list.\n\n"))?;
    for (side, name) in names.iter().enumerate() {
        append(&format!(
            "{}: {:?} — {}\n",
            if side == 0 {
                lang.text("Links", "Left")
            } else {
                lang.text("Rechts", "Right")
            },
            name,
            if file_sources[side] {
                lang.text("Datei", "File")
            } else {
                lang.text("Editorinhalt", "Editor content")
            }
        ))?;
        if let Some(path) = &paths[side] {
            append(&format!("{path:?}\n"))?;
        }
    }
    let options = view::options_summary(comparison.options(), lang);
    if !options.is_empty() {
        append(&format!("{options}\n"))?;
    }
    let yes = |value| {
        if value {
            lang.text("ja", "yes")
        } else {
            lang.text("nein", "no")
        }
    };
    append(&format!(
        "{}: {}\n{}: {}\n{}: {}\n",
        lang.text("Unterschiede", "Differences"),
        comparison.blocks().len(),
        lang.text(
            "Vergleichstexte exakt gleich",
            "Comparison texts exactly equal"
        ),
        yes(comparison.byte_identical()),
        lang.text("Abweichende Zeilenenden", "Different line endings"),
        yes(comparison.rows().iter().any(|row| row.terminators_differ))
    ))?;
    if !comparison.byte_identical() && comparison.blocks().is_empty() {
        append(lang.text("Die ursprünglichen Texte unterscheiden sich; unter den aktiven Vergleichsregeln gibt es keine Unterschiedsblöcke.\n", "The original texts differ; the active comparison rules produce no difference blocks.\n"))?;
    }
    let labels = result::block_labels(comparison, lang);
    for (index, block) in comparison.blocks().iter().enumerate() {
        append(&format!(
            "\n{} {}: {}\n",
            lang.text("Unterschied", "Difference"),
            index + 1,
            labels[index]
        ))?;
        for row in &comparison.rows()[block.rows.clone()] {
            for (marker, number, left) in [("-", row.left_line, true), ("+", row.right_line, false)]
            {
                if let Some(number) = number {
                    append(&format!(
                        "{marker} {number} | {}\n",
                        comparison.content(left, number).unwrap()
                    ))?;
                }
            }
        }
    }
    append(lang.text("\n- bezeichnet die linke/vorherige Zeile; + die rechte/neue Zeile. Zeilennummern beginnen bei 1.\n", "\n- denotes the left/before line; + the right/after line. Line numbers begin at 1.\n"))?;
    Ok(output)
}
pub(super) fn open(state: &Rc<State>) {
    if state.busy.get() || !state.active() {
        return;
    }
    let Some(model) = state.model.borrow().clone() else {
        return;
    };
    let names = state
        .view
        .names
        .each_ref()
        .map(|label| label.text().to_string());
    let owner = Rc::downgrade(state);
    let lang = state.lang;
    let mut sources = state
        .choices
        .borrow()
        .iter()
        .flatten()
        .filter_map(|choice| choice.path())
        .collect::<Vec<_>>();
    sources.extend(model.paths.iter().flatten().cloned());
    sources.sort();
    sources.dedup();
    let mut identities = model
        .inputs
        .iter()
        .filter_map(|input| input.file.as_ref())
        .map(|file| fastra_io::FileIdentity {
            device: file.identity().device(),
            inode: file.identity().inode(),
        })
        .collect::<Vec<_>>();
    for origin in state.origins.borrow().iter().flatten() {
        identities.extend(origin.protected_identities());
    }
    support::background(
        move || {
            report(
                &model.comparison,
                &names,
                &model.paths,
                model.inputs.each_ref().map(|input| input.file.is_some()),
                fastra_diff::Limits::default().max_report_bytes,
                lang,
            )
        },
        move |result| {
            let Some(state) = owner.upgrade().filter(|state| state.active()) else {
                return;
            };
            let report = match result {
                Ok(report) => report,
                Err(error) => {
                    state.error(&error);
                    return;
                }
            };
            let Some(ui) = state.live() else { return };
            let target = Rc::downgrade(&ui);
            prompt(
                &ui.window,
                report.into(),
                sources,
                identities,
                lang,
                move |message| {
                    if let Some(ui) = target.upgrade() {
                        ui.status.set_text(&message);
                    }
                },
            );
        },
    );
}
pub(super) fn prompt(
    window: &impl IsA<gtk::Window>,
    report: Arc<str>,
    sources: Vec<PathBuf>,
    identities: Vec<fastra_io::FileIdentity>,
    lang: Language,
    done: impl FnOnce(String) + 'static,
) {
    let target = window.as_ref().downgrade();
    gtk::FileDialog::builder()
        .title(lang.text("Vergleich exportieren", "Export comparison"))
        .initial_name("Fastra-Diff.txt")
        .build()
        .save(Some(window), None::<&gio::Cancellable>, move |result| {
            let Ok(file) = result else { return };
            let Some(window) = target.upgrade().filter(|window| window.is_visible()) else {
                return;
            };
            let Some(path) = file.path() else {
                done(
                    lang.text(
                        "Für den Export eine lokale Datei wählen.",
                        "Choose a local file for export.",
                    )
                    .into(),
                );
                return;
            };
            let hold = window.application().map(|app| app.hold());
            support::background(
                move || {
                    protect_sources(&sources, &identities, &path, lang)?;
                    let parent = path.parent().ok_or("Missing output directory")?;
                    let mut temporary =
                        tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
                    temporary
                        .write_all(report.as_bytes())
                        .map_err(|e| e.to_string())?;
                    temporary.as_file().sync_all().map_err(|e| e.to_string())?;
                    protect_sources(&sources, &identities, &path, lang)?;
                    temporary.persist(&path).map_err(|e| e.error.to_string())?;
                    Ok(())
                },
                move |result| {
                    done(match result {
                        Ok(()) => lang
                            .text("Vergleich exportiert.", "Comparison exported.")
                            .into(),
                        Err(error) => format!(
                            "{} {error}",
                            lang.text("Export nicht möglich:", "Cannot export:")
                        ),
                    });
                    drop(hold);
                },
            );
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn report_cannot_replace_a_source_renamed_after_comparison() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source.txt");
        let renamed = root.path().join("renamed.txt");
        std::fs::write(&source, "original").unwrap();
        let metadata = std::fs::metadata(&source).unwrap();
        let identity = fastra_io::FileIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
        };
        std::fs::rename(&source, &renamed).unwrap();
        assert!(protect_sources(&[source], &[identity], &renamed, Language(false)).is_err());
        assert_eq!(std::fs::read_to_string(renamed).unwrap(), "original");
    }
    #[test]
    fn missing_source_directory_allows_an_unrelated_report_but_not_the_moved_source() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("old");
        std::fs::create_dir(&directory).unwrap();
        let source = directory.join("source.txt");
        std::fs::write(&source, "original").unwrap();
        let metadata = std::fs::metadata(&source).unwrap();
        let identity = fastra_io::FileIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
        };
        let moved = root.path().join("moved");
        std::fs::rename(&directory, &moved).unwrap();
        let alias = root.path().join("alias.txt");
        std::fs::hard_link(moved.join("source.txt"), &alias).unwrap();
        assert!(protect_sources(
            std::slice::from_ref(&source),
            &[identity],
            &alias,
            Language(true)
        )
        .is_err());
        assert!(protect_sources(
            &[source],
            &[identity],
            &root.path().join("report.txt"),
            Language(true)
        )
        .is_ok());
    }
    #[test]
    fn report_cannot_replace_a_source_through_a_name_symlink_or_hardlink() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source.txt");
        std::fs::write(&source, "original").unwrap();
        let link = root.path().join("link.txt");
        std::os::unix::fs::symlink(&source, &link).unwrap();
        let hard = root.path().join("hard.txt");
        std::fs::hard_link(&source, &hard).unwrap();
        for target in [&source, &link, &hard] {
            assert!(
                protect_sources(std::slice::from_ref(&source), &[], target, Language(true))
                    .is_err()
            );
        }
        assert!(protect_sources(
            std::slice::from_ref(&source),
            &[],
            &root.path().join("report.txt"),
            Language(false)
        )
        .is_ok());
        assert_eq!(std::fs::read_to_string(source).unwrap(), "original");
    }
}
