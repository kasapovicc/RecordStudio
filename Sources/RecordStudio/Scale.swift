import AppKit
import RecordCore
import SwiftUI

// The UI's one scale for spacing, corner radii and colour. Views use only these values, so things that should match do.
// Type uses the system text styles (.title2, .headline, .body, .callout, .subheadline, .caption…); a custom size only
// for the countdown digits, the recording timer and the teleprompter's user-set text size.
// RecordCoreTests/ScaleTests checks that no view slips a literal back in.

enum Space {
    static let xxs = 2.0, xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0
}

enum Radius {
    static let small = 6.0, medium = 10.0, large = 16.0

    /// A shape nested `inset` points inside one with radius `outer` keeps its corners concentric.
    static func inner(_ outer: Double, inset: Double) -> Double { max(0, outer - inset) }
    /// A selection ring drawn `inset` points outside a shape with radius `inner`.
    static func outer(_ inner: Double, inset: Double) -> Double { inner + inset }
}

// Two colours: graphite for selection and focus in place of system blue, and the brand red for anything that means
// recording. Errors and destructive buttons keep the system red, so "error" and "recording" stay apart by context.
extension NSColor {
    static let record = NSColor(srgbRed: Brand.red.r, green: Brand.red.g, blue: Brand.red.b, alpha: 1)
    static let graphite = NSColor(name: "graphite") { a in
        switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        // Selected tabs and switches fill with it, and AppKit picks dark or light text to match. A mid grey reads as
        // disabled, so it's near-white in dark mode and near-black in light mode.
        case .darkAqua: NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1) // #F2F2F5
        case .accessibilityHighContrastDarkAqua: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .accessibilityHighContrastAqua: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        default: NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1) // #232428
        }
    }
}

extension Color {
    /// One colour in light mode and another in dark mode, for fills the system colours don't cover.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

// On ShapeStyle rather than Color, so `.record` also works where a style is expected (`.fill(.record)`).
extension ShapeStyle where Self == Color {
    static var record: Color { Color(nsColor: .record) }
    static var graphite: Color { Color(nsColor: .graphite) }
}

// The system's display settings (Accessibility › Display), applied in one place so every surface follows them alike.
// Liquid Glass turns opaque by itself with Reduce Transparency; Reduce Motion is read where things move, falling back to a fade.

/// The primary colour at a low opacity, for faint borders and fills. With Increase Contrast it's about twice as strong.
struct Faint: ShapeStyle {
    let opacity: Double
    static func opacity(_ o: Double, increased: Bool) -> Double { increased ? min(1, o * 2 + 0.08) : o }
    func resolve(in env: EnvironmentValues) -> Color { Color.primary.opacity(Self.opacity(opacity, increased: env.colorSchemeContrast == .increased)) }
}

/// Tertiary marks and text (ruler labels, lane icons), stepped up to secondary with Increase Contrast.
struct Quiet: ShapeStyle {
    func resolve(in env: EnvironmentValues) -> HierarchicalShapeStyle { env.colorSchemeContrast == .increased ? .secondary : .tertiary }
}

/// A dark backing behind white text or over video, solid with Reduce Transparency.
struct Scrim: ShapeStyle {
    let opacity: Double
    func resolve(in env: EnvironmentValues) -> Color { .black.opacity(env.accessibilityReduceTransparency ? 1 : opacity) }
}

extension ShapeStyle where Self == Faint { static func faint(_ opacity: Double) -> Faint { Faint(opacity: opacity) } }
extension ShapeStyle where Self == Quiet { static var quiet: Quiet { Quiet() } }
extension ShapeStyle where Self == Scrim { static func scrim(_ opacity: Double) -> Scrim { Scrim(opacity: opacity) } }

// Surfaces: which material each layer uses, so a view picks from this list rather than a hand-tuned opacity.
// - Window: the system window background. Strips docked in it (the timeline's transport) use `.bar`.
// - Floating controls inside a window (toasts, progress capsules, the editor's floating buttons) and panels floating
//   over other apps (record bar, recording pill, window and area pickers): `.glassEffect(.regular)`.
// - Text read for a long time over other apps (the teleprompter): `.ultraThickMaterial`, so what's behind never competes.
// - White text over video or images: `.scrim(_:)`.
// With Reduce Transparency, glass and materials turn opaque by themselves and `.scrim` turns solid.

// Motion: one name per reason something moves. Views use these, never a literal curve, through `.motion(_:value:)` or
// `withAnimation(Motion.x.respecting(reduceMotion))`, so Reduce Motion turns movement into a short cross-fade.
// Nothing started from the keyboard animates. RecordCoreTests/ScaleTests fails on a literal curve outside this file.
enum Motion {
    /// A button or tile while it's held down, scaled to `pressScale` (see `PressableButtonStyle`).
    static let press = Animation.easeOut(duration: 0.12)
    static let pressScale = 0.97
    /// Hover outlines, colour and opacity changes.
    static let hover = Animation.easeOut(duration: 0.15)
    /// Popovers, panels, toasts and items appearing.
    static let enter = Animation.spring(duration: 0.3, bounce: 0)
    /// The same things leaving, faster than they came.
    static let exit = Animation.easeOut(duration: 0.18)
    /// What arrives once something it depends on is there: the editor's timeline and inspector after the first frame.
    static let follow = Animation.spring(duration: 0.3, bounce: 0).delay(0.1)
    /// Something moving or resizing on screen: a highlight sliding to another tab, the welcome window's pages.
    static let move = Animation.spring(duration: 0.4, bounce: 0)
    /// Only after a drag is released, so it carries the drag's momentum.
    static let settle = Animation.spring(duration: 0.35, bounce: 0.15)
    /// What Reduce Motion plays in place of any of the above.
    static let fade = Animation.easeOut(duration: 0.15)
    /// The recording light breathing. Not played with Reduce Motion.
    static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    /// The welcome window's sketch of a recording: a click, its ripple fading, the camera zooming in and out. Slower than
    /// the rest, since it shows how something works rather than answering a click.
    static let demoClick = Animation.easeOut(duration: 0.4)
    static let demoRipple = Animation.easeOut(duration: 0.5).delay(0.4)
    static let demoZoom = Animation.spring(duration: 1.1, bounce: 0)
}

extension Animation {
    /// This animation, or `Motion.fade` with Reduce Motion.
    func respecting(_ reduceMotion: Bool) -> Animation { reduceMotion ? Motion.fade : self }
}

extension View {
    /// `.animation(_:value:)` with a `Motion` curve that cross-fades instead with Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View { modifier(MotionModifier(animation: animation, value: value)) }

    /// Feedback while held down, from the moment it's pressed: scaled to `scale`, or slightly dimmed with Reduce Motion.
    func pressed(_ isPressed: Bool, scale: Double = Motion.pressScale) -> some View { modifier(Pressed(isPressed: isPressed, scale: scale)) }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation, value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(animation.respecting(reduceMotion), value: value) }
}

private struct Pressed: ViewModifier {
    let isPressed: Bool, scale: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? scale : 1)
            .opacity(isPressed && reduceMotion ? 0.8 : 1)
            .animation(Motion.press, value: isPressed)
    }
}

/// A plain button that sinks slightly while held down, so it answers the press rather than the release.
struct PressableButtonStyle: ButtonStyle {
    var scale = Motion.pressScale
    func makeBody(configuration: Configuration) -> some View { configuration.label.pressed(configuration.isPressed, scale: scale) }
}

extension AnyTransition {
    /// Appearing from what opened it: fading in from 96% at `anchor`, and leaving the same way. Only the fade with
    /// Reduce Motion.
    static func enterFromTrigger(anchor: UnitPoint) -> AnyTransition {
        .modifier(active: Shift(scale: 0.96, anchor: anchor, visible: false), identity: Shift(anchor: anchor))
    }

    /// Fading in 40 points from `edge`, and out the same way. Only the fade with Reduce Motion.
    static func slide(edge: Edge) -> AnyTransition {
        let d = 40.0, x = edge == .leading ? -d : edge == .trailing ? d : 0, y = edge == .top ? -d : edge == .bottom ? d : 0
        return .modifier(active: Shift(x: x, y: y, visible: false), identity: Shift())
    }
}

extension AnyTransition {
    /// A message (progress capsule, toast) at `edge`: fading in 8 points from it, and back out the same way, faster.
    /// Only the fade with Reduce Motion.
    static func message(at edge: Edge) -> AnyTransition {
        let y = edge == .bottom ? Space.s : -Space.s
        let shift = AnyTransition.modifier(active: Shift(y: y, visible: false), identity: Shift())
        return .asymmetric(insertion: shift.animation(Motion.enter), removal: shift.animation(Motion.exit))
    }
}

private struct Shift: ViewModifier {
    var x = 0.0, y = 0.0, scale = 1.0, anchor = UnitPoint.center, visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : scale, anchor: anchor)
            .offset(x: reduceMotion ? 0 : x, y: reduceMotion ? 0 : y)
            .opacity(visible ? 1 : 0)
    }
}
