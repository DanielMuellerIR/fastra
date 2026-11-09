use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

fn fixture() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("fastra-read-test-")
        .tempdir_in(std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/var/tmp".into()))
        .unwrap()
}

#[test]
fn hardlinks_are_readable_but_never_become_write_snapshots() {
    let root = fixture();
    let path = root.path().join("source");
    let alias = root.path().join("alias");
    let cancel = Cancellation::default();
    std::fs::write(&path, "café 😀\r\n").unwrap();
    std::fs::hard_link(&path, &alias).unwrap();
    let source = ReadSnapshot::read(&path, &cancel).unwrap();
    let linked = ReadSnapshot::read(&alias, &cancel).unwrap();
    assert_eq!(source.bytes(), "café 😀\r\n".as_bytes());
    assert_eq!(source.file_identity(), linked.file_identity());
    assert!(!source.same_source(&linked));
    source.verify_current(&cancel).unwrap();
    linked.verify_current(&cancel).unwrap();
    assert!(matches!(
        Snapshot::read(&path, &cancel),
        Err(Error::UnsupportedMetadata)
    ));
    assert!(matches!(
        Snapshot::read(&alias, &cancel),
        Err(Error::UnsupportedMetadata)
    ));
}

#[test]
fn only_a_separately_read_writable_basis_matches_the_source() {
    let root = fixture();
    let path = root.path().join("source");
    let other = root.path().join("other");
    let cancel = Cancellation::default();
    std::fs::write(&path, "same bytes").unwrap();
    std::fs::write(&other, "same bytes").unwrap();
    let source = ReadSnapshot::read(&path, &cancel).unwrap();
    assert!(source.matches_writable_snapshot(&Snapshot::read(&path, &cancel).unwrap()));
    assert!(!source.matches_writable_snapshot(&Snapshot::read(&other, &cancel).unwrap()));
}

#[test]
fn read_limits_and_cancellation_are_enforced_before_allocating() {
    let root = fixture();
    let path = root.path().join("source");
    std::fs::write(&path, [b'x'; 65537]).unwrap();
    let cancel = Cancellation::default();
    assert!(matches!(
        ReadSnapshot::read_bounded(&path, 65536, &cancel),
        Err(Error::Limit)
    ));
    assert!(matches!(
        ReadSnapshot::read_bounded(&path, MAX_BYTES + 1, &cancel),
        Err(Error::Limit)
    ));
    assert_eq!(
        ReadSnapshot::read_bounded(&path, 65537, &cancel)
            .unwrap()
            .bytes()
            .len(),
        65537
    );
    cancel.cancel();
    assert!(matches!(
        ReadSnapshot::read(&path, &cancel),
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
}

#[test]
fn symlinks_fifo_and_directories_are_not_read_or_followed() {
    let root = fixture();
    let path = root.path().join("source");
    let alias = root.path().join("link");
    std::fs::write(&path, "plain").unwrap();
    symlink(&path, &alias).unwrap();
    let cancel = Cancellation::default();
    assert!(ReadSnapshot::read(&alias, &cancel).is_err());
    let directory = root.path().join("dir");
    std::fs::create_dir(&directory).unwrap();
    std::fs::write(directory.join("file"), "plain").unwrap();
    symlink(&directory, root.path().join("dir-link")).unwrap();
    assert!(ReadSnapshot::read(&root.path().join("dir-link/file"), &cancel).is_err());
    assert!(matches!(
        ReadSnapshot::read(&directory, &cancel),
        Err(Error::UnsupportedMetadata)
    ));
    let fifo = root.path().join("fifo");
    let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(matches!(
        ReadSnapshot::read(&fifo, &cancel),
        Err(Error::UnsupportedMetadata)
    ));
}

#[test]
fn execute_only_parent_is_sufficient_to_read_a_known_file() {
    let root = fixture();
    let dir = root.path().join("private");
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("known");
    std::fs::write(&path, "readable").unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o100)).unwrap();
    let result = ReadSnapshot::read(&path, &Cancellation::default());
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(result.unwrap().bytes(), b"readable");
}

#[test]
fn same_byte_replacement_and_parent_rename_invalidate_a_read_basis() {
    let root = fixture();
    let dir = root.path().join("dir");
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("file");
    std::fs::write(&path, "original").unwrap();
    let cancel = Cancellation::default();
    let old = ReadSnapshot::read(&path, &cancel).unwrap();
    std::fs::write(dir.join("replacement"), "original").unwrap();
    std::fs::rename(dir.join("replacement"), &path).unwrap();
    assert!(matches!(old.verify_current(&cancel), Err(Error::Stale)));
    let current = ReadSnapshot::read(&path, &cancel).unwrap();
    std::fs::rename(&dir, root.path().join("moved")).unwrap();
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(&path, "original").unwrap();
    assert!(matches!(current.verify_current(&cancel), Err(Error::Stale)));
}

#[test]
fn in_place_changes_with_restored_mtime_and_growth_are_rejected() {
    let root = fixture();
    let path = root.path().join("source");
    std::fs::write(&path, "original").unwrap();
    let cancel = Cancellation::default();
    let source = ReadSnapshot::read(&path, &cancel).unwrap();
    let file = File::options().write(true).open(&path).unwrap();
    let time = file.metadata().unwrap().modified().unwrap();
    file.set_len(0).unwrap();
    (&file).write_all(b"modified").unwrap();
    file.set_modified(time).unwrap();
    assert!(matches!(source.verify_current(&cancel), Err(Error::Stale)));
    let source = ReadSnapshot::read(&path, &cancel).unwrap();
    (&file).write_all(b" grows").unwrap();
    assert!(matches!(source.verify_current(&cancel), Err(Error::Limit)));
}
