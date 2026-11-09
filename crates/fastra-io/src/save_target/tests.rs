use super::*;
use std::fs;
fn fixture() -> tempfile::TempDir {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    tempfile::tempdir_in(root).unwrap()
}
#[test]
fn absent_anchor_has_no_placeholder_and_cannot_follow_a_replaced_parent() {
    let root = fixture();
    let folder = root.path().join("destination");
    fs::create_dir(&folder).unwrap();
    let path = folder.join("copy.md");
    let cancel = Cancellation::default();
    let target = Target::capture(&path, &cancel).unwrap();
    assert!(target.existing().is_none());
    assert!(!path.exists());
    fs::rename(&folder, root.path().join("old-folder")).unwrap();
    fs::create_dir(&folder).unwrap();
    assert!(target.publish(b"new text", &cancel).is_err());
    assert!(!path.exists());
    assert!(!root.path().join("old-folder/copy.md").exists());
}
#[test]
fn new_and_confirmed_existing_targets_are_bound_even_when_bytes_match() {
    let root = fixture();
    let path = root.path().join("copy.md");
    let cancel = Cancellation::default();
    let target = Target::capture(&path, &cancel).unwrap();
    fs::write(&path, "occupied").unwrap();
    assert!(target.publish(b"wanted", &cancel).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"occupied");
    let target = Target::capture(&path, &cancel).unwrap();
    fs::rename(&path, root.path().join("previous")).unwrap();
    fs::write(&path, "occupied").unwrap();
    assert!(target.publish(b"occupied", &cancel).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"occupied");
    let target = Target::capture(&path, &cancel).unwrap();
    let result = target.publish(b"confirmed replacement", &cancel).unwrap();
    assert_eq!(result.path(), path);
    assert_eq!(result.bytes(), b"confirmed replacement");
}
#[test]
fn new_target_and_asset_plan_share_the_held_absent_anchor() {
    use crate::markdown_assets::{Input, Owner, Plan};
    let root = fixture();
    let path = root.path().join("copy.md");
    let cancel = Cancellation::default();
    let target = Target::capture(&path, &cancel).unwrap();
    let owner = Owner {
        document: "save-as".into(),
        revision: 1,
        generation: 1,
    };
    let plan = Plan::prepare_at(
        target.clone(),
        owner.clone(),
        vec![Input {
            extension: "png".into(),
            bytes: Arc::new(b"full image bytes".to_vec()),
        }],
        &cancel,
    )
    .unwrap();
    assert!(!path.exists());
    assert!(!root.path().join("images").exists());
    let receipt = plan.apply(&owner, &cancel).unwrap();
    assert!(!path.exists());
    let saved = target
        .publish(b"![image](images/1.png)\r\n", &cancel)
        .unwrap();
    assert_eq!(saved.bytes(), b"![image](images/1.png)\r\n");
    assert_eq!(
        fs::read(root.path().join(&receipt.preview()[0].relative)).unwrap(),
        b"full image bytes"
    );
}
#[test]
fn special_targets_are_refused_without_changing_their_sources() {
    use std::os::unix::fs::symlink;
    let root = fixture();
    let original = root.path().join("original");
    fs::write(&original, "original").unwrap();
    let link = root.path().join("link");
    symlink(&original, &link).unwrap();
    assert!(Target::capture(&link, &Cancellation::default()).is_err());
    let hard = root.path().join("hard");
    fs::hard_link(&original, &hard).unwrap();
    assert!(Target::capture(&hard, &Cancellation::default()).is_err());
    let fifo = root.path().join("fifo");
    let encoded = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(encoded.as_ptr(), 0o600) }, 0);
    assert!(Target::capture(&fifo, &Cancellation::default()).is_err());
    assert_eq!(fs::read(original).unwrap(), b"original");
}

#[test]
fn final_create_collision_and_parent_swap_preserve_every_foreign_target() {
    for replace_parent in [false, true] {
        let root = fixture();
        let folder = root.path().join("folder");
        fs::create_dir(&folder).unwrap();
        let path = folder.join("copy.md");
        let target = Target::capture(&path, &Cancellation::default()).unwrap();
        let moved = root.path().join("held-folder");
        let folder_copy = folder.clone();
        RACE.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |phase, path| {
                if phase == "before-new-publish" {
                    if replace_parent {
                        fs::rename(&folder_copy, &moved).unwrap();
                        fs::create_dir(&folder_copy).unwrap();
                    }
                    fs::write(path, "Foreign final target").unwrap();
                }
            }))
        });
        assert!(target
            .publish(b"approved", &Cancellation::default())
            .is_err());
        RACE.with(|hook| hook.borrow_mut().take());
        assert_eq!(fs::read(path).unwrap(), b"Foreign final target");
    }
}
#[test]
fn temp_fd_is_bound_to_input_and_replaced_temp_paths_are_not_cleaned_up() {
    for replace in [false, true] {
        let root = fixture();
        let path = root.path().join("copy.md");
        let target = Target::capture(&path, &Cancellation::default()).unwrap();
        let observed = Arc::new(std::sync::Mutex::new(None));
        let copy = observed.clone();
        RACE.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |phase, path| {
                if phase == "before-new-hash" {
                    if replace {
                        fs::rename(path, path.with_extension("held")).unwrap();
                    }
                    fs::write(path, "Foreign temporary bytes").unwrap();
                    *copy.lock().unwrap() = Some(path.to_owned());
                }
            }))
        });
        assert!(target
            .publish(b"approved", &Cancellation::default())
            .is_err());
        RACE.with(|hook| hook.borrow_mut().take());
        assert!(!path.exists());
        if replace {
            assert_eq!(
                fs::read(observed.lock().unwrap().as_ref().unwrap()).unwrap(),
                b"Foreign temporary bytes"
            );
        }
    }
}
#[test]
fn raw_utf8_collision_names_remain_distinct() {
    let root = fixture();
    let raw = root
        .path()
        .join(OsString::from_vec(b"raw-\xff.md".to_vec()));
    let replacement = root.path().join("raw-�.md");
    fs::write(&replacement, "Foreign replacement-name file").unwrap();
    let target = Target::capture(&raw, &Cancellation::default()).unwrap();
    let saved = target
        .publish(b"raw target", &Cancellation::default())
        .unwrap();
    assert_eq!(saved.path(), raw);
    assert_eq!(
        fs::read(replacement).unwrap(),
        b"Foreign replacement-name file"
    );
}
