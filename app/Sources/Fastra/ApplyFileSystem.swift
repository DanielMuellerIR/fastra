import Darwin
import Foundation

enum ApplyFileSystem {
    static let fileReadFlags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
    static let directoryReadFlags = fileReadFlags | O_DIRECTORY
    // Darwin weist O_NOFOLLOW_ANY zusammen mit O_NOFOLLOW ab.
    static let childFileReadFlags = fileReadFlags | O_NOFOLLOW
    static let childDirectoryReadFlags = directoryReadFlags | O_NOFOLLOW
    static let rootDirectoryReadFlags = directoryReadFlags | O_NOFOLLOW_ANY
    static let exclusiveRenameFlags = UInt32(RENAME_EXCL) | UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_RESOLVE_BENEATH)

    static func openRootDirectory(at url: URL) throws -> (descriptor: Int32, info: stat) {
        let descriptor = open(url.path, rootDirectoryReadFlags)
        guard descriptor >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = posixError()
            close(descriptor)
            throw failure
        }
        return (descriptor, info)
    }

    static func isApplyTemporaryFilename(_ name: String, targetName: String? = nil) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp"), !name.contains("/"), !name.utf8.contains(0) else {
            return false
        }
        if let targetName {
            guard !targetName.isEmpty, targetName != ".", targetName != "..",
                  !targetName.contains("/"), !targetName.utf8.contains(0) else {
                return false
            }
            let prefix = ".\(targetName).fastra-apply-"
            guard name.hasPrefix(prefix) else { return false }
            let uuidPart = String(name.dropFirst(prefix.count).dropLast(".tmp".count))
            return UUID(uuidString: uuidPart) != nil
        }
        guard let marker = name.range(of: ".fastra-apply-", options: .backwards) else {
            return false
        }
        let targetStart = name.index(after: name.startIndex)
        guard marker.lowerBound > targetStart else { return false }
        let extractedTarget = String(name[targetStart..<marker.lowerBound])
        guard extractedTarget != ".", extractedTarget != ".." else {
            return false
        }
        let uuidEnd = name.index(name.endIndex, offsetBy: -4)
        guard marker.upperBound < uuidEnd else { return false }
        let uuidPart = String(name[marker.upperBound..<uuidEnd])
        return UUID(uuidString: uuidPart) != nil
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func scanChildren(_ descriptor: Int32, limit: Int,
                             isCancelled: () -> Bool = { false }) throws -> (names: [String], limited: Bool) {
        // dup teilt den Verzeichnisoffset. openat startet am Anfang desselben Ordners.
        let scanFD = openat(descriptor, ".", childDirectoryReadFlags)
        guard scanFD >= 0 else { throw posixError() }
        guard let stream = fdopendir(scanFD) else {
            let failure = posixError()
            close(scanFD)
            throw failure
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            if isCancelled() { throw CancellationError() }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                if names.count == limit { return (names, true) }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw posixError() }
        return (names, false)
    }

    static func hasExtendedACL(_ descriptor: Int32,
                               matching predicate: (acl_entry_t?) throws -> Bool) throws -> Bool {
        guard let access = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(access)) }
        guard acl_valid(access) == 0 else { throw posixError() }
        var entry: acl_entry_t?
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(access, selector, &entry) == 0 {
            if try predicate(entry) { return true }
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        // Darwin meldet das Ende einer zuvor validierten ACL mit EINVAL.
        guard errno == EINVAL else { throw posixError() }
        return false
    }

    static func hasMutatingExtendedACL(_ descriptor: Int32) throws -> Bool {
        try hasExtendedACL(descriptor) { entry in
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw posixError() }
            guard tag == ACL_EXTENDED_ALLOW else { return false }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0 else { throw posixError() }
            for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                               ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                let granted = acl_get_perm_np(permissions, permission)
                guard granted >= 0 else { throw posixError() }
                if granted != 0 { return true }
            }
            return false
        }
    }
}
