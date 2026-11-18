import CoreServices
import Foundation

/// An agent running in a pane, as far as session-file events are concerned.
struct TrackedAgent: Equatable {
    let kind: AgentKind
    /// The agent's process and its descendants: Claude keys its session file
    /// by whichever of them it runs as (npm installs wrap it in `node`).
    let pids: Set<Int>

    /// Agents whose session switches show up as file events we watch. Their
    /// captures stay valid until an event says otherwise.
    var hasEventSource: Bool { AgentSessionWatch.eventKinds.contains(kind) }
}

/// Maps session-file changes to the panes whose capture they invalidate.
/// Pure: the paths come from `FileEventStream`, the panes from the cache.
enum AgentSessionWatch {
    static let eventKinds: Set<AgentKind> = [.claude, .codex]

    /// The directories whose changes mean an agent opened, switched or saved
    /// a session. A missing directory is replaced by its parent (the agent
    /// was installed but never run), or skipped when that is missing too.
    static func watchedDirectories(home: URL, exists: (String) -> Bool) -> [String] {
        [".claude/sessions", ".codex/sessions"].compactMap { relative in
            let directory = home.appendingPathComponent(relative)
            if exists(directory.path) { return directory.path }
            let parent = directory.deletingLastPathComponent().path
            return exists(parent) ? parent : nil
        }
    }

    /// `~/.claude/sessions/<pid>.json` → pid.
    static func claudePID(fromPath path: String) -> Int? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "json",
              url.deletingLastPathComponent().lastPathComponent == "sessions",
              url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".claude"
        else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem.allSatisfy(\.isASCII), stem.allSatisfy(\.isNumber) else { return nil }
        return Int(stem)
    }

    /// A Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-…jsonl`). It
    /// names no pid, so any change refreshes every Codex pane.
    static func isCodexRollout(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.contains("/.codex/sessions/") && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Whether any path is one the watcher cares about at all.
    static func isRelevant(_ paths: [String]) -> Bool {
        paths.contains { claudePID(fromPath: $0) != nil || isCodexRollout($0) }
    }

    static func panesToRefresh(changedPaths: [String], tracked: [UUID: TrackedAgent]) -> Set<UUID> {
        let claudePIDs = Set(changedPaths.compactMap(claudePID(fromPath:)))
        let codexChanged = changedPaths.contains(where: isCodexRollout)
        return Set(tracked.compactMap { pane, agent in
            switch agent.kind {
            case .claude: agent.pids.isDisjoint(with: claudePIDs) ? nil : pane
            case .codex: codexChanged ? pane : nil
            default: nil
            }
        })
    }
}

/// One FSEvents stream over a few directories, delivering changed file paths
/// on the main queue. The I/O edge for `AgentSessionWatch`.
///
/// Memory: the stream retains a small `Sink` (via the context's retain and
/// release callbacks) that holds only the handler, and the handler should
/// capture its owner weakly. Stopping, invalidating and releasing the stream
/// in `deinit` frees the sink, so nothing outlives the owner and a late
/// callback can never touch freed memory.
final class FileEventStream {
    typealias Handler = ([String]) -> Void

    private final class Sink {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?

    /// Nil when there is nothing to watch or FSEvents refused the stream.
    init?(directories: [String], latency: CFTimeInterval = 1.0, handler: @escaping Handler) {
        guard !directories.isEmpty else { return nil }
        let sink = Unmanaged.passRetained(Sink(handler))
        defer { sink.release() } // The stream holds its own retain from here on.
        var context = FSEventStreamContext(
            version: 0,
            info: sink.toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            // With UseCFTypes, `paths` is a CFArray of CFString.
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            guard count > 0, !changed.isEmpty else { return }
            Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().handler(changed)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
