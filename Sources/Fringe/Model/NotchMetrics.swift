import AppKit

/// Geometry of the notch on a particular screen.
struct NotchMetrics: Equatable {
    var size: CGSize
    /// False when we are drawing a stand-in notch on a display without a cutout.
    var isPhysical: Bool

    /// Always measures the hardware when there is a cutout to measure. The
    /// stand-in size is a fallback for displays without one, never a choice —
    /// a hardcoded width silently misaligns the drawn notch from the real one.
    @MainActor
    static func resolve(for screen: NSScreen, settings: NotchSettings) -> NotchMetrics {
        if let physical = physicalSize(
            screenWidth: screen.frame.width,
            leftAuxiliary: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliary: screen.auxiliaryTopRightArea?.width,
            topInset: screen.safeAreaInsets.top
        ) {
            return NotchMetrics(size: physical, isPhysical: true)
        }
        return NotchMetrics(size: settings.simulatedNotchSize, isPhysical: false)
    }

    /// The cutout sits between the two auxiliary areas AppKit reports on
    /// either side of it, and is as tall as the top safe area inset.
    ///
    /// Numbers rather than `NSScreen`, so the formula can be checked without
    /// a notched display attached. A missing auxiliary area or a zero inset
    /// means there is no cutout, not "guess a width".
    static func physicalSize(
        screenWidth: CGFloat,
        leftAuxiliary: CGFloat?,
        rightAuxiliary: CGFloat?,
        topInset: CGFloat
    ) -> CGSize? {
        guard let leftAuxiliary, let rightAuxiliary, topInset > 0 else { return nil }
        let width = screenWidth - leftAuxiliary - rightAuxiliary
        guard width > 1 else { return nil }
        return CGSize(width: width, height: topInset)
    }
}

extension NSScreen {
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil
    }

    /// The display the panel should live on: the notched one if there is one,
    /// otherwise whichever screen currently holds the menu bar.
    static func notchHost() -> NSScreen? {
        screens.first(where: \.hasPhysicalNotch) ?? main ?? screens.first
    }
}
