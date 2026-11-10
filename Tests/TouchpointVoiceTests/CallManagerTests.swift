import Foundation
import Testing
import TouchpointCore
@testable import TouchpointVoice

// MARK: - TouchpointCallManager — outbound CallKit behind protocols

/// Records what the manager asked CallKit for and lets a test play the system's side.
@MainActor
final class FakeCallSystem: CallProviding, CallControlling {
    var configuration: CallProviderConfiguration?
    var requested: [CallSystemRequest] = []
    var reported: [CallSystemReport] = []
    var requestError: Error?
    /// Perform the start action inside `request`, as the real system can before the request returns.
    var performStartDuringRequest = false
    /// And activate the audio session too, still inside `request`.
    var activateDuringRequest = false
    weak var delegate: CallProviderDelegate?

    func setDelegate(_ d: any CallProviderDelegate) { delegate = d }
    func request(_ request: CallSystemRequest) async throws {
        requested.append(request)
        if let requestError { throw requestError }
        if performStartDuringRequest, case .start(let id, _) = request {
            _ = await delegate?.performStartCall(id)
            if activateDuringRequest { await delegate?.audioSessionDidActivate() }
        }
    }
    func report(_ report: CallSystemReport) { reported.append(report) }

    // The system performing what we requested:
    func performStart(_ id: UUID) async -> Bool { await delegate?.performStartCall(id) ?? false }
    func performEnd(_ id: UUID) async -> Bool { await delegate?.performEndCall(id) ?? false }
    func performMute(_ id: UUID, _ muted: Bool) async -> Bool { await delegate?.performSetMuted(id, muted) ?? false }
    func activateAudio() async { await delegate?.audioSessionDidActivate() }
    func deactivateAudio() async { await delegate?.audioSessionDidDeactivate() }
    func reset() async { await delegate?.providerDidReset() }
    func timeout(_ id: UUID) async { await delegate?.actionTimedOut(id) }
}

/// What the manager drives: start media, end, mute. Records order so the ordering test is exact.
/// The closures capture the fake strongly: the manager owns `CallActions`, so the fake lives as
/// long as the manager — which is also how a host's own hooks behave.
@MainActor
final class FakeCallActions {
    var log: [String] = []
    var muteError: Error?
    var configureError: Error?
    var actions: CallActions {
        CallActions(
            configureAudioSession: { self.log.append("configureAudio"); if let e = self.configureError { throw e } },
            startMedia: { self.log.append("startMedia") },
            endCall: { self.log.append("endCall") },
            setMuted: { m in self.log.append("mute:\(m)"); if let e = self.muteError { throw e } }
        )
    }
}

@Suite("TouchpointCallManager")
@MainActor
struct CallManagerTests {
    private func make(backgroundModes: [String] = ["audio"]) -> (TouchpointCallManager, FakeCallSystem, FakeCallActions, Capture<[TouchpointError]>) {
        let sys = FakeCallSystem(); let acts = FakeCallActions()
        let errors = Capture<[TouchpointError]>([])
        let m = TouchpointCallManager(provider: sys, controller: sys, actions: acts.actions, backgroundModes: backgroundModes, displayName: "Acme Bank")
        m.onError = { errors.value.append($0) }
        return (m, sys, acts, errors)
    }

    @Test("K1: startCall requests a CXStartCallAction with a generic handle carrying the display name, and the provider is configured without hold or video")
    func startRequests() async throws {
        let (m, sys, _, _) = make()
        let id = try await m.startCall()
        #expect(sys.requested == [.start(id, handle: "Acme Bank")])
        let c = try #require(sys.configuration)
        #expect(!c.supportsHolding)
        #expect(!c.supportsVideo)
        #expect(c.maximumCallsPerCallGroup == 1)
        #expect(c.maximumCallGroups == 1)
        #expect(c.supportedHandleTypes == [.generic])
        #expect(!c.includesCallsInRecents, "a call to a bank does not go to Recents unless the host opts in")
        #expect(m.state == .requesting)
    }

    @Test("K3: ordering — the start action configures the audio session and fulfils; media starts only when the audio session activates")
    func mediaWaitsForAudioSession() async throws {
        let (m, sys, acts, _) = make()
        let id = try await m.startCall()
        #expect(await sys.performStart(id))
        #expect(acts.log == ["configureAudio"], "fulfilled with the category set, nothing else — no network inside the action handler")
        #expect(m.state == .connecting)
        #expect(sys.reported == [.outgoingStartedConnecting(id)])
        await sys.activateAudio()
        #expect(acts.log == ["configureAudio", "startMedia"])
    }

    @Test("K3b: an audio activation that arrives without a pending start does nothing")
    func strayActivation() async {
        let (_, sys, acts, _) = make()
        await sys.activateAudio()
        #expect(acts.log.isEmpty)
    }

    @Test("K3c: the start action for an unknown call UUID is failed, not fulfilled")
    func unknownStart() async throws {
        let (m, sys, acts, _) = make()
        _ = try await m.startCall()
        #expect(!(await sys.performStart(UUID())))
        #expect(acts.log.isEmpty)
    }

    @Test("K4: end and mute actions reach the transport and are fulfilled; a refused mute fails the action")
    func endAndMute() async throws {
        let (m, sys, acts, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio()
        #expect(await sys.performMute(id, true))
        #expect(acts.log.last == "mute:true")
        acts.muteError = TouchpointError.transportFailure("refused")
        #expect(!(await sys.performMute(id, false)))
        #expect(await sys.performEnd(id))
        #expect(acts.log.last == "endCall")
        #expect(m.state == .idle)
    }

    @Test("K4b: the app's own end/mute go through CallKit, not around it")
    func appControlsRequest() async throws {
        let (m, sys, _, _) = make()
        let id = try await m.startCall()
        try await m.setMuted(true)
        try await m.endCall()
        #expect(sys.requested == [.start(id, handle: "Acme Bank"), .setMuted(id, true), .end(id)])
    }

    @Test("K5: the transport reporting connected / ended updates CallKit — connectedAt on connect, the mapped CXCallEndedReason on end")
    func reports() async throws {
        let (m, sys, _, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio()
        m.transportDidConnect(call: id)
        #expect(m.state == .connected)
        #expect(sys.reported.last == .outgoingConnected(id))
        m.transportDidEnd(call: id, .agentEnded)
        #expect(sys.reported.last == .ended(id, .remoteEnded))
        #expect(m.state == .idle)

        for (reason, expected) in [(EndReason.connectionLost, CallEndedReason.failed), (.credentialVendingFailed, .failed),
                                   (.systemEnded, .unanswered), (.agentEnded, .remoteEnded)] {
            let (m2, sys2, _, _) = make()
            let id2 = try await m2.startCall()
            _ = await sys2.performStart(id2)
            m2.transportDidEnd(call: id2, reason)
            #expect(sys2.reported.last == .ended(id2, expected), "\(reason)")
        }
        // Our own end: CallKit already knows (it performed the action); no duplicate report.
        let (m3, sys3, _, _) = make()
        let id3 = try await m3.startCall(); _ = await sys3.performStart(id3)
        _ = await sys3.performEnd(id3)
        m3.transportDidEnd(call: id3, .customerEnded)
        #expect(!sys3.reported.contains { if case .ended = $0 { true } else { false } })
    }

    @Test("K6: a missing `audio` background mode is reported loudly at init (asynchronously, so an onError set right after init hears it); present is silent")
    func backgroundMode() async {
        let (m, _, _, errors) = make(backgroundModes: [])
        #expect(await eventuallyOnMain { errors.value.count == 1 })
        _ = m   // the report is delivered to a *living* manager's observer
        guard case .invalidConfiguration(let msg)? = errors.value.first else { Issue.record("expected invalidConfiguration"); return }
        #expect(msg.contains("audio"))
        let (m2, _, _, ok) = make(backgroundModes: ["audio"])
        await Task.yield()
        #expect(ok.value.isEmpty)
        _ = m2
    }

    @Test("K7b: an interruption before the transport connects resumes to .connecting, and the later connect still reaches CallKit")
    func interruptionBeforeConnect() async throws {
        let (m, sys, _, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio()          // media joining
        await sys.deactivateAudio()
        #expect(m.state == .interrupted)
        await sys.activateAudio()
        #expect(m.state == .connecting, "reactivation does not invent a connection")
        m.transportDidConnect(call: id)
        #expect(m.state == .connected)
        #expect(sys.reported.last == .outgoingConnected(id), "CallKit hears the connect, so the call timer starts")
    }

    @Test("K7c: a connect that arrives during an interruption is recorded but the state stays interrupted until the session returns")
    func connectWhileInterrupted() async throws {
        let (m, sys, _, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio(); await sys.deactivateAudio()
        m.transportDidConnect(call: id)
        #expect(m.state == .interrupted)
        #expect(sys.reported.last == .outgoingConnected(id))
        await sys.activateAudio()
        #expect(m.state == .connected)
    }

    @Test("K11: transport events are tagged with their call — a previous call's late end cannot kill the next one")
    func staleTransportEvents() async throws {
        let (m, sys, _, _) = make()
        let first = try await m.startCall()
        _ = await sys.performStart(first); _ = await sys.performEnd(first)          // user hung up via the system UI
        let second = try await m.startCall()
        m.transportDidEnd(call: first, .customerEnded)                              // the first call's session catches up
        #expect(m.state == .requesting)
        #expect(m.callID == second)
        #expect(!sys.reported.contains { if case .ended(second, _) = $0 { true } else { false } })
        m.transportDidConnect(call: first)
        #expect(m.state == .requesting)
    }

    @Test("K12: a customer end that bypassed CallKit (host called session.end()) is routed through CXEndCallAction, never reported as failed")
    func customerEndGoesThroughCallKit() async throws {
        let (m, sys, acts, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio(); m.transportDidConnect(call: id)
        m.transportDidEnd(call: id, .customerEnded)
        #expect(await eventuallyOnMain { sys.requested.contains(.end(id)) })
        #expect(!sys.reported.contains { if case .ended(id, .failed) = $0 { true } else { false } })
        _ = await sys.performEnd(id)
        #expect(m.state == .idle)
        #expect(acts.log.last == "endCall")
    }

    @Test("K13: configureAudioSession throwing fails the start action, reports, goes idle, and startCall throws rather than returning a dead call")
    func configureFails() async throws {
        let (m, sys, acts, errors) = make()
        acts.configureError = NSError(domain: "av", code: 560030580)
        sys.performStartDuringRequest = true
        await #expect(throws: TouchpointError.self) { _ = try await m.startCall() }
        #expect(m.state == .idle)
        #expect(errors.value.count == 1)
        #expect(acts.log == ["configureAudio"])
    }

    @Test("K14: an end request CallKit refuses (phantom call after a timeout) still ends media and frees the manager")
    func endRequestRefusedRecovers() async throws {
        let (m, sys, acts, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio()
        sys.requestError = NSError(domain: "cx", code: 2)
        await #expect(throws: TouchpointError.self) { try await m.endCall() }
        #expect(acts.log.last == "endCall")
        #expect(m.state == .idle)
        sys.requestError = nil
        _ = try await m.startCall()                                                   // not stuck
    }

    @Test("K15: a CallKit action timeout ends the call locally and reports")
    func actionTimeout() async throws {
        let (m, sys, acts, errors) = make()
        let id = try await m.startCall()
        await sys.timeout(id)
        #expect(m.state == .idle)
        #expect(acts.log.last == "endCall")
        #expect(errors.value.count == 1)
    }

    @Test("K16: an empty display name is refused — it is what the system call UI shows")
    func emptyDisplayName() async {
        let sys = FakeCallSystem(); let acts = FakeCallActions()
        let m = TouchpointCallManager(provider: sys, controller: sys, actions: acts.actions, backgroundModes: ["audio"], displayName: "")
        await #expect(throws: TouchpointError.self) { _ = try await m.startCall() }
    }

    @Test("K7: audio session deactivation mid-call marks the call interrupted; reactivation clears it without restarting media")
    func deactivation() async throws {
        let (m, sys, acts, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio(); m.transportDidConnect(call: id)
        await sys.deactivateAudio()
        #expect(m.state == .interrupted)
        await sys.activateAudio()
        #expect(m.state == .connected)
        #expect(acts.log.filter { $0 == "startMedia" }.count == 1)
    }

    @Test("K8: a second startCall while one exists throws; a failed CXStartCallAction request leaves the manager idle")
    func singleCall() async throws {
        let (m, sys, _, _) = make()
        _ = try await m.startCall()
        await #expect(throws: TouchpointError.self) { _ = try await m.startCall() }
        let (m2, sys2, _, _) = make()
        sys2.requestError = NSError(domain: "cx", code: 1)
        await #expect(throws: TouchpointError.self) { _ = try await m2.startCall() }
        #expect(m2.state == .idle)
        _ = sys
    }

    @Test("K9: providerDidReset ends any live call through the transport and goes idle")
    func reset() async throws {
        let (m, sys, acts, _) = make()
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio()
        await sys.reset()
        #expect(acts.log.last == "endCall")
        #expect(m.state == .idle)
    }

    @Test("K9b: providerDidReset during .requesting ends cleanly")
    func resetWhileRequesting() async throws {
        let (m, sys, acts, _) = make()
        _ = try await m.startCall()
        await sys.reset()
        #expect(m.state == .idle)
        #expect(acts.log == ["endCall"])
        _ = try await m.startCall()
    }

    @Test("K10: state changes are announced to the observer in order")
    func stateChanges() async throws {
        let (m, sys, _, _) = make()
        let seen = Capture<[CallState]>([])
        m.onStateChange = { seen.value.append($0) }
        let id = try await m.startCall()
        _ = await sys.performStart(id); await sys.activateAudio(); m.transportDidConnect(call: id); m.transportDidEnd(call: id, .agentEnded)
        #expect(seen.value == [.requesting, .connecting, .connected, .idle])
    }
}

@MainActor
final class Capture<Value> {
    var value: Value
    init(_ v: Value) { value = v }
}
