import SwiftUI

struct IdentitySection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: OverviewViewModel

    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                HStack {
                    SectionHeader(
                        "Identity",
                        icon: "person.circle.fill",
                        color: PRTheme.info,
                        subtitle: "Anonymous, login ve logout akışları"
                    )
                    Spacer()
                    StatusBadge(
                        text: appState.isAnonymous ? "Anonymous" : "Identified",
                        color: appState.isAnonymous ? .orange : PRTheme.success
                    )
                }

                userIdDisplay

                loginRow

                PRActionButton(
                    "Logout",
                    icon: "rectangle.portrait.and.arrow.right",
                    color: PRTheme.error,
                    action: vm.logout
                )
            }
        }
    }

    // MARK: - Subviews

    private var userIdDisplay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("App User ID")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            HStack {
                Text(appState.currentAppUserId)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if appState.currentAppUserId != "-" {
                    Button {
                        UIPasteboard.general.string = appState.currentAppUserId
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(PRTheme.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var loginRow: some View {
        HStack(spacing: 8) {
            PRTextField(placeholder: "New User ID", text: $vm.newAppUserId)

            Button(action: vm.login) {
                Text("Login")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(PRTheme.success.opacity(0.12))
                    .foregroundStyle(PRTheme.success)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
