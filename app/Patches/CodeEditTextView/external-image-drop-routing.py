import sys

path = sys.argv[1]
src = open(path).read()
old_entered = '''    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        determineDragOperation(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        determineDragOperation(sender)
    }'''
new_entered = '''    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Fastra-Patch: externer Drop wird vor dem Standard-Textdrag geroutet.
        fastraExternalDraggingUpdated(sender) ?? determineDragOperation(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fastraExternalDraggingUpdated(sender) ?? determineDragOperation(sender)
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fastraCleanUpExternalDrop()
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        fastraCleanUpExternalDrop()
    }'''
old_perform = '''    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: pasteboardObjects)?'''
new_perform = '''    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let externalResult = fastraPerformExternalDrop(sender) {
            return externalResult
        }
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: pasteboardObjects)?'''
if old_entered not in src or old_perform not in src:
    raise SystemExit(f"{path}: Drag-Zielstruktur hat sich geaendert — Patch 4z3 pruefen")
src = src.replace(old_entered, new_entered, 1).replace(old_perform, new_perform, 1)
open(path, "w").write(src)
