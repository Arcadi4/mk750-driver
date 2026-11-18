import SwiftUI

/// The same read-only command is available in the toolbar, menu and offline views.
struct KeyboardConnectionButton: View {
  @ObservedObject var store: KeyboardStore

  var body: some View {
    let connected = store.connection == .connected
    Button {
      Task {
        if connected { await store.refresh() } else { await store.connect() }
      }
    } label: {
      Label(connected ? "Refresh" : "Connect", systemImage: connected ? "arrow.clockwise" : "cable.connector")
    }
    .disabled(store.isBusy)
    .help(connected ? "Read the current keyboard state (⌘R)" : "Find the MK750 over wired USB (⌘R)")
  }
}

struct KeyboardConnectionCard: View {
  @ObservedObject var store: KeyboardStore
  @State private var showDetails = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 14) {
          Image(systemName: "keyboard")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(store.connection == .connecting ? "Looking for your MK750…" : "Connect your MK750")
              .font(.headline)
            Text("Switch to wired mode and plug the keyboard into your Mac with a USB data cable.")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          if store.connection == .connecting {
            ProgressView().controlSize(.small)
          } else {
            KeyboardConnectionButton(store: store).buttonStyle(.borderedProminent)
          }
        }
        if let error = store.connectionError {
          DisclosureGroup("Connection details", isExpanded: $showDetails) {
            Text(error)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 4)
          }
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }
      .padding(8)
    }
  }
}
