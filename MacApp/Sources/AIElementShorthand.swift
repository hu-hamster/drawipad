import Foundation

/// AI 友好的元素简写 → 完整 Excalidraw 元素展开器。
///
/// 支持简写（未填字段自动补默认值）：
///   {"type":"rectangle","x":100,"y":100,"width":180,"height":60,"label":"DP0","fill":"#a5d8ff"}
///   {"type":"arrow","from":"n1","to":"n2","label":"register"}
///   {"type":"text","x":100,"y":100,"text":"标题","fontSize":32}
///
/// 便捷别名：fill → backgroundColor、stroke → strokeColor、
/// label → 自动生成绑定文本元素、from/to → 自动计算箭头端点并绑定。
enum AIElementShorthand {
    struct ExpandResult {
        let elements: [[String: Any]]
    }

    /// 展开一批简写元素（from/to 引用的元素可以来自本批或 existing 元素）。
    static func expand(_ items: [[String: Any]], existing: [[String: Any]]?) -> ExpandResult? {
        var byID = [String: [String: Any]]()
        var result: [[String: Any]] = []
        var bindings: [(arrowID: String, targetID: String, end: String)] = []

        for (key, value) in existingAsDictionary(existing) {
            byID[key] = value
        }

        for item in items {
            let type = (item["type"] as? String ?? "rectangle").lowercased()
            switch type {
            case "rectangle", "ellipse", "diamond":
                guard let element = expandShape(item, type: type) else { return nil }
                result.append(element.0)
                byID[element.1] = element.0
                if let labelElement = element.2 {
                    result.append(labelElement)
                    byID[element.1 + "_label"] = labelElement
                }
            case "text":
                guard let element = expandText(item) else { return nil }
                result.append(element)
                byID[element["id"] as? String ?? ""] = element
            case "arrow", "line":
                let (element, fromID, toID) = expandArrow(item, type: type)
                guard let element else { return nil }
                result.append(element)
                let id = element["id"] as? String ?? ""
                byID[id] = element
                if let label = item["label"] as? String {
                    let labelElement = makeBoundText(
                        id: id + "_label", containerID: id,
                        x: (element["x"] as? Double) ?? 0, y: (element["y"] as? Double) ?? 0,
                        text: label, fontSize: item["fontSize"] == nil ? 14 : fontSize(from: item),
                        containerWidth: (element["width"] as? Double) ?? 120,
                        containerHeight: (element["height"] as? Double) ?? 30)
                    result.append(labelElement)
                }
                if let fromID { bindings.append((id, fromID, "start")) }
                if let toID { bindings.append((id, toID, "end")) }
            case "freedraw":
                guard let element = expandFreedraw(item) else { return nil }
                result.append(element)
            default:
                return nil
            }
        }

        // 处理 from/to 绑定：箭头指向目标元素中心
        for binding in bindings {
            guard let target = byID[binding.targetID] else { continue }
            guard var arrow = byID[binding.arrowID] else { continue }
            let tx = (target["x"] as? Double) ?? 0
            let ty = (target["y"] as? Double) ?? 0
            let tw = (target["width"] as? Double) ?? 100
            let th = (target["height"] as? Double) ?? 60
            let cx = tx + tw / 2
            let cy = ty + th / 2

            // 统一坐标空间：points 是相对箭头 x/y 的坐标，先把既有 points 转成绝对坐标，
            // 再把端点设为目标中心，最后重新归一化——避免相对/绝对混用产生偏移
            let oldX = (arrow["x"] as? Double) ?? 0
            let oldY = (arrow["y"] as? Double) ?? 0
            var points = (arrow["points"] as? [[Double]]) ?? []
            if points.count >= 2 {
                points = points.map { [$0[0] + oldX, $0[1] + oldY] }
                if binding.end == "start" {
                    points[0] = [cx, cy]
                } else {
                    points[points.count - 1] = [cx, cy]
                }
            }
            // 重算 bbox（x/y 为左上角，points 相对坐标）
            let xs = points.map { $0[0] }
            let ys = points.map { $0[1] }
            let minX = (xs.min() ?? 0), maxX = (xs.max() ?? 0)
            let minY = (ys.min() ?? 0), maxY = (ys.max() ?? 0)
            let width = max(1, maxX - minX)
            let height = max(1, maxY - minY)
            arrow["x"] = minX
            arrow["y"] = minY
            arrow["width"] = width
            arrow["height"] = height
            arrow["points"] = points.map { [$0[0] - minX, $0[1] - minY] }
            let bindingDict: [String: Any] = [
                "elementId": binding.targetID, "focus": 0, "gap": 4, "fixedPoint": NSNull()
            ]
            if binding.end == "start" {
                arrow["startBinding"] = bindingDict
            } else {
                arrow["endBinding"] = bindingDict
            }
            // 目标元素登记 boundElements
            var updatedTarget = target
            var bound = (updatedTarget["boundElements"] as? [[String: Any]]) ?? []
            bound.append(["id": binding.arrowID, "type": binding.end == "start" ? "arrow" : "arrow"])
            updatedTarget["boundElements"] = bound
            byID[binding.targetID] = updatedTarget

            byID[binding.arrowID] = arrow
            // 更新 result 中对应元素（箭头与目标）
            result = result.map { element -> [String: Any] in
                let id = element["id"] as? String ?? ""
                if id == binding.arrowID { return arrow }
                if id == binding.targetID { return updatedTarget }
                return element
            }
        }

        return ExpandResult(elements: result)
    }

    // MARK: - 各类型展开

    private static func expandShape(_ item: [String: Any], type: String) -> ([String: Any], String, [String: Any]?)? {
        let id = stringID(item)
        var element = baseElement(item, id: id, type: type)
        element["width"] = number(item, "width", default: 140)
        element["height"] = number(item, "height", default: 70)
        if type == "rectangle" {
            element["roundness"] = ["type": 3]
        }
        var labelElement: [String: Any]?
        if let label = item["label"] as? String {
            let labelFont = item["fontSize"] == nil ? 16 : fontSize(from: item)
            element["boundElements"] = [["id": id + "_label", "type": "text", "isPrimary": true] as [String: Any]]
            let boxW = (element["width"] as? Double) ?? 140
            let boxH = (element["height"] as? Double) ?? 70
            // 大容器（分组框）标签放左上角，避免垂直居中撞到内部元素
            if boxH > 160 {
                labelElement = makeBoundText(
                    id: id + "_label", containerID: id,
                    x: (element["x"] as? Double) ?? 0 + 16, y: (element["y"] as? Double) ?? 0 + 12,
                    text: label, fontSize: labelFont,
                    containerWidth: boxW - 32, containerHeight: Double(labelFont) + 8,
                    topLeft: true)
            } else {
                labelElement = makeBoundText(
                    id: id + "_label", containerID: id,
                    x: (element["x"] as? Double) ?? 0, y: (element["y"] as? Double) ?? 0,
                    text: label, fontSize: labelFont,
                    containerWidth: boxW, containerHeight: boxH)
            }
        }
        return (element, id, labelElement)
    }

    private static func expandText(_ item: [String: Any]) -> [String: Any]? {
        guard let text = item["text"] as? String else { return nil }
        let id = stringID(item)
        var element = baseElement(item, id: id, type: "text")
        let fontSize = Self.fontSize(from: item)
        element["text"] = text
        element["rawText"] = text
        element["originalText"] = text
        element["fontSize"] = fontSize
        element["fontFamily"] = 1
        element["lineHeight"] = 1.25
        element["hasTextLink"] = false
        element["textAlign"] = item["align"] as? String ?? "left"
        element["verticalAlign"] = "top"
        element["autoResize"] = true
        let charWidth = Double(fontSize) * 0.55
        let lines = text.components(separatedBy: "\n")
        element["width"] = number(item, "width", default: Double(lines.map(\.count).max() ?? 1) * charWidth + 8)
        element["height"] = number(item, "height", default: Double(lines.count) * Double(fontSize) * 1.25 + 8)
        if let color = item["textColor"] as? String {
            element["strokeColor"] = color
        }
        return element
    }

    private static func expandArrow(_ item: [String: Any], type: String) -> ([String: Any]?, String?, String?) {
        let id = stringID(item)
        var element = baseElement(item, id: id, type: type)

        var points: [[Double]]
        if let raw = item["points"] as? [[Double]], raw.count >= 2 {
            points = raw
        } else {
            let x1 = number(item, "x1", default: 0)
            let y1 = number(item, "y1", default: 0)
            let x2 = number(item, "x2", default: 200)
            let y2 = number(item, "y2", default: 0)
            points = [[x1, y1], [x2, y2]]
        }
        let xs = points.map { $0[0] }
        let ys = points.map { $0[1] }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let baseX = (element["x"] as? Double) ?? 0
        let baseY = (element["y"] as? Double) ?? 0
        element["x"] = baseX + minX
        element["y"] = baseY + minY
        element["width"] = max(1, (xs.max() ?? 0) - minX)
        element["height"] = max(1, (ys.max() ?? 0) - minY)
        element["points"] = points.map { [$0[0] - minX, $0[1] - minY] }
        element["lastCommittedPoint"] = NSNull()
        element["startBinding"] = NSNull()
        element["endBinding"] = NSNull()
        element["startArrowhead"] = NSNull()
        element["endArrowhead"] = type == "arrow" ? "arrow" : NSNull()
        if let curve = item["curve"] as? Bool, curve == false {
            element["elbowed"] = false
        }
        return (element, item["from"] as? String, item["to"] as? String)
    }

    private static func expandFreedraw(_ item: [String: Any]) -> [String: Any]? {
        let id = stringID(item)
        var element = baseElement(item, id: id, type: "freedraw")
        var points: [[Double]] = []
        if let raw = item["points"] as? [[Double]] {
            points = raw
        } else if let path = item["path"] as? [[Double]] {
            points = path
        }
        guard points.count >= 2 else { return nil }
        let xs = points.map { $0[0] }
        let ys = points.map { $0[1] }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        element["x"] = ((element["x"] as? Double) ?? 0) + minX
        element["y"] = ((element["y"] as? Double) ?? 0) + minY
        element["width"] = max(1, (xs.max() ?? 0) - minX)
        element["height"] = max(1, (ys.max() ?? 0) - minY)
        element["points"] = points.map { [$0[0] - minX, $0[1] - minY] }
        element["pressures"] = points.map { _ in 0.5 }
        element["simulatePressure"] = false
        element["lastCommittedPoint"] = NSNull()
        return element
    }

    // MARK: - 工具

    private static func baseElement(_ item: [String: Any], id: String, type: String) -> [String: Any] {
        var element: [String: Any] = [
            "type": type,
            "id": id,
            "x": number(item, "x", default: 0),
            "y": number(item, "y", default: 0),
            "angle": number(item, "angle", default: 0),
            "strokeColor": (item["stroke"] as? String) ?? "#1e1e1e",
            "backgroundColor": (item["fill"] as? String) ?? "transparent",
            "fillStyle": (item["fillStyle"] as? String) ?? "solid",
            "strokeWidth": number(item, "strokeWidth", default: 2),
            "strokeStyle": (item["strokeStyle"] as? String) ?? "solid",
            "roughness": Int(number(item, "roughness", default: 1)),
            "opacity": Int(number(item, "opacity", default: 100)),
            "groupIds": [],
            "frameId": NSNull(),
            "roundness": NSNull(),
            "seed": Int.random(in: 100_000...999_999),
            "version": 1,
            "versionNonce": Int.random(in: 100_000...999_999),
            "isDeleted": false,
            "boundElements": NSNull(),
            "updated": Int(Date().timeIntervalSince1970 * 1000),
            "link": NSNull(),
            "locked": false,
        ]
        if type == "rectangle" || type == "ellipse" || type == "diamond" {
            element["roundness"] = ["type": type == "rectangle" ? 3 : 2]
        }
        return element
    }

    /// 估算一行文本宽度（CJK 全宽、拉丁半宽）。
    private static func measuredWidth(_ text: String, fontSize: Int) -> Double {
        var width = 0.0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 {
                width += Double(fontSize)
            } else {
                width += Double(fontSize) * 0.58
            }
        }
        return width
    }

    private static func makeBoundText(
        id: String, containerID: String, x: Double, y: Double,
        text: String, fontSize: Int,
        containerWidth: Double = 120, containerHeight: Double = 56,
        topLeft: Bool = false
    ) -> [String: Any] {
        // 自己测量并居中：Excalidraw 恢复场景时不会重排绑定文本，
        // 占位尺寸会导致文字漂在容器左上角。
        let lines = text.components(separatedBy: "\n")
        let lineWidth = lines.map { measuredWidth($0, fontSize: fontSize) }.max() ?? 10
        let lineHeight = Double(fontSize) * 1.28
        let textWidth = max(10, lineWidth + 4)
        let textHeight = max(10, lineHeight * Double(lines.count))
        let centeredX = topLeft ? x : x + (containerWidth - textWidth) / 2
        let centeredY = topLeft ? y : y + (containerHeight - textHeight) / 2
        return [
            "type": "text",
            "id": id,
            "x": centeredX,
            "y": centeredY,
            "width": textWidth,
            "height": textHeight,
            "angle": 0,
            "strokeColor": "#1e1e1e",
            "backgroundColor": "transparent",
            "fillStyle": "solid",
            "strokeWidth": 1,
            "strokeStyle": "solid",
            "roughness": 1,
            "opacity": 100,
            "groupIds": [],
            "frameId": NSNull(),
            "roundness": NSNull(),
            "seed": Int.random(in: 100_000...999_999),
            "version": 1,
            "versionNonce": Int.random(in: 100_000...999_999),
            "isDeleted": false,
            "boundElements": NSNull(),
            "updated": Int(Date().timeIntervalSince1970 * 1000),
            "link": NSNull(),
            "locked": false,
            "text": text,
            "rawText": text,
            "originalText": text,
            "fontSize": fontSize,
            "fontFamily": 1,
            "lineHeight": 1.25,
            "hasTextLink": false,
            "textAlign": topLeft ? "left" : "center",
            "verticalAlign": topLeft ? "top" : "middle",
            "containerId": containerID,
            "autoResize": true,
        ]
    }

    private static func fontSize(from item: [String: Any]) -> Int {
        Int(number(item, "fontSize", default: 20))
    }

    private static func stringID(_ item: [String: Any]) -> String {
        if let id = item["id"] as? String, !id.isEmpty { return id }
        return UUID().uuidString.prefix(12).lowercased().replacingOccurrences(of: "-", with: "")
    }

    private static func number(_ item: [String: Any], _ key: String, default defaultValue: Double) -> Double {
        if let value = item[key] as? Double { return value }
        if let value = item[key] as? Int { return Double(value) }
        if let value = item[key] as? String, let parsed = Double(value) { return parsed }
        return defaultValue
    }

    private static func existingAsDictionary(_ existing: [[String: Any]]?) -> [String: [String: Any]] {
        var dict = [String: [String: Any]]()
        for element in existing ?? [] {
            if let id = element["id"] as? String {
                dict[id] = element
            }
        }
        return dict
    }
}
