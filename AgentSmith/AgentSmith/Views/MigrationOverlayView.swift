import SwiftUI

/// Blocking overlay shown during the one-time embedding re-embed migration, when it's large enough
/// to take a noticeable amount of time. Driven by `SharedAppState.migrationInProgress`.
struct MigrationOverlayView: View {
    let entryCount: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Updating semantic index…")
                    .font(.headline)
                Text("Re-embedding \(entryCount) item\(entryCount == 1 ? "" : "s") with the new embedding model. This happens once and may take a minute.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
    }
}

extension View {
    /// Overlays the migration progress indicator while `shared.migrationInProgress` is set. The
    /// modifier reads the `@Observable` flag in its `body` so SwiftUI tracks and re-renders on change.
    func migrationOverlay(_ shared: SharedAppState) -> some View {
        modifier(MigrationOverlayModifier(shared: shared))
    }
}

private struct MigrationOverlayModifier: ViewModifier {
    let shared: SharedAppState

    func body(content: Content) -> some View {
        content.overlay {
            if shared.migrationInProgress {
                MigrationOverlayView(entryCount: shared.migrationEntryCount)
            }
        }
    }
}
