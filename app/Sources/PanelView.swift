import AppKit
import SwiftUI

/// The menu-bar panel, laid out like macOS's own menu extras (Wi-Fi, Bluetooth):
/// a title, a section of rows, separators, then plain text actions.
struct PanelView: View {
    @ObservedObject var store: AccountStore
    @State private var keyboardIndex: Int?
    @State private var addingAccount = false
    @State private var newAccountLabel = ""
    @State private var copied = false
    @State private var showMore = false
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Field { case panel, addAccount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.showSetup ? "Set Up Claude Orbit" : "Claude Orbit")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
            PanelDivider()

            if store.showSetup {
                SetupView(store: store, addControl: { AnyView(addAccountControl(prominent: $0)) }).transition(.opacity)
            } else {
                accounts.transition(.opacity)
            }

            if let err = store.errors[""] {
                ErrorLine(text: err)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            PanelDivider()
            footer
        }
        .padding(8)
        .frame(width: 330)
        .background(WindowAccessor())
        .onHover { PanelCloser.shared.hovering = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .panel)
        .onAppear {
            focus = .panel
            keyboardIndex = nil
            // testing aids, like CLAUDE_ACCOUNTS_DEMO_RENAME
            let env = ProcessInfo.processInfo.environment
            if env["CLAUDE_ACCOUNTS_DEMO_ADD"] != nil { addingAccount = true; showMore = true }
            if env["CLAUDE_ACCOUNTS_DEMO_MORE"] != nil { showMore = true }
            store.checkForUpdates(manual: false)
            Task { await store.refresh(checkReady: true); await store.checkConductor() }
        }
        // Panel shortcuts apply only when no text field is being edited (rename / add account),
        // otherwise Return would never reach the field.
        .onKeyPress(.downArrow) { guard focus == .panel else { return .ignored }; moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { guard focus == .panel else { return .ignored }; moveSelection(-1); return .handled }
        .onKeyPress(.return) {
            guard focus == .panel, let i = keyboardIndex, store.accounts.indices.contains(i) else { return .ignored }
            store.switchTo(store.accounts[i].id)
            return .handled
        }
        .onKeyPress(.escape) { guard focus == .panel else { return .ignored }; PanelCloser.shared.closeNow(); return .handled }
        .background(shortcuts)
        .animation(reduceMotion ? Motion.fade : Motion.highlight, value: store.showSetup)
    }

    // MARK: accounts

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Accounts")
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, account in
                AccountCard(store: store, account: account, index: i, keyboardSelected: keyboardIndex == i)
                if store.lastSwitch?.id == account.id && store.active == account.id {
                    switchedNote(for: account)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            PanelDivider()
            Button { store.next() } label: {
                MenuRowLabel(title: nextAccount.map { "Switch to \($0.label)" } ?? "Switch to Next Account", shortcut: "⌘N")
            }
            .buttonStyle(MenuRowStyle())
            .disabled(nextAccount == nil || store.busyId != nil)

            if store.conductorPending > 0, let active = store.activeAccount {
                Button { store.moveConductorChats() } label: {
                    MenuRowLabel(title: "Move \(store.conductorPending) Conductor Chat\(store.conductorPending == 1 ? "" : "s") to \(active.label)")
                }
                .buttonStyle(MenuRowStyle())
                .transition(.opacity)
            }
            if let note = store.conductorNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.highlight, value: store.lastSwitch?.id)
        .animation(Motion.fade, value: store.conductorPending)
    }

    /// After a switch: one quiet line telling how to resume, with a copy button.
    private func switchedNote(for a: Account) -> some View {
        HStack(spacing: 6) {
            Text("Resume with")
                .foregroundStyle(.secondary)
            Text("claude --continue")
                .font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude --continue", forType: .string)
                withAnimation(Motion.fade) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(Motion.fade) { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .font(.system(size: 11))
        .padding(.leading, 54)
        .padding(.trailing, 12)
        .padding(.top, 0)
        .padding(.bottom, 6)
        .help("Long session? Run /compact right after resuming to save usage.")
    }

    private var nextAccount: Account? {
        guard !store.accounts.isEmpty else { return nil }
        let ids = store.accounts.map(\.id)
        let start = ids.firstIndex(of: store.active ?? "") ?? -1
        for step in 1...ids.count {
            let c = store.accounts[(start + step) % ids.count]
            if c.id != store.active && c.ready { return c }
        }
        return nil
    }

    // MARK: footer

    /// The panel is for switching, so everything else sits behind "More".
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.update == .available || store.update == .installing { updateBanner.transition(.opacity) }
            Button { withAnimation(Motion.fade) { showMore.toggle() } } label: {
                HStack {
                    Text("More").font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
            }
            .buttonStyle(MenuRowStyle())
            if showMore {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.showSetup { addAccountControl(prominent: false) }   // setup has its own
                    updateRow
                    if case .blocked(let why) = store.update {
                        Text(why)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                    Button { NSApp.terminate(nil) } label: {
                        MenuRowLabel(title: "Quit Claude Orbit", shortcut: "⌘Q")
                    }
                    .buttonStyle(MenuRowStyle())
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: addingAccount)
        .animation(Motion.fade, value: store.update)
    }

    /// Shown without opening "More" when a newer version is on GitHub.
    private var updateBanner: some View {
        Button { store.installUpdate() } label: {
            HStack(spacing: 8) {
                if store.update == .installing {
                    ProgressView().controlSize(.small)
                    Text("Updating. The app restarts in a moment.").font(.system(size: 13))
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(inUseInk, inUseColor)
                        .font(.system(size: 15))
                    Text("Update Available").font(.system(size: 13))
                    Spacer()
                    Text("Install").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(store.update == .installing)
    }

    private var updateRow: some View {
        let title: String
        switch store.update {
        case .checking: title = "Checking for Updates…"
        case .upToDate: title = "You’re Up to Date"
        case .available: title = "Install Update…"
        case .installing: title = "Updating…"
        case .idle, .blocked: title = "Check for Updates…"
        }
        return Button {
            if store.update == .available { store.installUpdate() } else { store.checkForUpdates(manual: true) }
        } label: {
            MenuRowLabel(title: title)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(store.update == .checking || store.update == .installing || store.update == .upToDate)
    }

    /// "Add Account…", which turns into a name field in place. Setup shows it as a real button.
    @ViewBuilder private func addAccountControl(prominent: Bool) -> some View {
        if addingAccount {
            HStack(spacing: 6) {
                TextField("Account name, like Work", text: $newAccountLabel)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focus, equals: .addAccount)
                    .onSubmit(submitAdd)
                    .onExitCommand { addingAccount = false }
                Button("Cancel") { addingAccount = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Add", action: submitAdd)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newAccountLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .transition(.opacity)
        } else if prominent {
            Button("Add Account…", action: startAdding)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        } else {
            Button(action: startAdding) { MenuRowLabel(title: "Add Account…") }
                .buttonStyle(MenuRowStyle())
        }
    }

    private func startAdding() {
        addingAccount = true
        DispatchQueue.main.async { focus = .addAccount }
    }

    private func submitAdd() {
        store.add(label: newAccountLabel)
        newAccountLabel = ""
        addingAccount = false
    }

    // Invisible buttons carrying ⌘1…⌘9 and ⌘N.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.id) { i, a in
                Button("") { store.switchTo(a.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { store.next() }.keyboardShortcut("n", modifiers: .command)
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)   // Quit lives under "More"
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func moveSelection(_ delta: Int) {
        guard !store.accounts.isEmpty else { return }
        let current = keyboardIndex ?? store.accounts.firstIndex { $0.id == store.active } ?? 0
        keyboardIndex = (current + delta + store.accounts.count) % store.accounts.count
    }
}

/// Hands the hosting window to PanelCloser so the panel can close itself after a switch.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { PanelCloser.shared.window = v.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { PanelCloser.shared.window = w } }
    }
}
