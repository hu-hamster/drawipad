import Foundation

/// 导入 .excalidraw / .excalidraw.md（Obsidian 插件格式）文件。
enum ExcalidrawImport {
    /// 解析文本，返回 elements 数组的 JSON 字符串（nil = 无法解析）。
    static func parseScene(fromText text: String) -> String? {
        if let direct = parseJSONScene(text) {
            return direct
        }
        // 某些工具会直接输出带 encoded 字段的压缩 JSON，而不是 Markdown 栅栏。
        if text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{",
           let compressed = parseCompressed(text) {
            return compressed
        }
        // Markdown 代码栅栏（```json / ```compressed-json / 无语言标注）。
        // Obsidian 的 .excalidraw.md 会把实际场景放在这里。
        guard let fenceRegex = try? NSRegularExpression(
            pattern: "```([A-Za-z0-9_-]+)?[ \\t]*\\r?\\n([\\s\\S]*?)```"
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var last: String?
        for match in fenceRegex.matches(in: text, range: range) {
            guard let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let body = String(text[bodyRange])
            if let scene = parseJSONScene(body) {
                last = scene
            } else if let scene = parseCompressed(body) {
                last = scene
            }
        }
        return last
    }

    /// 直接 JSON 场景（Excalidraw 对象或单独的 elements 数组）。
    static func parseJSONScene(_ source: String) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        if let scene = object as? [String: Any], let elements = scene["elements"] as? [Any] {
            return serializeElements(elements)
        }
        if let elements = object as? [Any] {
            return serializeElements(elements)
        }
        return nil
    }

    /// Obsidian Excalidraw 插件压缩格式：
    ///
    /// - 当前版本：代码栅栏内直接放 LZ-String `compressToBase64` 的结果。
    /// - 兼容部分旧版/第三方导出：JSON 包装的 base64 zlib 数据。
    static func parseCompressed(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let encoded = object["encoded"] as? String,
           let payload = Data(base64Encoded: encoded),
           let inflated = inflate(payload),
           let json = String(data: inflated, encoding: .utf8) {
            return parseJSONScene(json)
        }

        // Obsidian 会把超长的压缩字符串换行；Base64 中的空白不属于数据。
        let encoded = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let json = decompressLZStringBase64(encoded) else { return nil }
        return parseJSONScene(json)
    }

    /// 解压：兼容 raw deflate（RFC1951）与 zlib 包装（RFC1950，pako 默认）。
    private static func inflate(_ data: Data) -> Data? {
        if let raw = try? (data as NSData).decompressed(using: .zlib), !raw.isEmpty {
            return raw as Data
        }
        guard data.count > 6, data[data.startIndex] == 0x78 else { return nil }
        let stripped = data.dropFirst(2).dropLast(4)
        return (try? (stripped as NSData).decompressed(using: .zlib)) as Data?
    }

    /// 把 elements 数组重新序列化为紧凑 JSON 字符串。
    private static func serializeElements(_ elements: [Any]) -> String? {
        guard let out = try? JSONSerialization.data(
            withJSONObject: elements,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    // MARK: - LZ-String

    /// `lz-string` 的 `decompressFromBase64` 的 Swift 移植。
    /// Obsidian Excalidraw 的 `compressed-json` 代码块使用的正是这种编码，
    /// 并不是标准 zlib，因此不能交给 `NSData.decompressed` 处理。
    private static func decompressLZStringBase64(_ input: String) -> String? {
        guard !input.isEmpty else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var values = [Character: Int]()
        for (index, character) in alphabet.enumerated() {
            values[character] = index
        }
        let symbols = Array(input)
        guard symbols.allSatisfy({ values[$0] != nil }) else { return nil }

        var dataValue = values[symbols[0]] ?? 0
        var dataPosition = 32
        var dataIndex = 1

        func readBits(_ count: Int) -> Int {
            var bits = 0
            var power = 1
            let maxPower = 1 << count
            while power != maxPower {
                let bit = dataValue & dataPosition
                dataPosition >>= 1
                if dataPosition == 0 {
                    dataPosition = 32
                    dataValue = dataIndex < symbols.count ? (values[symbols[dataIndex]] ?? 0) : 0
                    dataIndex += 1
                }
                if bit != 0 { bits |= power }
                power <<= 1
            }
            return bits
        }

        var dictionary = [Int: [UInt16]]()
        dictionary[0] = [0]
        dictionary[1] = [1]
        dictionary[2] = [2]
        var dictionarySize = 4
        var enlargeIn = 4
        var numBits = 3

        let initial = readBits(2)
        let first: [UInt16]
        switch initial {
        case 0:
            first = [UInt16(readBits(8))]
        case 1:
            first = [UInt16(readBits(16))]
        case 2:
            return ""
        default:
            return nil
        }
        dictionary[3] = first

        var word = first
        var result = first
        while true {
            let code = readBits(numBits)
            let entry: [UInt16]
            switch code {
            case 0:
                let value = [UInt16(readBits(8))]
                dictionary[dictionarySize] = value
                dictionarySize += 1
                enlargeIn -= 1
                entry = value
            case 1:
                let value = [UInt16(readBits(16))]
                dictionary[dictionarySize] = value
                dictionarySize += 1
                enlargeIn -= 1
                entry = value
            case 2:
                return String(decoding: result, as: UTF16.self)
            default:
                if let value = dictionary[code] {
                    entry = value
                } else if code == dictionarySize, let firstCharacter = word.first {
                    entry = word + [firstCharacter]
                } else {
                    return nil
                }
            }

            // 新字面量耗尽当前码宽时，下一轮读取必须先扩一位。
            // 这一步与 lz-string 的原始实现位置一致，不能等到下方
            // 写入 word + entry 后再判断。
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }

            result += entry
            guard let firstCharacter = entry.first else { return nil }
            dictionary[dictionarySize] = word + [firstCharacter]
            dictionarySize += 1
            enlargeIn -= 1
            word = entry

            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
    }

    /// 从文件名生成画板名（去掉 .excalidraw / .md 等后缀）。
    static func pageName(fromFileName fileName: String) -> String {
        var name = fileName
        for ext in [".excalidraw.md", ".excalidraw", ".md", ".json"] where name.hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        return name.isEmpty ? "导入画板" : name
    }
}
