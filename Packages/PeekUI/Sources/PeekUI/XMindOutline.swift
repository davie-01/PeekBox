import Foundation

/// 把 XMind 导图内容转成树状大纲文本，用于没有内嵌缩略图的文件（多为其他程序生成，XMind 自己保存时都会附带缩略图）。
/// 新版（XMind Zen 起）为 content.json，XMind 8 及更早为 content.xml
enum XMindOutline {
    struct Topic {
        var title: String
        var children: [Topic]
    }

    struct Sheet {
        var title: String
        var root: Topic
    }

    /// content.json：工作表数组，每个工作表的 rootTopic 下 children.attached 为分支，detached 为自由主题
    static func sheets(json data: Data) -> [Sheet]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func topic(_ object: [String: Any]) -> Topic {
            let children = object["children"] as? [String: Any]
            let nested = ["attached", "detached"].flatMap { children?[$0] as? [[String: Any]] ?? [] }
            return Topic(title: object["title"] as? String ?? "", children: nested.map(topic))
        }
        let sheets = array.compactMap { sheet -> Sheet? in
            guard let root = sheet["rootTopic"] as? [String: Any] else { return nil }
            return Sheet(title: sheet["title"] as? String ?? "", root: topic(root))
        }
        return sheets.isEmpty ? nil : sheets
    }

    /// content.xml：xmap-content/sheet/topic，分支位于 children/topics（type 为 attached 或 detached）
    static func sheets(xml data: Data) -> [Sheet]? {
        guard let root = try? XMLDocument(data: data).rootElement() else { return nil }
        func elements(_ element: XMLElement, named name: String) -> [XMLElement] {
            (element.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
        }
        func title(_ element: XMLElement) -> String {
            elements(element, named: "title").first?.stringValue ?? ""
        }
        func topic(_ element: XMLElement) -> Topic {
            let groups = elements(element, named: "children").flatMap { elements($0, named: "topics") }
                .filter { ["attached", "detached"].contains($0.attribute(forName: "type")?.stringValue ?? "attached") }
            return Topic(title: title(element), children: groups.flatMap { elements($0, named: "topic") }.map(topic))
        }
        let sheets = elements(root, named: "sheet").compactMap { sheet -> Sheet? in
            guard let root = elements(sheet, named: "topic").first else { return nil }
            return Sheet(title: title(sheet), root: topic(root))
        }
        return sheets.isEmpty ? nil : sheets
    }

    /// 多个工作表时各加标题；主题标题中的换行合并为空格。超过 limit 个字符时停止，返回 truncated
    static func text(of sheets: [Sheet], limit: Int) -> (String, truncated: Bool) {
        var lines: [String] = []
        var count = 0
        func append(_ line: String) -> Bool {
            guard count < limit else { return false }
            lines.append(line)
            count += line.count + 1
            return true
        }
        func walk(_ topic: Topic, prefix: String, last: Bool, depth: Int) -> Bool {
            let title = flatten(topic.title)
            let line = depth == 0 ? title : prefix + (last ? "└─ " : "├─ ") + title
            guard append(line) else { return false }
            let childPrefix = depth == 0 ? "" : prefix + (last ? "   " : "│  ")
            for (index, child) in topic.children.enumerated() {
                guard walk(child, prefix: childPrefix, last: index == topic.children.count - 1, depth: depth + 1) else { return false }
            }
            return true
        }
        var complete = true
        for (index, sheet) in sheets.enumerated() where complete {
            if sheets.count > 1 {
                if index > 0 { lines.append("") }
                complete = append("【\(flatten(sheet.title))】")
            }
            complete = complete && walk(sheet.root, prefix: "", last: true, depth: 0)
        }
        return (lines.joined(separator: "\n"), !complete)
    }

    private static func flatten(_ title: String) -> String {
        title.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
