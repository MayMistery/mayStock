#if canImport(Darwin)
import Foundation

/// Calls back whenever a file may have changed: written in place, replaced
/// by a rename — how `Data.write(options: .atomic)` and most editors save —
/// created, or deleted.
///
/// Watches the directory as well as the file. A watch on the file alone goes
/// deaf at the first atomic save: the name then points at a new file, and
/// the one watched is the copy just replaced. The directory hears the
/// rename, and the file watch is moved to whatever the name points at now.
///
/// "May have changed" is all it promises — the caller compares contents.
/// Bursts are coalesced into one call (an atomic save is a create and a
/// rename, an editor's save several writes), and writes to other files in
/// the same directory call back too. Create it, and cancel it, on `queue`.
public final class FileWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    /// The file the file watch is on, so a directory event can tell whether
    /// the name now points elsewhere.
    private var watchedFile: (device: dev_t, inode: ino_t)?
    private var callScheduled = false

    public init(
        url: URL, queue: DispatchQueue = .main, coalescingFor delay: TimeInterval = 0.05,
        onChange: @escaping () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.delay = delay
        self.onChange = onChange
        let directory = url.deletingLastPathComponent().path
        directorySource = watch(directory, for: [.write, .rename, .delete, .revoke]) { [weak self] _ in
            self?.followName()
            self?.changed()
        }
        if directorySource == nil {
            Log.warn("watch: 监视不了 \(directory)（\(String(cString: strerror(errno)))），"
                     + "\(url.lastPathComponent) 被整个替换时这里听不到")
        }
        followName()
    }

    deinit { cancel() }

    public func cancel() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        watchedFile = nil
    }

    /// Point the file watch at whatever the name refers to now, unless it is
    /// already there.
    private func followName() {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            fileSource?.cancel()
            fileSource = nil
            watchedFile = nil
            return
        }
        if fileSource != nil, let watched = watchedFile,
           watched.device == info.st_dev, watched.inode == info.st_ino {
            return
        }
        fileSource?.cancel()
        fileSource = watch(url.path, for: [.write, .extend, .attrib, .rename, .delete, .revoke]) { [weak self] events in
            if !events.isDisjoint(with: [.rename, .delete, .revoke]) { self?.followName() }
            self?.changed()
        }
        watchedFile = fileSource == nil ? nil : (info.st_dev, info.st_ino)
    }

    private func watch(
        _ path: String, for events: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak source] in handler(source?.data ?? []) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func changed() {
        guard !callScheduled else { return }
        callScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.callScheduled = false
            self.onChange()
        }
    }
}
#endif
