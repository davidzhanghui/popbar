import Foundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

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
            case .badURL(let s): return L10n.t("Base URL 无效：\(s)", "Invalid Base URL: \(s)")
            case .badResponse: return L10n.t("响应格式无法解析", "Unparsable response format")
            }
        }
    }

    /// UA 带上真实版本号（以前一直写着 PopBar/0.1）
    static let userAgent = "PopBar/" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")

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
        request.setValue(LLMClient.userAgent, forHTTPHeaderField: "User-Agent")

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
