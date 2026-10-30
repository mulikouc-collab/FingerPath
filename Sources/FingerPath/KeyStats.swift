import Foundation

/// 常错键统计：字符键后马上按删除键，算这个键打错一次。只记键名和次数，只存在本机。
enum KeyStats {
    private static let key = "FingerPath.keyMistakes"

    static func record(_ character: Character) {
        var counts = all
        counts[String(character), default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }

    static var all: [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    /// 最容易打错的几个键，如「A×12  S×8  ;×5」。
    static func summary(top: Int = 5) -> String {
        let items = all.sorted { $0.value > $1.value }.prefix(top)
        guard !items.isEmpty else { return "还没有统计数据" }
        return items.map { "\($0.key.uppercased())×\($0.value)" }.joined(separator: "  ")
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
