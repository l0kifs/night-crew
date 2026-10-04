import Foundation

// Side effects stay behind these so the poll cycle runs against fakes in tests (SPEC §4).
public protocol ProcessProbing {
    func processes() -> [ProcessRecord]
}

public protocol TranscriptProbing {
    func snapshot(claudeFolders: Set<String>, now: Date) -> TranscriptSnapshot
}

public protocol PowerSensing {
    func read() -> PowerReading
}

public protocol OwnershipReading {
    /// `~/.nightcrew/owned` exists (SPEC §8).
    func isOwned() -> Bool
}

public protocol Clock {
    var now: Date { get }
}

public struct Tick: Equatable, Sendable {
    public var at: Date
    public var output: Output
    public var activity: ActivityReport
    public var power: PowerReading
}

/// One poll cycle (SPEC §6.1): probes → ActivityTracker → Engine. Scheduling lives in the app layer.
public struct Poller {
    public var config: Config {
        didSet {
            tracker.config = config
            engine.config = config
        }
    }
    public var matcher = Matcher.defaults
    /// Minimum gap between polls triggered by transcript writes.
    public var transcriptTriggerGap: TimeInterval = 1
    /// `lastWorkingAt` is persisted at most this often while working (SPEC §6.2).
    public var persistInterval: TimeInterval = 30

    private let processes: any ProcessProbing
    private let transcripts: any TranscriptProbing
    private let power: any PowerSensing
    private let ownership: any OwnershipReading
    private let clock: any Clock
    private var tracker: ActivityTracker
    private var engine: Engine
    private var lastTick: Tick?
    private var lastPersisted: Date?
    private var lastSeenWorkingAt: Date?

    public init(config: Config = Config(), lastWorkingAt: Date? = nil, processes: any ProcessProbing,
                transcripts: any TranscriptProbing, power: any PowerSensing, ownership: any OwnershipReading,
                clock: any Clock) {
        self.config = config
        self.processes = processes
        self.transcripts = transcripts
        self.power = power
        self.ownership = ownership
        self.clock = clock
        tracker = ActivityTracker(config: config)
        engine = Engine(config: config, lastWorkingAt: lastWorkingAt)
        lastPersisted = lastWorkingAt
    }

    public mutating func tick(mode: Mode) -> Tick {
        let now = clock.now
        let processList = processes.processes()
        let roots = matcher.sessionRoots(in: processList)
        let folders = Set(roots.filter { $0.agent == .claude }.compactMap { $0.cwd.map(Transcripts.claudeProjectFolder) })
        let activity = tracker.update(now: now, processes: processList, roots: roots,
                                      transcripts: transcripts.snapshot(claudeFolders: folders, now: now))
        let reading = power.read()

        var inputs = Inputs(now: now)
        inputs.sessions = activity.engineSessions
        inputs.lidClosed = reading.lidClosed
        inputs.externalDisplayOnline = reading.externalDisplayOnline
        inputs.builtinDisplayAsleep = reading.builtinDisplayAsleep
        inputs.onBattery = reading.onBattery
        inputs.batteryPercent = reading.batteryPercent
        inputs.thermal = reading.thermal
        inputs.sleepDisabled = reading.sleepDisabled
        inputs.owned = ownership.isOwned()
        inputs.mode = mode

        let tick = Tick(at: now, output: engine.step(inputs), activity: activity, power: reading)
        lastTick = tick
        return tick
    }

    /// A transcript write polls at once only while the Mac is not kept awake: that is the start-of-work case
    /// FSEvents exists for (SPEC §5.3). While awake, writes change nothing urgent and the timer suffices.
    public func shouldPollOnTranscriptChange() -> Bool {
        guard let last = lastTick else { return true }
        return !last.output.awake && clock.now.timeIntervalSince(last.at) >= transcriptTriggerGap
    }

    /// Call once per tick. The `lastWorkingAt` to persist now: at most every `persistInterval` while it keeps
    /// moving, and immediately once it stops moving (work ended), so a restart sees the exact value.
    public mutating func lastWorkingAtToPersist() -> Date? {
        let current = engine.lastWorkingAt
        defer { lastSeenWorkingAt = current }
        guard let current, current != lastPersisted else { return nil }
        let settled = current == lastSeenWorkingAt
        if !settled, let previous = lastPersisted, current.timeIntervalSince(previous) < persistInterval { return nil }
        lastPersisted = current
        return current
    }

    public mutating func record(_ outcome: Outcome) {
        engine.record(outcome, at: clock.now)
    }

    public mutating func retry() {
        engine.retry()
    }
}
