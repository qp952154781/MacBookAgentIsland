import AppKit
import IslandCore

@MainActor struct NotchGeometry {
    let screen: NSScreen
    var metrics: NotchMetrics {
        NotchMetrics(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                     auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea,
                     menuBarHeight: NSStatusBar.system.thickness, visibleFrame: screen.visibleFrame)
    }

    static func preferred(useMainScreen: Bool = false) -> NotchGeometry? {
        if useMainScreen { return (NSScreen.screens.first ?? NSScreen.main).map { NotchGeometry(screen: $0) } }
        let builtIn = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
        return (builtIn ?? NSScreen.main ?? NSScreen.screens.first).map { NotchGeometry(screen: $0) }
    }

    func json() -> [String: Any] {
        let notch = metrics
        return ["screenName": screen.localizedName, "frame": Self.rectJSON(screen.frame), "scale": screen.backingScaleFactor,
                "safeAreaTop": screen.safeAreaInsets.top,
                "auxiliaryTopLeft": screen.auxiliaryTopLeftArea.map(Self.rectJSON) as Any? ?? NSNull(),
                "auxiliaryTopRight": screen.auxiliaryTopRightArea.map(Self.rectJSON) as Any? ?? NSNull(),
                "hasNotch": notch.hasNotch, "notchRect": Self.rectJSON(notch.notchRect),
                "islandFrames": Dictionary(uniqueKeysWithValues: IslandMode.allCases.map {
                    ($0.rawValue, Self.rectJSON(IslandLayout.frame(for: $0, notch: notch)))
                })]
    }
    static func rectJSON(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
