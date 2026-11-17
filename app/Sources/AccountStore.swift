import AppKit
import Foundation
import SwiftUI

enum UpdateState: Equatable {
    case idle               // nothing to say (not checked yet, or an automatic check found nothing)
    case checking
    case upToDate
    case available
    case blocked(String)    // this copy can't update itself; the text says why
    case installing
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var accounts: [Account] = []
    @Published var importable: [Importable] = []
    @Published var forceSetup = false
    @Published var active: String?
    @Published var busyId: String?            // account currently being switched to
    @Published var loggingIn: Set<String> = []  // accounts waiting for the browser sign-in
    @Published var renamingId: String?          // the one account being renamed, if any
    private var logins: [String: RunningCommand] = [:]
    @Published var errors: [String: String] = [:]   // account id -> inline error ("" key = panel-wide)
    @Published var lastSwitch: Account?
    @Published var conductorPending = 0
    @Published var conductorNote: String?
    @Published var setupComplete: Bool
    @Published var update: UpdateState = .idle
    private var lastUpdateCheck = Date.distantPast

    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1

    private init() {
        setupComplete = FileManager.default.fileExists(atPath: Self.setupMarker.path)
        Task {
            _ = try? await CLIClient.run(["apply-env"])   // after a reboot, GUI apps learn the active account
            await refresh(checkReady: true)
            checkForUpdates(manual: false)
        }
        startWatching()
    }

    static var setupMarker: URL { CLIClient.accountsHome.appendingPathComponent(".setup-complete") }

    var activeAccount: Account? { accounts.first { $0.id == active } }
    var showSetup: Bool { forceSetup || !setupComplete }
    var anyReady: Bool { accounts.contains(where: \.ready) }

    // MARK: loading

    func refresh(checkReady: Bool = false) async {
        do {
            // `setup` is idempotent and also reports accounts importable from ClaudeSwitcher.
            apply(try await CLIClient.decode(Listing.self, [showSetup || checkReady ? "setup" : "list"]))
            if checkReady {
                for a in accounts {
                    if let s = try? await CLIClient.decode(StatusResult.self, ["status", a.id]) {
                        update(a.id) { $0.ready = s.ready; if let e = s.email { $0.email = e } }
                    }
                }
            }
            errors[""] = nil
        } catch let e as CLIError {
            errors[""] = e.error
        } catch {
            errors[""] = "Couldn't run claude-switch. Is it installed?"
        }
    }

    private func apply(_ l: Listing) {
        accounts = l.accounts
        if let imp = l.importable { importable = imp }
        if active != l.active {
            withAnimation(Motion.highlight) { active = l.active }
        }
    }

    private func update(_ id: String, _ change: (inout Account) -> Void) {
        if let i = accounts.firstIndex(where: { $0.id == id }) { change(&accounts[i]) }
    }

    // MARK: actions

    func switchTo(_ id: String) {
        guard id != active, busyId == nil, let target = accounts.first(where: { $0.id == id }) else { return }
        if !target.ready { errors[id] = "Log in first."; return }
        let previous = active
        withAnimation(Motion.highlight) { active = id }   // respond instantly; the CLI confirms
        busyId = id
        errors[id] = nil
        Task {
            defer { busyId = nil }
            do {
                _ = try await CLIClient.decode(SwitchResult.self, ["switch", id])
                withAnimation(Motion.fade) { lastSwitch = target }
                await checkConductor()
                PanelCloser.shared.scheduleClose()
            } catch let e as CLIError {
                withAnimation(Motion.highlight) { active = previous }
                errors[id] = e.error
            } catch {
                withAnimation(Motion.highlight) { active = previous }
                errors[id] = error.localizedDescription
            }
        }
    }

    func next() {
        guard !accounts.isEmpty else { return }
        let ids = accounts.map(\.id)
        let start = ids.firstIndex(of: active ?? "") ?? -1
        for step in 1...ids.count {
            let candidate = accounts[(start + step) % ids.count]
            if candidate.id != active && candidate.ready { switchTo(candidate.id); return }
        }
        errors[""] = "No other account is logged in yet."
    }

    /// Opens the browser sign-in. Nothing changes until the user approves there; Cancel, or
    /// closing the browser (3-minute limit), puts the row straight back to how it was.
    func login(_ id: String) {
        guard !loggingIn.contains(id) else { return }
        let cmd = CLIClient.start(["login", id])
        logins[id] = cmd
        withAnimation(Motion.fade) { _ = loggingIn.insert(id); errors[id] = nil }
        Task {
            defer {
                logins[id] = nil
                withAnimation(Motion.fade) { _ = loggingIn.remove(id) }
            }
            do {
                let s = try await cmd.decode(StatusResult.self)
                withAnimation(Motion.fade) {
                    update(id) { $0.ready = s.ready; if let e = s.email { $0.email = e } }
                }
                if !s.ready { flash(id, "Sign-in didn't finish. Nothing changed.") }
                if active == nil, s.ready { switchTo(id) }
            } catch let e as CLIError where e.code == "cancelled" {
                // user cancelled: back to normal, no message
            } catch let e as CLIError {
                flash(id, e.error, seconds: e.code == "wrong_account" ? 10 : 5)
            } catch {
                flash(id, error.localizedDescription)
            }
            await refresh()
        }
    }

    func cancelLogin(_ id: String) { logins[id]?.cancel() }

    /// Inline message that clears itself.
    private func flash(_ id: String, _ message: String, seconds: Double = 5) {
        withAnimation(Motion.fade) { errors[id] = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.errors[id] == message else { return }
            withAnimation(Motion.fade) { self.errors[id] = nil }
        }
    }

    func add(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                let l = try await CLIClient.decode(Listing.self, ["add", trimmed])
                withAnimation(Motion.fade) { apply(l) }
                if let new = l.accounts.last { login(new.id) }
            } catch let e as CLIError {
                errors[""] = e.error
            } catch {}
        }
    }

    func importAccount(_ item: Importable) {
        Task {
            do {
                let l = try await CLIClient.decode(Listing.self, ["import-claudeswitcher", item.email])
                withAnimation(Motion.fade) {
                    apply(l)
                    importable.removeAll { $0.email == item.email }
                }
                if let new = l.accounts.first(where: { $0.email?.lowercased() == item.email }) { login(new.id) }
            } catch let e as CLIError {
                errors[""] = e.error
            } catch {}
        }
    }

    func rename(_ id: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                apply(try await CLIClient.decode(Listing.self, ["rename", id, trimmed]))
            } catch let e as CLIError {
                errors[id] = e.error
            } catch {
                errors[id] = error.localizedDescription
            }
        }
    }

    func remove(_ id: String) {
        Task {
            do {
                let l = try await CLIClient.decode(Listing.self, ["remove", id, "--yes"])
                withAnimation(Motion.fade) { apply(l) }
            } catch let e as CLIError {
                errors[id] = e.error
            } catch {}
        }
    }

    func finishSetup() {
        FileManager.default.createFile(atPath: Self.setupMarker.path, contents: Data())
        withAnimation(Motion.fade) { setupComplete = true }
    }

    // MARK: updates

    /// Looks on GitHub for a newer version. Automatic checks (at launch and when the panel opens, at most
    /// every six hours) stay quiet unless there is one; a manual check always reports back.
    func checkForUpdates(manual: Bool) {
        guard update != .checking, update != .installing else { return }
        if !manual && Date().timeIntervalSince(lastUpdateCheck) < 6 * 3600 { return }
        lastUpdateCheck = Date()
        if manual { withAnimation(Motion.fade) { update = .checking } }
        Task {
            let info = try? await CLIClient.decode(UpdateInfo.self, ["update", "--check"])
            withAnimation(Motion.fade) {
                if let info, info.available, info.reason == nil {
                    update = .available
                } else if manual {
                    update = info.map { $0.reason == nil ? .upToDate : .blocked($0.message) } ?? .blocked("Couldn't check for updates.")
                } else if update == .available {
                    update = .idle
                }
            }
            if update == .upToDate {   // the confirmation fades back to the plain "Check for Updates…" row
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if update == .upToDate { withAnimation(Motion.fade) { update = .idle } }
            }
        }
    }

    /// Downloads the new version and re-runs the installer, which restarts this app.
    func installUpdate() {
        guard update != .installing else { return }
        withAnimation(Motion.fade) { update = .installing }
        Task {
            do {
                let r = try await CLIClient.decode(UpdateStart.self, ["update"])
                if !r.started { withAnimation(Motion.fade) { update = .upToDate } }
            } catch let e as CLIError {
                withAnimation(Motion.fade) { update = .blocked(e.error) }
            } catch {
                withAnimation(Motion.fade) { update = .blocked("Couldn't update.") }
            }
        }
    }

    // MARK: conductor

    func checkConductor() async {
        if let r = try? await CLIClient.decode(ConductorResult.self, ["conductor-move", "--dry-run"]) {
            withAnimation(Motion.fade) { conductorPending = r.pending; conductorNote = nil }
        }
    }

    func moveConductorChats() {
        let label = activeAccount?.label ?? "the new account"
        Task {
            do {
                let r = try await CLIClient.decode(ConductorResult.self, ["conductor-move"])
                var note = r.moved.isEmpty ? "" : "Moved \(r.moved.count) chat\(r.moved.count == 1 ? "" : "s"). Your next message continues on \(label)."
                if !r.skipped_busy.isEmpty {
                    note += (note.isEmpty ? "" : " ") + "\(r.skipped_busy.count) busy chat\(r.skipped_busy.count == 1 ? " is" : "s are") still working; move \(r.skipped_busy.count == 1 ? "it" : "them") when done."
                }
                withAnimation(Motion.fade) { conductorNote = note; conductorPending = r.skipped_busy.count }
            } catch let e as CLIError where e.code == "conductor_unsupported" {
                withAnimation(Motion.fade) { conductorNote = "Restart the chat in Conductor to continue on \(label)." }
            } catch {
                conductorNote = "Couldn't move Conductor chats."
            }
        }
    }

    // MARK: watching the CLI

    private func startWatching() {
        let dir = CLIClient.accountsHome
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watchFD = open(dir.path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watchFD, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
        src.setCancelHandler { [fd = watchFD] in close(fd) }
        src.resume()
        watcher = src
    }
}

/// Closes the menu-bar panel a moment after a switch, unless the pointer is inside it.
@MainActor
final class PanelCloser {
    static let shared = PanelCloser()
    weak var window: NSWindow?
    var hovering = false
    var enabled = true
    private var pending: DispatchWorkItem?

    func scheduleClose(after seconds: Double = 2.5) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            if self.hovering { self.scheduleClose(after: 1.0); return }
            self.window?.close()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func closeNow() { pending?.cancel(); if enabled { window?.close() } }
}
