import Foundation
import Observation
import TouchpointCore

/// Which screen the full-screen voice view shows. The decision is the pure
/// ``screen(callState:everConnected:failed:)`` below, so "connecting vs live vs ended vs failed" is
/// unit-testable without a running call (VO-1, VO-2). Mirrors `VoiceMiniRail.Phase` for the rail.
public enum VoiceScreen: Equatable, Sendable {
    /// Placing or joining the call: the loader (web's `Loader`, Android's `Loader`).
    case connecting
    /// The call: the orb and the microphone (web's `FullscreenVoice` live branch).
    case live
    /// A call that connected and then ended — "The conversation has ended" (web's `isTerminated`).
    case ended
    /// A call that never connected, or failed outright — "Oops!" with Retry (web's error branch,
    /// and its no-microphone failure).
    case failed
}

extension VoiceScreen {
    /// What to show, from the call's fused state and two view-owned facts: whether the call ever
    /// reached `.connected`, and whether a start threw or the first-join deadline passed.
    ///
    /// The rule follows web: the error screen shows **only when the call never connected** — a
    /// connect failure, a no-microphone start, or the VO-5 timeout. Once connected, any end (even a
    /// lost connection Chime could not recover) is the "ended" screen, as web's `isTerminated` is.
    public static func screen(callState: VoiceCallState, everConnected: Bool, failed: Bool) -> VoiceScreen {
        if failed { return .failed }
        switch callState {
        case .idle, .requesting, .connecting: return .connecting
        case .connected, .reconnecting, .interrupted: return .live
        case .ended: return everConnected ? .ended : .failed
        }
    }
}

/// An injectable sleep: the first-join timeout (VO-5) and the transport's speaking off-delay, so
/// both are testable without waiting. Mirrors `LiveSyncSleeping` in TouchpointLiveSync.
protocol VoiceSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousClockVoiceSleeper: VoiceSleeping {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// The full-screen voice view's brain (VO-1…VO-5): it owns the call's lifecycle for the view —
/// starting it, restarting it, ending it, hanging up when the view goes away — tracks which screen
/// to show, runs the first-join timeout, and exposes the Speakers toggle. Deliberately free of
/// UIKit so every rule here is tested on macOS; ``TouchpointVoiceView`` is the thin SwiftUI layer
/// over it.
///
/// It drives the existing ``TouchpointVoiceCall`` facade rather than reaching past it, so the
/// host-owned flow (the rail + CallKit) is untouched: a host that never shows this view sees no
/// change. Shown for a call the host already started, it adopts that call instead of starting a
/// second one.
@MainActor
@Observable
public final class TouchpointVoiceModel {
    /// The call this view controls and reflects.
    public let call: TouchpointVoiceCall

    /// Which screen to show. Recomputed from the call's state and the view's own facts.
    public private(set) var screen: VoiceScreen = .connecting

    /// Whether the customer hears the other side (VO-4). A read-through to the facade, so the view
    /// draws the Speakers control from one place.
    public var speakersOn: Bool { call.speakersOn }

    /// Fires once when a call this view shows and that connected has ended — an adopted call's end
    /// too — but not for a Restart's end, not for a call that never connected (web's
    /// `onVoiceSessionEnded`), and not once Minimise was tapped: the host follows the call from then.
    public var onEnded: (@MainActor (EndReason) -> Void)?

    @ObservationIgnored private let sleeper: any VoiceSleeping
    @ObservationIgnored private let firstJoinTimeout: Duration
    @ObservationIgnored private var everConnected = false
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var reportedEnd = false
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// - Parameters:
    ///   - call: the call to drive. The view-owned flow asks for the microphone through the
    ///     facade's own `permissionPolicy`, so a host using this view configures the call with a
    ///     policy that allows the microphone (otherwise the call fails and the view offers Retry).
    ///   - firstJoinTimeout: how long a call may take to connect before it is treated as failed
    ///     (VO-5). Defaults to the 30 s Android uses; not applied once the call has connected.
    public convenience init(call: TouchpointVoiceCall, firstJoinTimeout: Duration = .seconds(30)) {
        self.init(call: call, firstJoinTimeout: firstJoinTimeout, sleeper: ContinuousClockVoiceSleeper())
    }

    init(call: TouchpointVoiceCall, firstJoinTimeout: Duration, sleeper: any VoiceSleeping) {
        self.call = call
        self.firstJoinTimeout = firstJoinTimeout
        self.sleeper = sleeper
    }

    // MARK: View lifecycle

    /// The view appeared. Starts a call if one is not already running (web starts on mount); if the
    /// host already started this call, adopts it without starting a second. Idempotent.
    public func appear() {
        // Back on screen (a host that hides and shows the view keeps its model): it is wanted again.
        disappeared = false
        guard !started else { return }
        started = true
        switch call.state {
        case .idle, .ended:
            // Nothing running — a fresh facade, or one whose last call is over: place a call.
            begin()
        case .requesting, .connecting, .connected, .reconnecting, .interrupted:
            adopted = true
            everConnected = Self.isLive(call.state)
            recompute()
        }
    }

    /// Set when the view opened on a call the host had already started (the rail's expand, say).
    /// That call stays the host's: going away leaves it running, as the rail and CallKit expect. A
    /// call the view places itself (a Retry) is the view's again.
    @ObservationIgnored private var adopted = false
    /// Set by ``minimise()``: the call now belongs to the host, whoever started it.
    @ObservationIgnored private var handedOff = false
    /// Set by ``disappear()`` and cleared by ``appear()``, so a Restart still tearing down does not
    /// place a call for a view that is gone.
    @ObservationIgnored private var disappeared = false

    /// The view went away: hang up, as web's unmount does (VO-3) — for a call the view started. A
    /// call it adopted, or handed to the host with ``minimise()``, is left running, so collapsing
    /// the full screen back to the rail does not end it. A rotation that merely re-creates the view
    /// is the host's concern — SwiftUI keeps the model across one.
    public func disappear() {
        disappeared = true
        timeoutTask?.cancel()
        guard !adopted, !handedOff else { return }
        startTask?.cancel()
        Task { @MainActor [call] in await call.shutdown() }
    }

    // MARK: Controls

    /// Minimise (an iOS addition — web's full-screen voice has none): hand the call to the host, so
    /// dismissing the view does not hang up. Whatever this view was doing to place the call
    /// carries on; the first-join timeout, which only this view could act on, does not. From here
    /// the host shows the call (the rail, the system call UI) and learns its end from
    /// ``TouchpointVoiceCall/state`` — this view reports no ``onEnded`` from here on.
    public func minimise() {
        handedOff = true
        timeoutTask?.cancel()
    }

    /// Restart (VO-3): hang up, then call again. The ended/failed screen's Retry, and a host's own
    /// restart affordance, both land here.
    public func restart() {
        timeoutTask?.cancel()
        startTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.restarting = true
            self.recompute()
            await self.call.shutdown()
            self.restarting = false
            // The view hung up and went away meanwhile: nobody is left to want the new call. One
            // the customer minimised is still wanted, and is placed for the host.
            guard !self.disappeared || self.handedOff else {
                self.recompute()   // not stuck on the restart's loader if the view comes back
                return
            }
            self.begin()
        }
    }

    /// End the call (VO-3). The header's red close and a host's End both call this; the connected
    /// call then ends and the view shows "The conversation has ended".
    public func end() {
        Task { @MainActor [call] in try? await call.end() }
    }

    /// Toggle the Speakers control (VO-4): the other side's audio on or off.
    public func toggleSpeakers() {
        Task { @MainActor [call] in await call.setSpeakersOn(!call.speakersOn) }
    }

    // MARK: State in

    /// The call's fused state changed. The view feeds this from the facade's `state`; tests call it
    /// directly. Drives the screen, the first-join timeout's cancellation, and the end report.
    public func callStateChanged(_ state: VoiceCallState) {
        if Self.isLive(state), !everConnected {
            everConnected = true
            timeoutTask?.cancel()
        }
        if case .ended(let reason) = state, everConnected, !restarting, !reportedEnd, !handedOff {
            reportedEnd = true
            onEnded?(reason)
        }
        recompute(for: state)
    }

    /// The first-join deadline passed (VO-5). A no-op once the call connected, already failed, is
    /// restarting, or was handed to the host; otherwise the call is failed and hung up.
    func firstJoinDeadlineReached() {
        guard !everConnected, !failed, !restarting, !handedOff else { return }
        failed = true
        recompute()
        Task { @MainActor [call] in await call.shutdown() }
    }

    // MARK: Internals

    private func begin() {
        adopted = false        // a call this view places is the view's to hang up…
        // …and no longer the host's — unless the view has gone: a Restart finishing after Minimise
        // places the call for the host, with nobody here to time it out or hang it up.
        if !disappeared { handedOff = false }
        everConnected = false
        failed = false
        reportedEnd = false
        recompute()
        armTimeout()
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.call.start()
            } catch {
                // A start that throws — most often the microphone denied, which web treats as its
                // generic failure — is the failed screen, unless a Restart is already tearing down.
                guard !self.restarting else { return }
                self.failed = true
                self.recompute()
            }
        }
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        // A call handed to the host (a Restart finishing after a minimise) has no view to fail it.
        guard !handedOff else { return }
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.sleeper.sleep(for: self.firstJoinTimeout)
            guard !Task.isCancelled else { return }
            self.firstJoinDeadlineReached()
        }
    }

    private func recompute(for state: VoiceCallState? = nil) {
        if restarting { screen = .connecting; return }
        screen = VoiceScreen.screen(callState: state ?? call.state, everConnected: everConnected, failed: failed)
    }

    private static func isLive(_ state: VoiceCallState) -> Bool {
        switch state {
        case .connected, .reconnecting, .interrupted: true
        case .idle, .requesting, .connecting, .ended: false
        }
    }
}
