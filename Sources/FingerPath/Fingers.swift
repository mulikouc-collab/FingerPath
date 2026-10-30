import SwiftUI

/// 十根手指，从左手小指 1 号数到右手小指 10 号。
enum Finger: Int, CaseIterable {
    case leftPinky = 1, leftRing, leftMiddle, leftIndex, leftThumb
    case rightThumb, rightIndex, rightMiddle, rightRing, rightPinky

    var number: Int { rawValue }
    var isLeft: Bool { rawValue <= 5 }

    var name: String {
        switch self {
        case .leftPinky: "左手小指"
        case .leftRing: "左手无名指"
        case .leftMiddle: "左手中指"
        case .leftIndex: "左手食指"
        case .leftThumb: "左手大拇指"
        case .rightThumb: "右手大拇指"
        case .rightIndex: "右手食指"
        case .rightMiddle: "右手中指"
        case .rightRing: "右手无名指"
        case .rightPinky: "右手小指"
        }
    }

    /// 这根手指平时「住」在哪个键上（起始位置）。
    var homeKey: Character? {
        switch self {
        case .leftPinky: "a"
        case .leftRing: "s"
        case .leftMiddle: "d"
        case .leftIndex: "f"
        case .rightIndex: "j"
        case .rightMiddle: "k"
        case .rightRing: "l"
        case .rightPinky: ";"
        case .leftThumb, .rightThumb: " "
        }
    }

    /// 每个键由哪根手指负责（标准指法）。空格用大拇指（5 或 6 号都行，这里记为 6 号）。
    static func of(_ key: Character) -> Finger {
        switch key {
        case "q", "a", "z", "1", "`": .leftPinky
        case "w", "s", "x", "2": .leftRing
        case "e", "d", "c", "3": .leftMiddle
        case "r", "f", "v", "t", "g", "b", "4", "5": .leftIndex
        case "y", "h", "n", "u", "j", "m", "6", "7": .rightIndex
        case "i", "k", ",", "8": .rightMiddle
        case "o", "l", ".", "9": .rightRing
        case "p", ";", "/", "'", "0", "-", "=", "[", "]", "\\": .rightPinky
        default: .rightThumb
        }
    }

    static let homeKeys: Set<Character> = ["a", "s", "d", "f", "j", "k", "l", ";"]
}

/// 手指颜色：左右对称的手指同色（1/10、2/9、3/8、4/7、5/6）。
/// 用 Okabe-Ito 色弱友好色板的实色，红绿色弱也能分清；文字颜色按底色深浅选黑或白。
enum FingerPalette {
    static func color(_ finger: Finger) -> Color {
        switch finger {
        case .leftIndex, .rightIndex: Color(red: 0.94, green: 0.89, blue: 0.26)   // 黄
        case .leftMiddle, .rightMiddle: Color(red: 0.34, green: 0.71, blue: 0.91) // 天蓝
        case .leftRing, .rightRing: Color(red: 0.0, green: 0.62, blue: 0.45)      // 深绿
        case .leftPinky, .rightPinky: Color(red: 0.80, green: 0.47, blue: 0.65)   // 紫红
        case .leftThumb, .rightThumb: Color(white: 0.72)                           // 灰
        }
    }

    static func text(_ finger: Finger) -> Color {
        switch finger {
        case .leftRing, .rightRing: .white
        default: .black
        }
    }
}
