import Foundation

/// OpenAI 兼容 /chat/completions 的流式客户端(DeepSeek、硅基流动、OpenAI、OpenRouter 等通用)
enum LLMClient {
    enum Event {
        case delta(String)
        case done
        case failure(String)
    }

    enum ClientError: LocalizedError {
        case badURL(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .badURL(let s): return L10n.t("Base URL 无效: \(s)", "Invalid Base URL: \(s)")
            case .badResponse: return L10n.t("响应格式无法解析", "Unparsable response format")
            }
        }
    }

    /// 发起一次流式翻译请求;返回的 Task 可 cancel()
    static func stream(text: String, systemPrompt: String?, provider: LLMProvider,
                       timeout: Double, temperature: Double,
                       onEvent: @escaping (Event) -> Void) -> Task<Void, Never> {
        var messages: [[String: String]] = []
        if let sys = systemPrompt, !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": text])
        return stream(messages: messages, provider: provider,
                      timeout: timeout, temperature: temperature, onEvent: onEvent)
    }

    /// 多轮消息版本(追问用)
    static func stream(messages: [[String: String]], provider: LLMProvider,
                       timeout: Double, temperature: Double,
                       onEvent: @escaping (Event) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            do {
                let request = try makeRequest(messages: messages,
                                              provider: provider, timeout: timeout,
                                              temperature: temperature)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    onEvent(.failure(L10n.t("无 HTTP 响应", "No HTTP response"))); return
                }
                guard (200..<300).contains(http.statusCode) else {
                    var body = ""
                    for try await line in bytes.lines {
                        body += line
                        if body.count > 600 { break }
                    }
                    onEvent(.failure(serverMessage(status: http.statusCode, body: body)))
                    return
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
                    if let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty {
                        onEvent(.delta(piece))
                    }
                }
                onEvent(.done)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                onEvent(.failure(error.localizedDescription))
            }
        }
    }

    // MARK: - 私有

    private static func makeRequest(messages: [[String: String]], provider: LLMProvider,
                                    timeout: Double, temperature: Double) throws -> URLRequest {
        let base = provider.baseURL.hasSuffix("/")
            ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let url = URL(string: base + "/chat/completions") else {
            throw ClientError.badURL(provider.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("PopBar/0.1", forHTTPHeaderField: "User-Agent")

        var body: [String: Any] = [
            "model": provider.model,
            "stream": true,
            "temperature": temperature,
            "messages": messages,
        ]
        if let extra = thinkingExtra(for: provider) {
            body.merge(extra) { _, new in new }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 深度思考开关对应附加参数;各家 OpenAI 兼容服务的字段名不同,按域名适配:
    /// DeepSeek 用 thinking.type;OpenRouter 用 reasoning;Qwen/硅基流动/vLLM 系用 enable_thinking。
    /// 未知服务走最通用的 enable_thinking + chat_template_kwargs,不支持的字段会被服务端忽略。
    private static func thinkingExtra(for provider: LLMProvider) -> [String: Any]? {
        guard let mode = provider.thinking, mode != "default" else { return nil }
        let enable = (mode == "on")
        let host = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        if host.contains("deepseek") {
            return ["thinking": ["type": enable ? "enabled" : "disabled"]]
        }
        if host.contains("openrouter") {
            return ["reasoning": enable ? ["enabled": true] : ["exclude": true]]
        }
        return [
            "enable_thinking": enable,
            "chat_template_kwargs": ["enable_thinking": enable],
        ]
    }

    /// 从错误响应里尽量抽出可读信息
    private static func serverMessage(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return "HTTP \(status): \(message)"
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(trimmed.prefix(160))"
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }
}

/// 翻译提示词与语言判断
enum TranslatePrompt {
    static func resolveTarget(_ configured: String, text: String) -> String {
        if configured != "auto" { return configured }
        return LanguageDetect.containsCJK(text) ? "en" : "zh-CN"
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "zh-CN", "zh": return "Simplified Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        default: return code
        }
    }

    static func systemPrompt(source: String, target: String) -> String {
        var lines = [
            "You are a professional translation engine.",
            "Translate the user's text into \(languageName(target)).",
            "Output only the translation itself: no explanations, no notes, no surrounding quotes.",
            "Preserve the original formatting, line breaks, numbers, code snippets and proper nouns.",
        ]
        if source != "auto" {
            lines.append("The source language is \(languageName(source)).")
        }
        return lines.joined(separator: " ")
    }

    /// 开启「自定义提示词」时系统提示词的默认模板(用变量保留动态目标语言)
    static let customSystemTemplate =
        "You are a professional translation engine. Translate the user's text into {$query.detectToLang}. Output only the translation itself: no explanations, no notes, no surrounding quotes. Preserve the original formatting, line breaks, numbers, code snippets and proper nouns."

    /// 模板变量替换,带不带花括号都认:
    /// {$query.text} / $query.text 原文、{$query.detectFromLang} / $query.detectFromLang 源语言、
    /// {$query.detectToLang} / $query.detectToLang 目标语言
    static func render(_ template: String, text: String, source: String, target: String) -> String {
        let from = source == "auto" ? LanguageDetect.code(text) : source
        // 先替换带花括号的,再替换裸写法(后者是前者的子串,顺序不能反)
        return template
            .replacingOccurrences(of: "{$query.text}", with: text)
            .replacingOccurrences(of: "{$query.detectFromLang}", with: languageName(from))
            .replacingOccurrences(of: "{$query.detectToLang}", with: languageName(target))
            .replacingOccurrences(of: "$query.text", with: text)
            .replacingOccurrences(of: "$query.detectFromLang", with: languageName(from))
            .replacingOccurrences(of: "$query.detectToLang", with: languageName(target))
    }

    /// 组装发给模型的 (system, user):provider 配了自定义提示词就渲染模板,否则用默认翻译提示词
    static func messages(source: String, target: String, text: String,
                         provider: LLMProvider) -> (system: String?, user: String) {
        let system = provider.systemPrompt.map {
            render($0, text: text, source: source, target: target)
        } ?? systemPrompt(source: source, target: target)
        let user = provider.userPrompt.map {
            render($0.isEmpty ? "{$query.text}" : $0, text: text, source: source, target: target)
        } ?? text
        return (system, user)
    }
}

/// 轻量语言判断,用于"识别为 …"徽标与自动目标语言
enum LanguageDetect {
    static func containsCJK(_ text: String) -> Bool {
        text.range(of: "[\\u4e00-\\u9fff\\u3040-\\u30ff]", options: .regularExpression) != nil
    }

    static func containsKana(_ text: String) -> Bool {
        text.range(of: "[\\u3040-\\u30ff]", options: .regularExpression) != nil
    }

    static func containsHangul(_ text: String) -> Bool {
        text.range(of: "[\\uac00-\\ud7af]", options: .regularExpression) != nil
    }

    /// 给用户看的描述,例如「中文简体」
    static func describe(_ text: String) -> String {
        if containsKana(text) { return L10n.t("日本語", "Japanese") }
        if containsHangul(text) { return L10n.t("한국어", "Korean") }
        if containsCJK(text) { return L10n.t("中文简体", "Chinese (Simplified)") }
        let latin = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if latin > 0 { return "English" }
        return L10n.t("未知语言", "Unknown")
    }

    static func code(_ text: String) -> String {
        if containsKana(text) { return "ja" }
        if containsHangul(text) { return "ko" }
        if containsCJK(text) { return "zh-CN" }
        return "en"
    }
}
