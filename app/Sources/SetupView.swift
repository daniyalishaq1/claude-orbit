import SwiftUI

/// First run: import accounts found in ClaudeSwitcher, add others, sign each in once.
struct SetupView: View {
    @ObservedObject var store: AccountStore
    /// "Add Account…" from the panel; `true` asks for the prominent button used on the very first run.
    let addControl: (Bool) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in to each account once. After that, switching is instant and never asks for your password.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if !store.accounts.isEmpty {
                SectionHeader(title: "Accounts")
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, account in
                    AccountCard(store: store, account: account, index: i, setupMode: true)
                }
                addControl(false)
            }

            if !store.importable.isEmpty {
                SectionHeader(title: "Found in ClaudeSwitcher").padding(.top, 8)
                ForEach(store.importable) { item in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(.primary.opacity(0.14))
                            Image(systemName: "person.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 30, height: 30)
                        Text(item.email)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button("Import") { store.importAccount(item) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }
            }

            if store.accounts.isEmpty {
                // Very first run: say what will happen, then one obvious button.
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Add an account and give it a name, like “Work”.")
                    step(2, "Your browser opens. Sign in to that Claude account there.")
                    step(3, "Do the same for your other accounts, then press Done.")
                }
                .padding(.horizontal, 12)
                .padding(.top, store.importable.isEmpty ? 0 : 10)
                .padding(.bottom, 8)
                addControl(true)
            }

            if store.anyReady {
                // Finishing setup needs one signed-in account, so Done only appears once there is one.
                // Accounts not signed in yet keep their Log In… button in the normal menu.
                PanelDivider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Done") { store.finishSetup() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: store.importable)
        .animation(Motion.fade, value: store.accounts)
        .animation(Motion.fade, value: store.anyReady)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.primary.opacity(0.14)))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
