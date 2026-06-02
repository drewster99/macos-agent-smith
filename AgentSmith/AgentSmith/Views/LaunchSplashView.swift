import SwiftUI

/// Brief launch splash that displays the app logo with a fade-in / fade-out
/// animation. Calls `onFinished` when its dismiss animation completes so the
/// host can remove it from the view tree.
struct LaunchSplashView: View {
    let onFinished: () -> Void

    @State private var phase: Phase = .preEntry

    private enum Phase {
        case preEntry
        case visible
        case fadingOut
    }

    private let entryDuration: Double = 0.45
    private let holdDuration: Double = 1.2
    private let exitDuration: Double = 0.55

    var body: some View {
        ZStack {
            AppColors.splashBackground
                .ignoresSafeArea()
                .opacity(phase == .fadingOut ? 0 : 1)

            Image("AppLaunchLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .stroke(AppColors.splashLogoStroke, lineWidth: 1)
                )
                .shadow(color: AppColors.splashLogoGlow, radius: 28, x: 0, y: 0)
                .shadow(color: AppColors.splashLogoShadow, radius: 18, x: 0, y: 12)
                .scaleEffect(phase == .preEntry ? 0.88 : (phase == .fadingOut ? 1.04 : 1.0))
                .opacity(phase == .visible ? 1 : 0)
        }
        .allowsHitTesting(false)
        .task {
            LaunchChime.shared.playOnce()
            withAnimation(.easeOut(duration: entryDuration)) {
                phase = .visible
            }
            do {
                try await Task.sleep(nanoseconds: UInt64((entryDuration + holdDuration) * 1_000_000_000))
                withAnimation(.easeIn(duration: exitDuration)) {
                    phase = .fadingOut
                }
                try await Task.sleep(nanoseconds: UInt64(exitDuration * 1_000_000_000))
            } catch {
                // Task.sleep only throws on cancellation/teardown; in that case the
                // splash is being torn down, so don't fire the completion callback.
                return
            }
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}
