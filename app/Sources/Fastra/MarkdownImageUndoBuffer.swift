import Foundation

/// Nur entfernte Bilddateien belegen diesen appweiten Puffer. Reservierungen
/// zählen schon vor dem Lesen; ausgeliehene Daten dürfen nicht verdrängt werden.
final class MarkdownImageUndoBuffer: @unchecked Sendable {
    static let shared = MarkdownImageUndoBuffer(byteLimit: 512 * 1024 * 1024)

    private struct Entry {
        let size: Int
        let order: UInt64
        let invalidated: () -> Void
        var data: [Data]?
        var borrowers = 0
    }

    let byteLimit: Int
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var sequence: UInt64 = 0
    private var retainedBytes = 0
    private var notifications: [() -> Void] = []

    init(byteLimit: Int) { self.byteLimit = max(0, byteLimit) }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedBytes
    }

    func reserve(bytes: Int, invalidated: @escaping () -> Void) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard bytes >= 0, bytes <= byteLimit else { return nil }
        while bytes > byteLimit - retainedBytes {
            guard let oldest = entries.filter({ $0.value.data != nil && $0.value.borrowers == 0 })
                .min(by: { $0.value.order < $1.value.order }) else { return nil }
            entries.removeValue(forKey: oldest.key)
            retainedBytes -= oldest.value.size
            notifications.append(oldest.value.invalidated)
        }
        let id = UUID()
        sequence &+= 1
        entries[id] = Entry(size: bytes, order: sequence, invalidated: invalidated)
        retainedBytes += bytes
        return id
    }

    func fill(_ id: UUID, with data: [Data]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], data.reduce(0, { $0 + $1.count }) == entry.size else { return false }
        entries[id]?.data = data
        return true
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.data != nil
    }

    func withData<T>(_ id: UUID, _ body: ([Data]) throws -> T) rethrows -> T? {
        lock.lock()
        guard let data = entries[id]?.data else { lock.unlock(); return nil }
        entries[id]?.borrowers += 1
        lock.unlock()
        defer {
            lock.lock()
            entries[id]?.borrowers -= 1
            lock.unlock()
        }
        return try body(data)
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], entry.borrowers == 0 else { return }
        entries.removeValue(forKey: id)
        retainedBytes -= entry.size
    }

    /// Erst nach der zugehörigen Textaktion zustellen: Sonst könnte deren
    /// lokale Undo-Gruppe nach dem Leeren des Verlaufs erneut eingehängt werden.
    func takeInvalidations() -> [() -> Void] {
        lock.lock()
        defer { lock.unlock() }
        let pending = notifications
        notifications.removeAll()
        return pending
    }

    func invalidate(_ action: @escaping () -> Void) {
        lock.lock()
        notifications.append(action)
        lock.unlock()
    }
}
