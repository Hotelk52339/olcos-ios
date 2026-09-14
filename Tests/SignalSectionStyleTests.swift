import XCTest
import UIKit
import SwiftUI
@testable import olcrtc_ios

// boc #492: the shared treatment must not turn a readable primary action into
// a light-on-light label. Test the actual tokens in both system appearances.
@MainActor
final class SignalSectionStyleTests: XCTestCase {
    func testSignalPrimaryActionHasReadableContrastInBothAppearances() {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            let foreground = UIColor(Theme.Signal.onAction).resolvedColor(with: traits)
            let background = UIColor(Theme.Signal.actionFill).resolvedColor(with: traits)
            let light = max(luminance(foreground), luminance(background))
            let dark = min(luminance(foreground), luminance(background))
            XCTAssertGreaterThanOrEqual((light + 0.05) / (dark + 0.05), 4.5)
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
// eoc #492
