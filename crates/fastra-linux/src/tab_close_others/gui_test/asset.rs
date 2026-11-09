use super::*;
pub(super) fn run(ui: Rc<Ui>) {
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("asset-worker.bin");
    std::fs::write(root.join("pause-main"), b"").unwrap();
    ui.add_document("Keep.txt", "keep");
    let keep = ui.active().unwrap();
    ui.add_document("Previous.txt", "previous");
    let previous = ui.active().unwrap();
    let docs = ui.documents.borrow().clone();
    let complete = Rc::new(Cell::new(false));
    let done = complete.clone();
    let output = path.clone();
    super::super::super::asset_io::background(
        move || {
            std::fs::write(output, b"bounded actual asset worker")
                .map_err(|error| error.to_string())
        },
        move |result| {
            result.unwrap();
            done.set(true);
        },
    );
    let stage = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(35),
            "asset stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 if root.join("ready-main").exists()
                && pause.get().elapsed() > Duration::from_millis(500) =>
            {
                assert!(super::super::super::asset_io::pending());
                assert!(!complete.get());
                assert_eq!(
                    std::fs::read(&path).unwrap(),
                    b"bounded actual asset worker"
                );
                menu(&ui, &keep);
                stage.set(1);
            }
            1 => {
                if let Some(action) = others(&ui, &keep) {
                    click(action.upcast_ref(), "1");
                    pause.set(Instant::now());
                    stage.set(2);
                }
            }
            2 if !close_protocol::active(&ui)
                && pause.get().elapsed() > Duration::from_millis(500) =>
            {
                same(&ui, &docs);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                assert!(super::super::super::asset_io::pending());
                assert!(!complete.get());
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("Bilddateivorgang", "Image file operation")));
                std::fs::write(root.join("release-main"), b"").unwrap();
                stage.set(3);
            }
            3 if complete.get() && !super::super::super::asset_io::pending() => {
                menu(&ui, &keep);
                stage.set(4);
            }
            4 => {
                if let Some(action) = others(&ui, &keep) {
                    click(action.upcast_ref(), "1");
                    stage.set(5);
                }
            }
            5 if !close_protocol::active(&ui) && ui.documents.borrow().len() == 1 => {
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &keep));
                assert_eq!(
                    std::fs::read(&path).unwrap(),
                    b"bounded actual asset worker"
                );
                println!("PASS close others asset: actual bounded file worker finished but final Main receipt still pending blocks real context action; after owned completion idle action succeeds without losing receipt or bytes");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
