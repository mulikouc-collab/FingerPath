import Foundation
import NaturalLanguage
@preconcurrency import Translation

enum TextLanguage: Sendable {
    case chinese
    case english

    var label: String {
        switch self {
        case .chinese: "中"
        case .english: "英"
        }
    }

    /// 汉字数量不少于拉丁字母的三分之一，就当作中文处理（中英混排时偏向中文）。
    static func detect(_ text: String) -> TextLanguage {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                han += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            default:
                break
            }
        }
        return han > 0 && han * 3 >= latin ? .chinese : .english
    }
}

struct TranslationResult: Sendable, Equatable {
    let source: String
    let translated: String
    let sourceLanguage: TextLanguage

    /// 统一「中文 → English」的顺序。
    var chineseText: String { sourceLanguage == .chinese ? source : translated }
    var englishText: String { sourceLanguage == .chinese ? translated : source }
}

struct WordGloss: Sendable, Equatable, Hashable {
    let chinese: String
    let english: String

    var asResult: TranslationResult {
        TranslationResult(source: chinese, translated: english, sourceLanguage: .chinese)
    }
}

enum TranslationServiceError: LocalizedError {
    case unsupportedSystem
    case languageNotInstalled

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            "需要 macOS 26 或更高版本"
        case .languageNotInstalled:
            "请先下载翻译语言：系统设置 → 通用 → 语言与地区 → 翻译语言 → 中文（简体）和英语"
        }
    }
}

/// 中英互译。使用系统自带的离线翻译模型，不联网、不收费。
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    private let chinese = Locale.Language(identifier: "zh-Hans")
    private let english = Locale.Language(identifier: "en")
    private var sessions: [String: AnyObject] = [:]

    func translate(_ text: String) async throws -> TranslationResult {
        let language = TextLanguage.detect(text)
        guard #available(macOS 26.0, *) else { throw TranslationServiceError.unsupportedSystem }
        let session = try session(from: language)
        do {
            let response = try await session.translate(text)
            return TranslationResult(
                source: text,
                translated: response.targetText.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceLanguage: language
            )
        } catch {
            // 模型未下载时会话会失效，丢弃缓存，下次重新创建。
            sessions[key(for: language)] = nil
            throw TranslationServiceError.languageNotInstalled
        }
    }

    @available(macOS 26.0, *)
    private func session(from language: TextLanguage) throws -> TranslationSession {
        let cacheKey = key(for: language)
        if let cached = sessions[cacheKey] as? TranslationSession { return cached }
        let session = language == .chinese
            ? TranslationSession(installedSource: chinese, target: english)
            : TranslationSession(installedSource: english, target: chinese)
        sessions[cacheKey] = session
        return session
    }

    /// 中文逐词对照：分词后挑出含汉字的词（去重，最多 8 个），逐个翻译。
    func wordGlosses(for text: String) async -> [WordGloss] {
        guard #available(macOS 26.0, *), TextLanguage.detect(text) == .chinese else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if TextLanguage.detect(word) == .chinese, !words.contains(word) {
                words.append(word)
            }
            return words.count < 8
        }
        // 只有一个词时，整句翻译已经是它的意思了。
        guard words.count > 1, let session = try? session(from: .chinese) else { return [] }
        // 逐个翻译：词很短，本地模型很快；批量接口在 Swift 6 并发检查下无法从主线程调用。
        var glosses: [WordGloss] = []
        for word in words {
            guard !Task.isCancelled else { break }
            if let response = try? await session.translate(word) {
                let english = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                glosses.append(WordGloss(chinese: word, english: english))
            }
        }
        return glosses
    }

    private func key(for language: TextLanguage) -> String {
        language == .chinese ? "zh-en" : "en-zh"
    }
}
