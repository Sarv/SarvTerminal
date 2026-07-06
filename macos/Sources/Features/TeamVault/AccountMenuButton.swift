import SwiftUI
import AppKit

/// Account button on the trailing edge of the Vaults top bar (after the gear).
/// Logged out it opens a sign-in popover ("Login with Sarv" + manual token);
/// logged in it shows the account + team/account switcher. Sized to match the
/// gear/bell (28×24, white glyph).
struct AccountMenuButton: View {
    @ObservedObject private var store = VaultStore.shared
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: store.isAuthenticated ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 14, weight: .regular))
                // Adapts to the chrome appearance — hardcoded .white vanishes
                // on a light window.
                .foregroundStyle(.secondaryText)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .hoverTip(store.activeEmail.map { "Signed in: \($0)" } ?? "Sign in to Team Vaults")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            if store.isAuthenticated {
                signedInPanel
            } else {
                signInPanel
            }
        }
    }

    // MARK: Signed out

    @State private var email = "vault-owner@sarv.com"
    @State private var manualToken = ""

    private var signInPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sign in to Sarv Vault", systemImage: "lock.shield").font(.headline)

            Button {
                NSWorkspace.shared.open(VaultConfig.loginURL)
            } label: {
                HStack { Image(systemName: "globe"); Text("Login") }
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("Opens the Sarv login in your browser. After signing in, paste the auth token below (automatic sign-in coming soon).")
                .font(.caption).foregroundStyle(.secondaryText)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Paste auth token").font(.caption.weight(.semibold))
                HStack {
                    TextField("token…", text: $manualToken)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.loginWithToken(manualToken) }
                    Button("Submit") { store.loginWithToken(manualToken) }
                        .disabled(store.isBusy || manualToken.isEmpty)
                }
            }

            if VaultConfig.devLoginEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dev sign-in (local)").font(.caption.weight(.semibold)).foregroundStyle(.secondaryText)
                    HStack {
                        TextField("email", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.login(email: email) }
                        Button("Go") { store.login(email: email) }.disabled(store.isBusy)
                    }
                }
            }

            if store.isBusy { ProgressView().controlSize(.small) }
            if let err = store.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onChange(of: store.isAuthenticated) { authed in if authed { showPopover = false } }
    }

    // MARK: Signed in

    private var signedInPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signed in").font(.headline)
                    Text(store.activeEmail ?? "").font(.caption).foregroundStyle(.secondaryText)
                }
            }

            Button {
                openTeams(); showPopover = false
            } label: {
                HStack { Image(systemName: "person.2"); Text("Open Team Vaults") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if store.accounts.count > 1 {
                Divider()
                Text("Switch account").font(.caption.weight(.semibold)).foregroundStyle(.secondaryText)
                ForEach(store.accounts) { acct in
                    Button {
                        if acct.id != store.activeAccountID { store.switchAccount(acct.id) }
                        showPopover = false
                    } label: {
                        HStack {
                            Image(systemName: acct.id == store.activeAccountID ? "largecircle.fill.circle" : "circle")
                            Text(acct.email); Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            HStack {
                Button("Add account…") { store.showingAddAccount = true; openTeams(); showPopover = false }
                Spacer()
                if let active = store.activeAccount {
                    Button("Sign out", role: .destructive) { store.signOut(active.id) }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func openTeams() {
        VaultsTabsModel.shared.selectDashboard(section: .vaults)
        HostManagerSelection.shared.vaultsSection = .teams
    }
}
