import Foundation
import UIKit

/// The agent works on the phone this app runs on, so the app must be out of the way: Start sends it to the
/// Home Screen (and checks that iOS really put it in the background), and a run holds while it is in front.
extension AppModel {

    var appIsBackgrounded: Bool { UIApplication.shared.applicationState == .background }

    /// Each fallback is a distinct gesture; never treat the board's ACK as a successful departure.
    func leaveApp() async throws -> Bool {
        try await AppDeparture(isBackground: { self.appIsBackgrounded },
                               isConnected: { self.board.connected }, attempt: { method in
            switch method {
            case .homeKey: _ = try await self.board.commands.send("homescreen", timeout: 3)
            case .shortcut: _ = try await self.board.commands.send("key cmd+h", timeout: 3)
            case .swipe: try await self.pointer.homeSwipe()
            }
        }, waitForBackground: { try await self.waitForBackground($0, stopOnBoardLoss: true) },
           waitForConnection: {
            if self.startingAgent { try await self.waitForStartupBoard() }
            else { _ = try await self.agent.waitForScreen() }
        }, failed: { method, error in
            DebugLog.write("leave app: \(method.rawValue) failed: \(error.localizedDescription)")
            if error is BoardTimeout || !self.board.connected {
                self.startupBoardUnavailable(disconnected: !self.board.connected)
            }
        }, log: DebugLog.write).leave()
    }

    /// Keep the manual instruction visible; a normal disconnect pauses this wait and retries departure.
    func askUserToLeave() async throws -> Bool {
        var remaining = 30.0
        defer { homeHint = nil }
        while remaining > 0 {
            homeHint = startupBoardIssue
                ? String(localized: "The board isn't responding. Move it closer to your iPhone, or swipe up to continue.")
                : String(localized: "Swipe up to go to the Home Screen, and I'll start.")
            let began = now()
            if try await waitForBackground(remaining, stopOnBoardLoss: true) { return true }
            remaining -= now() - began
            guard !board.connected else { return false }
            try await waitForStartupBoard()
            if try await leaveApp() { return true }
        }
        return false
    }

    /// A startup has no AgentLoop recovery yet, so report a failed link immediately here.
    func startupBoardUnavailable(disconnected: Bool) {
        guard startingAgent, !agent.running, !MockMode.on else { return }
        startupBoardIssue = true
        let status: IslandStatus = disconnected ? .waitingForBoard : .boardSlow
        homeHint = status.full
        live.show(status, mood: .listening)
        if disconnected { recover(.init(part: .board, ask: false)) }
    }

    /// Pause a startup on normal BLE loss, then restore streaming and continue in the same task.
    func waitForStartupBoard() async throws {
        let began = now()
        var waited = false
        while true {
            while !board.connected {
                try Task.checkCancellation()
                guard now() < startupDeadline else { throw DeviceError(message: Recovery.reason(.board)) }
                waited = true
                let stage = Recovery.Stage(part: .board, ask: now() - began >= Recovery.quiet[.board]!)
                if stage != recovering { recover(stage) }
                homeHint = stage.line
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            try Task.checkCancellation()
            if waited && FrameMode.current == .stream {
                do { try await feed.stream(true) }
                catch {
                    try Task.checkCancellation()
                    if !board.connected { continue }
                    throw error
                }
            }
            if waited {
                recover(nil)
                startupBoardIssue = false
                homeHint = nil
                live.show(.leavingApp, mood: .acting)
            }
            return
        }
    }

    func startupBoardCommand(_ operation: () async throws -> Void) async throws {
        while true {
            try await waitForStartupBoard()
            do { try await operation(); return }
            catch {
                try Task.checkCancellation()
                guard !board.connected else { throw error }
                startupBoardUnavailable(disconnected: true)
            }
        }
    }

    /// Try a short stream wait, then explicitly snap; a static Home Screen must not stall startup.
    func waitForStartupFrame(boundary: StartupFrameBoundary, snapMode: Bool) async throws -> String {
        let began = now()
        var recovery = Recovery(at: began, limit: max(0, startupDeadline - began))
        let streamDeadline = snapMode ? began : began + 3
        var requestedMotion = false
        var receivedSnapshot = false
        var source = "live"
        func hasFrame() -> Bool {
            feed.frame != nil && !feed.broken
                && boundary.accepts(capturedAt: feed.capturedAt, backgroundEnteredAt: backgroundEnteredAt)
        }
        while true {
            guard now() < startupDeadline else { throw DeviceError(message: Recovery.reason(.frames)) }
            try Task.checkCancellation()
            guard appIsBackgrounded else {
                throw DeviceError(message: String(localized: "ESP32 Agent is still on screen"))
            }
            if hasFrame(), board.connected, !snapMode || receivedSnapshot {
                await feed.settled()
                try Task.checkCancellation()
                if hasFrame(), board.connected, appIsBackgrounded {
                    if recovering != nil { recover(nil) }
                    return source
                }
            }
            let link = Recovery.Link(connected: board.connected, sta: board.status?.sta, ap: board.status?.ap,
                                     frameAt: hasFrame() ? now() : 0)
            switch recovery.next(link, at: now()) {
            case .live: break
            case .wait(let stage):
                if stage != recovering { recover(stage) }
                homeHint = stage.line
            case .giveUp(let reason): throw DeviceError(message: reason)
            }
            if !board.connected { try await waitForStartupBoard(); continue }
            if now() < streamDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            do {
                if !requestedMotion {
                    // A static Home frame may predate its notification. Move only the cursor to request
                    // a genuinely newer image; no tap, model call, or timestamp tolerance is involved.
                    try await pointer.point(0.5, 0.5, aim: false)
                    try Task.checkCancellation()
                    guard appIsBackgrounded else {
                        throw DeviceError(message: String(localized: "ESP32 Agent is still on screen"))
                    }
                    try await pointer.point(0.55, 0.5, aim: false)
                    requestedMotion = true
                }
                try Task.checkCancellation()
                let remaining = max(0.1, startupDeadline - now())
                try await feed.snap(timeout: min(feed.snapTimeout, remaining))
                receivedSnapshot = true
                source = "snap"
            } catch {
                try Task.checkCancellation()
                guard appIsBackgrounded else { throw error }
                DebugLog.write("startup frame: " + error.localizedDescription)
                if !board.connected { startupBoardUnavailable(disconnected: true) }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Before each look and gesture of a run. If the agent itself brought the app to the front (it tapped our
    /// Live Activity, a notification or an intent), or Continue was just tapped here, send the app away at once;
    /// if the user opened it, wait until they leave. The model never sees or taps this app's own screens.
    func holdWhileInFront() async throws {
        guard !appIsBackgrounded, agent.running, !MockMode.on else { return }
        let ours = now() - agent.lastActed < 3 || now() - resumeAsked < 5
        DebugLog.write("run: ESP32 Agent is in front (\(ours ? "after an agent action" : "opened by the user")); holding")
        let since = now()
        var away = false
        if ours { away = try await leaveApp() }
        if !away {
            homeHint = String(localized: "Paused while you're here. Go to the Home Screen and I'll go on.")
            live.show(.pausedInApp, mood: .thinking)
            defer { homeHint = nil }
            while !appIsBackgrounded {
                try Task.checkCancellation()
                if !feed.live {
                    _ = try await agent.waitForScreen()
                    live.show(.pausedInApp, mood: .thinking)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        _ = await feed.fresh(since: since, timeout: 3)  // a frame of the screen that is in front now
        await feed.settled()
        DebugLog.write("run: app in background again, going on")
    }

    private func waitForBackground(_ seconds: Double, stopOnBoardLoss: Bool = false) async throws -> Bool {
        let deadline = now() + seconds
        while !appIsBackgrounded {
            try Task.checkCancellation()
            if stopOnBoardLoss && !board.connected { return false }
            if now() > deadline { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        return true
    }
}
