import SwiftUI

/// One account, styled like a network row in the Wi-Fi menu: neutral avatar, lime when in use.
/// Right-click (or the context menu) offers Rename, Log In Again and Remove.
struct AccountCard: View {
    @ObservedObject var store: AccountStore
    let account: Account
    let index: Int
    var keyboardSelected = false
    var setupMode = false

    @State private var newLabel = ""
    @State private var confirmingRemove = false
    @FocusState private var renameFocused: Bool

    private var isActive: Bool { store.active == account.id }
    private var isBusy: Bool { store.busyId == account.id }
    private var isLoggingIn: Bool { store.loggingIn.contains(account.id) }
    private var renaming: Bool { store.renamingId == account.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if renaming {
                renameRow   // a real, editable field: kept outside the row's button
            } else {
                Button { if !setupMode && account.ready { store.switchTo(account.id) } } label: { row }
                    .buttonStyle(MenuRowStyle(highlighted: keyboardSelected))
                    .disabled(confirmingRemove)
                    .contextMenu { menuItems }
            }
            if confirmingRemove { removeConfirm.transition(.opacity) }
            if let err = store.errors[account.id] {
                ErrorLine(text: err)
                    .padding(.leading, 54)
                    .padding(.trailing, 12)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .onAppear {   // testing aid, like CLAUDE_ACCOUNTS_DEMO_RENAME: open on the remove confirmation
            if ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_REMOVE"] == account.id { confirmingRemove = true }
        }
        .animation(Motion.fade, value: confirmingRemove)
        .animation(Motion.fade, value: renaming)
        .animation(Motion.fade, value: store.errors[account.id])
    }

    private var row: some View {
        HStack(spacing: 12) {
            Avatar(label: account.label, active: isActive)
                .animation(Motion.highlight, value: isActive)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label).font(.system(size: 13)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var renameRow: some View {
        HStack(spacing: 12) {
            Avatar(label: newLabel.isEmpty ? account.label : newLabel, active: isActive)
            TextField("Account name", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($renameFocused)
                .onSubmit(commitRename)
                .onExitCommand(perform: cancelRename)
            Button("Cancel", action: cancelRename)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Save", action: commitRename)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            newLabel = account.label
            DispatchQueue.main.async { renameFocused = true }
        }
        .transition(.opacity)
    }

    private func commitRename() {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != account.label { store.rename(account.id, to: trimmed) }
        withAnimation(Motion.fade) { store.renamingId = nil }
    }

    private func cancelRename() {
        withAnimation(Motion.fade) { store.renamingId = nil }   // nothing saved
    }

    private var subtitle: String {
        if isLoggingIn { return "Waiting for browser sign-in…" }
        return account.email ?? (account.ready ? "Signed in" : "Not signed in")
    }

    @ViewBuilder private var trailing: some View {
        if isLoggingIn {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { store.cancelLogin(account.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .transition(.opacity)
        } else if isBusy {
            ProgressView().controlSize(.small)
        } else if !account.ready {
            Button("Log In…") { store.login(account.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if isActive {
            InUseBadge().transition(.opacity)
        } else if setupMode {
            Text("Signed in")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else if index < 9 {
            Text("⌘\(index + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Rename…") {
            withAnimation(Motion.fade) { store.renamingId = account.id }
        }
        Button(account.ready ? "Log In Again…" : "Log In…") { store.login(account.id) }
            .disabled(isLoggingIn)
        Divider()
        Button("Remove…", role: .destructive) { confirmingRemove = true }
    }

    private var removeConfirm: some View {
        // Message on its own line, buttons underneath: side by side, the message was cut off after "It will…".
        VStack(alignment: .trailing, spacing: 6) {
            Text("Remove “\(account.label)”? It will be signed out.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Cancel") { confirmingRemove = false }
                    .controlSize(.small)
                Button("Remove", role: .destructive) { confirmingRemove = false; store.remove(account.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(dangerColor)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }
}
