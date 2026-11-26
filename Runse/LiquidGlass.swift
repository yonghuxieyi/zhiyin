import SwiftUI

/// Item 15 (UI redesign): Liquid Glass, app-wide (2026-11-26 23:03 —
/// "界面风格用苹果液态玻璃（Liquid Glass），半透明毛玻璃效果").
///
/// iOS 26's `.glassEffect()` is the real Liquid Glass; the deployment
/// target is iOS 18, so on older systems the same call sites fall back
/// to the frosted `.ultraThinMaterial` — same look family, just without
/// the refraction. Dark mode flips automatically in both cases.
///
/// Use it for floating controls and content cards (pill nav, camera
/// overlays, translate-page cards, floating round buttons). Do NOT nest
/// it — glass on glass compounds and looks muddy — and do NOT put it
/// on state-coloured controls (mic buttons, selected pill item) or on
/// list rows / Form sections, which the system already styles.
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
