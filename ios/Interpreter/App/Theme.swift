import SwiftUI
import UIKit

/// 길로그 컬러스펙 v1.1 · 타이포 · 모서리 값을 그대로 옮긴 토큰.
/// 피그마 NUA 파일의 로컬 변수와 1:1.
enum Theme {
    static let text = dyn(0x26262B, 0xF3F3F6)
    static let textSecondary = dyn(0x71717A, 0xA0A0AA)
    static let textInverse = Color.white
    static let background = dyn(0xFFFFFF, 0x131316)
    static let surface = dyn(0xF5F5F7, 0x1E1E23)
    static let surfaceRaised = dyn(0xFFFFFF, 0x242429)
    static let selected = dyn(0xE7E7EC, 0x2C2C33)
    static let accent = dyn(0xFB3C39, 0xFF5040)
    static let accentText = dyn(0xE5342F, 0xFF5040)
    static let badge = dyn(0xFB3C39, 0xFF5040, 0.12, 0.18)

    /// CTA·활성 화자 버튼 전용 그라데이션(135°).
    static func gradient(_ scheme: ColorScheme) -> LinearGradient {
        let c: [UInt32] = scheme == .dark ? [0xFF6E33, 0xFF4A66, 0xFF4090] : [0xFF5A1E, 0xF8324E, 0xF0276A]
        return LinearGradient(stops: [
            .init(color: Color(UIColor(hex: c[0])), location: 0),
            .init(color: Color(UIColor(hex: c[1])), location: 0.62),
            .init(color: Color(UIColor(hex: c[2])), location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: da) : UIColor(hex: light, alpha: la) })
    }
}

enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let cta: CGFloat = 14
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Font {
    enum Noto: String {
        case regular = "NotoSansKR-Regular"
        case medium = "NotoSansKR-Medium"
        case bold = "NotoSansKR-Bold"
    }
    static func noto(_ size: CGFloat, _ weight: Noto = .medium) -> Font { .custom(weight.rawValue, size: size) }
}

extension View {
    func cardShadow(strong: Bool = false) -> some View {
        shadow(color: .black.opacity(strong ? 0.2 : 0.12), radius: 10, x: 0, y: 3)
    }
}
