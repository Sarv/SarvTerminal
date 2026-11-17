import AppKit
import Combine

/// One pane's reading on a watcher tick, gathered at the edge so the store's
/// tick logic stays free of AppKit.
struct AgentPaneSample: Equatable {
    var foreground: String?
    /// The active screen area's text, read only for panes that need it.
    var screenTail: String?
    /// The pane's tab is on screen in a window while the app is active.
    var onScreen: Bool
}

/// What the UI shows for one pane. Kept apart from `AgentPaneState` so a
/// spinner frame, which only bumps bookkeeping, does not redraw the strip.
struct AgentPaneSnapshot: Equatable {
    let state: AgentState
    let since: Date
}

/// An effect from one pane, for the notification edge.
struct AgentWatcherEffect: Equatable {
    let surfaceID: UUID
    let effect: AgentEffect
    /// The agent's own words, when a desktop notification caused the effect.
    var message: String?
}

/// App-wide agent state for every pane, keyed by surface id. Feeds terminal
/// signals through `AgentStateReducer` and publishes the result; the reducer
/// owns every decision.
@MainActor
final class AgentWatcherStore: ObservableObject {
    static let shared = AgentWatcherStore(clock: Date.init)

    /// The Settings ▸ AI Agents switch. On unless the user turned it off.
    static let enabledKey = "SarvAgentWatcherEnabled"
    static var enabledInSettings: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// How often the watcher samples foreground processes and screens.
    static let tickInterval: TimeInterval = 2

    /// Full reducer state per pane. Not published: it changes on every
    /// spinner frame.
    private(set) var panes: [UUID: AgentPaneState] = [:]
    /// State and since per agent pane, published only when one of them changes.
    @Published private(set) var snapshots: [UUID: AgentPaneSnapshot] = [:]
    /// Notify and remind effects, for the notification edge.
    let effects = PassthroughSubject<AgentWatcherEffect, Never>()

    /// Whether the watcher runs. Off means no icon, no tab dots, no
    /// sampling, no signal handling and no notifications.
    @Published private(set) var isEnabled = false

    private let clock: () -> Date
    /// How long a finished pane shows done before viewing it turns it idle.
    private let doneHold: () -> TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private lazy var socket = AgentStatusSocket { [weak self] line in self?.receive(line) }
    /// Agents whose hook setup was offered this session.
    private var offeredHookSetups: Set<String> = []

    init(clock: @escaping () -> Date, doneHold: @escaping () -> TimeInterval = { AgentDoneHold.current.seconds }) {
        self.clock = clock
        self.doneHold = doneHold
    }

    /// Saves the Settings switch and starts or stops the watcher to match.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    /// Starts listening to terminal signals and sampling every surface.
    /// Safe to call more than once.
    func start() {
        guard timer == nil else { return }
        isEnabled = true
        observeSignals()
        do {
            try socket.start()
        } catch {
            Ghostty.logger.warning("agent status socket unavailable: \(error.localizedDescription)")
        }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops listening and sampling and forgets every pane, so the icon and
    /// tab dots go away. Safe to call more than once.
    func stop() {
        timer?.invalidate()
        timer = nil
        socket.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panes = [:]
        snapshots = [:]
        isEnabled = false
    }

    func state(of surfaceID: UUID) -> AgentState {
        panes[surfaceID]?.state ?? .noAgent
    }

    /// Republishes one pane's snapshot, only when its state or since changed.
    private func publishSnapshot(of surfaceID: UUID) {
        let next = panes[surfaceID].flatMap { pane in
            pane.state.isAgent ? AgentPaneSnapshot(state: pane.state, since: pane.since) : nil
        }
        if snapshots[surfaceID] != next { snapshots[surfaceID] = next }
    }

    /// Feeds one signal for one pane through the reducer.
    func send(_ event: AgentEvent, to surfaceID: UUID) {
        let now = clock()
        let current = panes[surfaceID] ?? AgentPaneState(since: now)
        let (next, effects) = AgentStateReducer.reduce(current, event, now: now)
        if next != current {
            panes[surfaceID] = next
            publishSnapshot(of: surfaceID)
        }
        let message: String? = if case .notification(let body) = event { body } else { nil }
        for effect in effects {
            self.effects.send(AgentWatcherEffect(surfaceID: surfaceID, effect: effect, message: message))
        }
    }

    /// One watcher tick over the given panes. Panes missing from `samples`
    /// no longer exist and are dropped.
    func tick(_ samples: [UUID: AgentPaneSample]) {
        let gone = Set(panes.keys).subtracting(samples.keys)
        for id in gone {
            panes[id] = nil
            publishSnapshot(of: id)
        }
        let doneHold = doneHold()
        for (id, sample) in samples {
            send(.foreground(sample.foreground), to: id)
            if let tail = sample.screenTail { send(.screenSample(tail), to: id) }
            if sample.onScreen { send(.viewed(doneHold: doneHold), to: id) }
            send(.tick, to: id)
        }
    }

    /// Whether a tick should read this pane's screen: only a finished pane,
    /// or one waiting on a prompt the screen showed, can change from it.
    func needsScreenSample(_ surfaceID: UUID) -> Bool {
        guard let pane = panes[surfaceID] else { return false }
        switch pane.state {
        case .done: return true
        case .needsYou: return pane.needsYouSource == .screen
        default: return false
        }
    }

    // MARK: - Edges

    private func observeSignals() {
        observe(.sarvSurfaceProgress) { note in
            (note.userInfo?["progress"] as? AgentProgress).map(AgentEvent.progress)
        }
        observe(.sarvSurfaceTitle) { note in
            (note.userInfo?["title"] as? String).map(AgentEvent.title)
        }
        observe(.sarvSurfaceDesktopNotification) { note in
            (note.userInfo?["body"] as? String).map(AgentEvent.notification)
        }
        observe(.sarvSurfaceProgramStatus) { note in
            (note.userInfo?["status"] as? AgentProgramStatus).map(AgentEvent.programStatus)
        }
        let activated = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleAll() }
        }
        observers.append(activated)
    }

    private func observe(_ name: Notification.Name, event: @escaping (Notification) -> AgentEvent?) {
        let token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] note in
            guard let surface = note.object as? Ghostty.SurfaceView,
                  let agentEvent = event(note)
            else { return }
            let surfaceID = surface.id
            MainActor.assumeIsolated { self?.send(agentEvent, to: surfaceID) }
        }
        observers.append(token)
    }

    /// Samples every pane in every Vaults window. Also called when a tab is
    /// selected, so a finished tab turns idle without waiting for the tick.
    func sampleAll() {
        guard isEnabled else { return }
        var samples: [UUID: AgentPaneSample] = [:]
        for controller in HostManagerController.all {
            let model = controller.tabs
            // Seen means SarvTerminal is the active app, not just a window
            // left visible behind another app.
            let windowVisible = NSApp.isActive && controller.window?.isVisible == true
                && controller.window?.isMiniaturized == false
            for tab in model.terminals {
                let visible = windowVisible ? model.visiblePaneIDs(of: tab) : []
                for surface in tab.surfaceTree.root?.leaves() ?? [] {
                    samples[surface.id] = AgentPaneSample(
                        foreground: surface.surfaceModel?.foregroundProcessName,
                        screenTail: needsScreenSample(surface.id) ? surface.liveActiveText() : nil,
                        onScreen: visible.contains(surface.id))
                }
            }
        }
        tick(samples)
        offerHookSetup(runningProcesses: samples.values.compactMap(\.foreground))
    }

    /// Feeds one line from the status socket to its pane. Lines naming no
    /// pane of this app are dropped.
    func receive(_ line: String) {
        guard isEnabled, let message = AgentStatusMessage.parse(line),
              HostManagerController.all.contains(where: { controller in
                  controller.tabs.terminals.contains { tab in
                      tab.surfaceTree.root?.leaves().contains { $0.id == message.paneID } == true
                  }
              })
        else { return }
        send(.programStatus(message.status), to: message.paneID)
    }

    /// Offers, once per session, to set up hooks for an agent that runs
    /// without them.
    private func offerHookSetup(runningProcesses: [String]) {
        guard let integration = AgentHookOffer.candidate(
            runningProcesses: runningProcesses, offered: offeredHookSetups,
            declined: AgentHookOffer.declined, isInstalled: { $0.isInstalled() })
        else { return }
        offeredHookSetups.insert(integration.id)
        AgentHookOffer.present(integration)
    }
}
