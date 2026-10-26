import Foundation
import Darwin

/// A per-user OS lock closes the race between simultaneous launches. The OS
/// releases it on crashes too; the file is deliberately not deleted on exit.
final class AppInstanceLock {
    private var descriptor: Int32 = -1
    private let url: URL

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-status-board/app-instance.lock")) {
        self.url = url
    }

    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        fchmod(fd, 0o600)
        descriptor = fd
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
