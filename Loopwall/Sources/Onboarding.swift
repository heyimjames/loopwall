import SwiftUI

/// Shared palette for the two onboarding moments below. Matches the app icon
/// (indigo plate, amber-to-rose screen) so the first thing a user sees is
/// visually the same object as the icon they just clicked.
private enum WarmPalette {
    static let plate = Color(red: 0.149, green: 0.122, blue: 0.259)
    static let glow = Color(red: 1.0, green: 0.69, blue: 0.36)

    static let plateGradient = LinearGradient(
        colors: [Color(red: 0.176, green: 0.145, blue: 0.298), Color(red: 0.075, green: 0.063, blue: 0.129)],
        startPoint: .top, endPoint: .bottom
    )
    static let screenGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.69, blue: 0.36), Color(red: 0.816, green: 0.290, blue: 0.518)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Welcome hero (empty state / first run)
//
// ─────────────────────────────────────────────────────────────
// WELCOME HERO — ENTRANCE STORYBOARD
//
// Read top-to-bottom. Each `at` value is seconds after the view appears.
// This is a one-shot entrance — nothing loops once it settles.
//
//   0.00s   screen mockup scales in, 0.92 → 1.0, fades in
//   0.12s   title fades + rises 6pt → 0
//   0.22s   subtitle fades + rises 6pt → 0
//   0.32s   button fades + rises 6pt → 0
//
// Reduce Motion: every stage lands at once under a single 0.2s fade,
// no scale, no rise.
// ─────────────────────────────────────────────────────────────

private enum WelcomeTiming {
    static let screen: Double = 0.00     // mockup scales + fades in
    static let title: Double = 0.12      // title rises in
    static let subtitle: Double = 0.22   // subtitle rises in
    static let button: Double = 0.32     // CTA rises in
}

private enum WelcomeStyle {
    static let mockupSize = CGSize(width: 208, height: 130)
    static let initialScale: CGFloat = 0.92
    static let riseOffset: CGFloat = 6
    static let spring = Animation.spring(duration: 0.5, bounce: 0.18)
}

struct WelcomeHero: View {
    let isFirstLaunch: Bool
    let addAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0   // 0 none · 1 mockup · 2 +title · 3 +subtitle · 4 +button

    var body: some View {
        VStack(spacing: 18) {
            ScreenMockup()
                .opacity(stage >= 1 ? 1 : 0)
                .scaleEffect(stage >= 1 ? 1 : WelcomeStyle.initialScale)

            VStack(spacing: 6) {
                Text(isFirstLaunch ? "Welcome to Loopwall" : "Your library is empty")
                    .font(.title3.weight(.semibold))
                    .opacity(stage >= 2 ? 1 : 0)
                    .offset(y: stage >= 2 ? 0 : WelcomeStyle.riseOffset)

                Text(isFirstLaunch
                     ? "Drop an MP4, MOV, or GIF below to play it as your wallpaper."
                     : "Drop an MP4, MOV, or GIF here to add it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .opacity(stage >= 3 ? 1 : 0)
                    .offset(y: stage >= 3 ? 0 : WelcomeStyle.riseOffset)
            }

            Button("Add Video or GIF…", action: addAction)
                .buttonStyle(.borderedProminent)
                .opacity(stage >= 4 ? 1 : 0)
                .offset(y: stage >= 4 ? 0 : WelcomeStyle.riseOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await runEntrance() }
    }

    private func runEntrance() async {
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { stage = 4 }
            return
        }
        try? await Task.sleep(for: .seconds(WelcomeTiming.screen))
        withAnimation(WelcomeStyle.spring) { stage = 1 }
        try? await Task.sleep(for: .seconds(WelcomeTiming.title - WelcomeTiming.screen))
        withAnimation(WelcomeStyle.spring) { stage = 2 }
        try? await Task.sleep(for: .seconds(WelcomeTiming.subtitle - WelcomeTiming.title))
        withAnimation(WelcomeStyle.spring) { stage = 3 }
        try? await Task.sleep(for: .seconds(WelcomeTiming.button - WelcomeTiming.subtitle))
        withAnimation(WelcomeStyle.spring) { stage = 4 }
    }
}

/// A miniature of the icon's "screen" motif — the same plate, gradient, and
/// play glyph a user just clicked in the menu bar, echoed at hero size.
private struct ScreenMockup: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(WarmPalette.plateGradient)
                .frame(width: WelcomeStyle.mockupSize.width, height: WelcomeStyle.mockupSize.height)
                .shadow(color: WarmPalette.glow.opacity(0.35), radius: 28, x: 0, y: 10)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WarmPalette.screenGradient)
                .frame(width: WelcomeStyle.mockupSize.width - 32, height: WelcomeStyle.mockupSize.height - 32)

            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(WarmPalette.plate)
        }
    }
}

// MARK: - First wallpaper celebration
//
// ─────────────────────────────────────────────────────────────
// FIRST WALLPAPER — CELEBRATION STORYBOARD
//
// Shown exactly once per install: the moment the very first import
// finishes and goes live on the desktop. Every later import is routine
// and gets no celebration — see the Delight-Impact Curve.
//
//   0.05s   backdrop fades in, thumbnail card scales in 0.88 → 1.0
//   0.30s   title fades + rises 6pt → 0
//   0.42s   subtitle fades + rises 6pt → 0
//   2.60s   card + backdrop fade out, moment dismisses
//
// Tapping anywhere dismisses immediately. Reduce Motion: card fades
// straight in at 0.15s, holds 1.4s, fades out — no scale, no rise.
// ─────────────────────────────────────────────────────────────

private enum CelebrationTiming {
    static let card: Double = 0.05
    static let title: Double = 0.30
    static let subtitle: Double = 0.42
    static let hold: Double = 2.60
}

private enum CelebrationStyle {
    static let cardSize = CGSize(width: 220, height: 138)
    static let initialScale: CGFloat = 0.88
    static let riseOffset: CGFloat = 6
    static let spring = Animation.spring(duration: 0.55, bounce: 0.22)
    static let exit = Animation.easeIn(duration: 0.22)
}

/// Fired once, the first time a user's library goes from empty to having a
/// wallpaper actually playing on their desktop.
struct FirstWallpaperMoment: Identifiable {
    let id = UUID()
    let item: WallpaperItem
    let displayCount: Int
}

struct FirstWallpaperCelebration: View {
    let moment: FirstWallpaperMoment
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0   // 0 none · 1 card · 2 +title · 3 +subtitle · 4 exiting

    var body: some View {
        ZStack {
            Color.black.opacity(stage >= 1 && stage < 4 ? 0.28 : 0)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black)
                    .frame(width: CelebrationStyle.cardSize.width, height: CelebrationStyle.cardSize.height)
                    .overlay {
                        if let thumbnail = ThumbnailCache.image(for: moment.item) {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: WarmPalette.glow.opacity(0.4), radius: 30, x: 0, y: 12)
                    .opacity(stage >= 1 ? 1 : 0)
                    .scaleEffect(stage >= 1 ? 1 : CelebrationStyle.initialScale)

                VStack(spacing: 4) {
                    Text("Your wallpaper is live")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .opacity(stage >= 2 ? 1 : 0)
                        .offset(y: stage >= 2 ? 0 : CelebrationStyle.riseOffset)

                    Text(moment.displayCount == 1
                         ? "Playing on your display"
                         : "Playing on \(moment.displayCount) displays")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .opacity(stage >= 3 ? 1 : 0)
                        .offset(y: stage >= 3 ? 0 : CelebrationStyle.riseOffset)
                }
            }
            .opacity(stage >= 4 ? 0 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .task { await runCelebration() }
    }

    private func runCelebration() async {
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { stage = 3 }
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
            return
        }
        try? await Task.sleep(for: .seconds(CelebrationTiming.card))
        withAnimation(CelebrationStyle.spring) { stage = 1 }
        try? await Task.sleep(for: .seconds(CelebrationTiming.title - CelebrationTiming.card))
        withAnimation(CelebrationStyle.spring) { stage = 2 }
        try? await Task.sleep(for: .seconds(CelebrationTiming.subtitle - CelebrationTiming.title))
        withAnimation(CelebrationStyle.spring) { stage = 3 }
        try? await Task.sleep(for: .seconds(CelebrationTiming.hold - CelebrationTiming.subtitle))
        dismiss()
    }

    private func dismiss() {
        guard stage < 4 else { return }
        withAnimation(CelebrationStyle.exit) { stage = 4 }
        Task {
            try? await Task.sleep(for: .seconds(0.24))
            onDismiss()
        }
    }
}
