import CryptoKit
import Foundation

/// 语义化版本号（支持 `v3.1.0`、`3.1`、`3.1.0-beta.1`、`3.1.0+13`）
public struct SemVer: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// 预发布标识段（如 `beta.1` -> `["beta", "1"]`）；正式版为空数组
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // 去掉 +build 元数据
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        let pre: [String]
        if let dash = s.firstIndex(of: "-") {
            let preStr = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
            let parts = preStr.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            pre = parts
        } else {
            pre = []
        }
        let nums = s.split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count >= 2, nums.count <= 3 else { return nil }
        guard let maj = Int(nums[0]), let min = Int(nums[1]), maj >= 0, min >= 0 else { return nil }
        let pat: Int
        if nums.count == 3 {
            guard let p = Int(nums[2]), p >= 0 else { return nil }
            pat = p
        } else {
            pat = 0
        }
        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = pre
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : "\(base)-\(prerelease.joined(separator: "."))"
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 正式版 > 预发布版
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (na?, nb?): return na < nb
            case (_?, nil): return true    // 数字标识低于非数字标识（SemVer 2.0 规范）
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// GitHub Release 附件
public struct UpdateAsset: Equatable, Codable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64

    public init(name: String, downloadURL: URL, size: Int64) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }
}

/// 解析后的 GitHub Release 信息
public struct UpdateRelease: Equatable, Codable, Sendable {
    public let tagName: String
    public let version: SemVer
    public let name: String
    public let body: String
    public let htmlURL: URL
    public let publishedAt: Date?
    public let assets: [UpdateAsset]

    public init(tagName: String, version: SemVer, name: String, body: String,
                htmlURL: URL, publishedAt: Date?, assets: [UpdateAsset]) {
        self.tagName = tagName
        self.version = version
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    public enum ParseError: Error, Equatable {
        case invalidJSON
        case missingVersion(String)
        case invalidURL
        case draftOrPrerelease
    }

    /// 解析 GitHub `/releases/latest` 响应
    public static func parseGitHubRelease(_ data: Data) throws -> UpdateRelease {
        struct RawAsset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64?
        }
        struct RawRelease: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String
            let published_at: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [RawAsset]?
        }
        let raw: RawRelease
        do {
            raw = try JSONDecoder().decode(RawRelease.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }
        if raw.draft == true || raw.prerelease == true {
            throw ParseError.draftOrPrerelease
        }
        guard let version = SemVer(raw.tag_name) else {
            throw ParseError.missingVersion(raw.tag_name)
        }
        guard let htmlURL = URL(string: raw.html_url) else {
            throw ParseError.invalidURL
        }
        let iso = ISO8601DateFormatter()
        let published = raw.published_at.flatMap { iso.date(from: $0) }
        let assets: [UpdateAsset] = (raw.assets ?? []).compactMap { a in
            guard let u = URL(string: a.browser_download_url) else { return nil }
            return UpdateAsset(name: a.name, downloadURL: u, size: a.size ?? 0)
        }
        let title = (raw.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "PopBar \(raw.tag_name)"
        return UpdateRelease(
            tagName: raw.tag_name,
            version: version,
            name: title,
            body: raw.body ?? "",
            htmlURL: htmlURL,
            publishedAt: published,
            assets: assets
        )
    }

    /// 匹配本机架构（`arm64` / `x86_64`）对应的 DMG 安装包：
    /// 优先 `*-<arch>.dmg`，其次 `*-universal.dmg`，最后唯一不含另一架构名的 `.dmg`。
    public func preferredDMG(for arch: String) -> UpdateAsset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let target = arch.lowercased()
        let other = target == "arm64" ? "x86_64" : "arm64"
        if let exact = dmgs.first(where: { $0.name.lowercased().contains("-\(target).dmg") || $0.name.lowercased().contains("_\(target).dmg") }) {
            return exact
        }
        if let uni = dmgs.first(where: { $0.name.lowercased().contains("universal") }) {
            return uni
        }
        let neutral = dmgs.filter { !$0.name.lowercased().contains(other) }
        return neutral.count == 1 ? neutral[0] : nil
    }

    /// 匹配本机架构（`arm64` / `x86_64`）对应的 `.app.zip` 更新包（应用内更新优先使用，无需挂载 DMG）
    public func preferredAppZip(for arch: String) -> UpdateAsset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".app.zip") }
        let target = arch.lowercased()
        let other = target == "arm64" ? "x86_64" : "arm64"
        if let exact = zips.first(where: { $0.name.lowercased().contains("-\(target).app.zip") || $0.name.lowercased().contains("_\(target).app.zip") }) {
            return exact
        }
        if let uni = zips.first(where: { $0.name.lowercased().contains("universal") }) {
            return uni
        }
        let neutral = zips.filter { !$0.name.lowercased().contains(other) }
        return neutral.count == 1 ? neutral[0] : nil
    }

    /// 匹配本机架构的应用内更新包：优先 `.app.zip`，回退 `.dmg`（兼容旧版 Release）。
    public func preferredPackage(for arch: String) -> UpdateAsset? {
        preferredAppZip(for: arch) ?? preferredDMG(for: arch)
    }

    /// 校验文件附件（如 `SHA256SUMS.txt`）
    public var checksumAsset: UpdateAsset? {
        assets.first {
            let n = $0.name.lowercased()
            return n == "sha256sums.txt" || n == "sha256sums" || n == "checksums.txt" || n.hasSuffix(".sha256")
        }
    }

    /// 离线 Ed25519 签名附件（`SHA256SUMS.txt.sig`）
    public var signatureAsset: UpdateAsset? {
        assets.first { $0.name.lowercased() == "sha256sums.txt.sig" }
    }

    /// 提取更新说明正文：Release 模板前半段是固定的下载与安装说明，用 `---` 与实际变更日志隔开
    public var changelogText: String {
        let trimmed = body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let range = trimmed.range(of: "\n---\n") {
            let after = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { return after }
        }
        return trimmed
    }

    /// 从标准 `sha256sum` / `shasum -a 256` 文本中取出指定文件名的 64 位小写 hex 摘要
    public static func parseSHA256Sums(_ text: String, filename: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            if name == filename || URL(fileURLWithPath: name).lastPathComponent == filename {
                return hash
            }
        }
        return nil
    }
}

/// 安装目标解析结果
public struct UpdateInstallTarget: Equatable, Sendable {
    public let destinationURL: URL
    /// true 表示原地覆盖当前 `.app`；false 表示安装到 `/Applications/PopBar.app`
    public let isInPlace: Bool

    public init(destinationURL: URL, isInPlace: Bool) {
        self.destinationURL = destinationURL
        self.isInPlace = isInPlace
    }

    /// 根据当前运行的 bundle 路径决定覆盖目标：
    /// - 正常运行的 `.app`：原地覆盖；
    /// - 从只读 DMG（`/Volumes/`）、App Translocation（`/AppTranslocation/`）或裸二进制启动：安装到 `/Applications/PopBar.app`。
    public static func resolve(bundleURL: URL, defaultApplications: URL = URL(fileURLWithPath: "/Applications")) -> UpdateInstallTarget {
        let path = bundleURL.standardizedFileURL.path
        let isApp = bundleURL.pathExtension.lowercased() == "app"
        let isTranslocated = path.contains("/AppTranslocation/")
        let isMountedVolume = path.hasPrefix("/Volumes/")
        if isApp && !isTranslocated && !isMountedVolume {
            return UpdateInstallTarget(destinationURL: bundleURL.standardizedFileURL, isInPlace: true)
        }
        return UpdateInstallTarget(
            destinationURL: defaultApplications.appendingPathComponent("PopBar.app"),
            isInPlace: false
        )
    }
}

/// 发版离线验签（Ed25519）：使用硬编码公钥验证 CI 用 OpenSSL 签出的 `SHA256SUMS.txt.sig`。
public enum UpdateSignature {
    /// PopBar 发版签名公钥（原始 32 字节，对应 GitHub Actions Secret `RELEASE_SIGNING_KEY`）
    public static let releasePublicKeyBytes: [UInt8] = [
        0x02, 0x21, 0xb4, 0xae, 0xb0, 0xe4, 0xf7, 0x0b,
        0xe4, 0x97, 0xf9, 0xad, 0x2c, 0x13, 0x14, 0x38,
        0x93, 0x0a, 0xaa, 0x87, 0x6c, 0x4a, 0xfc, 0x4e,
        0x87, 0xd9, 0xe5, 0x22, 0xa1, 0x8c, 0x68, 0xa2,
    ]

    public enum VerifyError: Error, Equatable {
        case invalidPublicKey
        case invalidSignatureLength(Int)
        case invalidSignature
    }

    public static func verify(
        _ message: Data,
        signature: Data,
        publicKeyBytes: [UInt8] = releasePublicKeyBytes
    ) throws {
        guard signature.count == 64 else {
            throw VerifyError.invalidSignatureLength(signature.count)
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKeyBytes)) else {
            throw VerifyError.invalidPublicKey
        }
        guard key.isValidSignature(signature, for: message) else {
            throw VerifyError.invalidSignature
        }
    }
}

/// 后台自动检查节流与失败退避策略（与石渠一致：6h 常规间隔，失败按 1/2/4/6h 指数退避）
public enum UpdateSchedule {
    public static let checkInterval: TimeInterval = 6 * 3600
    public static let retryBase: TimeInterval = 3600
    public static let retryMax: TimeInterval = 6 * 3600
    public static let periodicPollInterval: TimeInterval = 15 * 60

    /// 第 `failures` 次连续失败后的等待时间：1h、2h、4h，封顶 6h。
    public static func retryDelay(failures: Int) -> TimeInterval {
        let shift = min(max(failures - 1, 0), 3)
        return min(retryBase * Double(1 << shift), retryMax)
    }

    /// 当前时刻是否到期需要自动检查：失败退避优先于常规 6 小时间隔。
    public static func isDue(now: Date, lastChecked: Date?, retryAfter: Date?) -> Bool {
        if let retryAfter, retryAfter.timeIntervalSince1970 > 0 {
            return now >= retryAfter
        }
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= checkInterval
    }
}

/// 更新替换与重启的后台脚本：所有路径通过位置参数（`$1`…`$7`）传入，避免命令注入。
public enum UpdateScript {
    /// 参数：
    /// - `$1`: 旧进程 PID
    /// - `$2`: 目标 `.app` 路径
    /// - `$3`: 已解压校验并清理 quarantine 的暂存 `.app` 路径（与 `$2` 同目录）
    /// - `$4`: 备份 `.app` 路径（替换成功后删除，失败时回滚）
    /// - `$5`: 可选自定义启动命令（默认 `open`；设为 `skip` 表示仅替换不重启，用于退出安装与自动化测试）
    /// - `$6`: 可选安装日志文件路径（`install.log`）
    /// - `$7`: 可选失败标记文件路径（`install-failed`，下次启动时读取提示并清除）
    public static let swapAndRelaunch = """
    set -u
    pid="$1"
    target="$2"
    staged="$3"
    backup="$4"
    launcher="${5:-open}"
    log="${6:-}"
    mark="${7:-}"

    log_line() {
        if [ -n "$log" ]; then
            printf '%s %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log" 2>/dev/null || true
        fi
    }

    fail() {
        code="$1"; shift
        log_line "$*"
        if [ -n "$mark" ]; then
            printf '%s\\n' "$*" >"$mark" 2>/dev/null || true
        fi
        exit "$code"
    }

    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do
        case "$(/bin/ps -o state= -p "$pid" 2>/dev/null)" in
            ""|Z*) break ;;
        esac
        sleep 0.1
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        case "$(/bin/ps -o state= -p "$pid" 2>/dev/null)" in
            ""|Z*) ;;
            *) kill -TERM "$pid" 2>/dev/null || true; sleep 0.5 ;;
        esac
    fi

    if [ ! -d "$staged" ]; then
        fail 2 "找不到待安装的新版本文件"
    fi

    rm -rf "$backup"
    if [ -e "$target" ]; then
        if ! mv "$target" "$backup"; then
            rm -rf "$staged"
            fail 3 "没有权限替换 $target"
        fi
    fi

    if mv "$staged" "$target"; then
        rm -rf "$backup"
        [ -n "$mark" ] && rm -f "$mark"
        log_line "已更新到新版本"
    else
        if [ -e "$backup" ]; then
            mv "$backup" "$target" 2>/dev/null || true
        fi
        rm -rf "$staged"
        fail 4 "新版本替换失败，已恢复旧版本"
    fi

    /usr/bin/xattr -cr "$target" 2>/dev/null || true
    if [ "$launcher" != "skip" ]; then
        "$launcher" "$target"
    fi
    """
}
