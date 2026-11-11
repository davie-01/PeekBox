import CryptoKit
import Foundation
import Testing
@testable import PeekCore

/// ZIP 写入的交叉校验：每次修改后用 unzip -t、7zz t 校验 CRC，再用 ditto（系统"归档实用工具"同一引擎）、
/// 7zz 与本应用分别完整解压，与预期内容逐字节比较。
@Suite(.serialized) struct ZipCrossValidationTests {
    typealias Reference = FormatMatrixTests.Reference
    static let sevenZip = FormatMatrixTests.sevenZip

    struct Expected {
        var files: [String: Data]
        var directories: Set<String>
    }

    @Test(arguments: [false, true])
    func survivesEditSequence(aes: Bool) throws {
        guard !aes || FormatMatrixTests.hasSevenZip else { return }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reference = try Reference(in: fixture.work)
        let zip = fixture.work.appendingPathComponent("edit.zip")
        let password: String? = aes ? "pass word" : nil
        if aes {
            #expect(try run(Self.sevenZip, ["a", "-tzip", "-mem=AES256", "-ppass word", zip.path, "."], in: reference.root) == 0)
        } else {
            #expect(try run("/usr/bin/zip", ["-q", "-r", zip.path, "."], in: reference.root) == 0)
        }
        var expected = Expected(files: reference.files, directories: reference.emptyDirectories)
        try validate(zip, expected, password: password, step: "初始", in: fixture.work)

        func rename(_ path: String, to name: String) throws {
            let newPath = try ZipEditor.rename(archive: zip, path: path, to: name, trashOldVersion: false)
            expected.files = Dictionary(uniqueKeysWithValues: expected.files.map { key, value in
                (key == path || key.hasPrefix(path + "/")) ? (newPath + key.dropFirst(path.count), value) : (key, value)
            })
            expected.directories = Set(expected.directories.map {
                ($0 == path || $0.hasPrefix(path + "/")) ? newPath + $0.dropFirst(path.count) : $0
            })
            try validate(zip, expected, password: password, step: "改名 \(path) → \(name)", in: fixture.work)
        }

        try rename("说明.txt", to: "说明 ✅.txt")
        try rename("数据/random.bin", to: "RANDOM.bin")
        try rename("数据/RANDOM.bin", to: "random.BIN")
        try rename("文档", to: "Documents 文档")

        try ZipEditor.delete(archive: zip, paths: ["a"], trashOldVersion: false)
        expected.files = expected.files.filter { !$0.key.hasPrefix("a/") }
        try validate(zip, expected, password: password, step: "删除 a/", in: fixture.work)

        // 拖入一整棵目录（加密 ZIP 不支持新增，应拒绝且原包不变）
        let incoming = fixture.work.appendingPathComponent("导入")
        try FileManager.default.createDirectory(at: incoming.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        var random = Data(count: 512 * 1024)
        _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try Data("导入的文本".utf8).write(to: incoming.appendingPathComponent("子目录/x.txt"))
        try random.write(to: incoming.appendingPathComponent("y.bin"))
        if aes {
            #expect(throws: ZipEditor.EditError.encryptedWrite) {
                try ZipEditor.addFiles(archive: zip, sources: [incoming], parent: "", trashOldVersion: false) { _ in .init(.cancel) }
            }
        } else {
            try ZipEditor.addFiles(archive: zip, sources: [incoming], parent: "Documents 文档", trashOldVersion: false) { _ in .init(.cancel) }
            expected.files["Documents 文档/导入/子目录/x.txt"] = Data("导入的文本".utf8)
            expected.files["Documents 文档/导入/y.bin"] = random
            try validate(zip, expected, password: password, step: "拖入目录", in: fixture.work)

            try ZipEditor.createDirectory(archive: zip, parent: "", name: "层级 1")
            try ZipEditor.createDirectory(archive: zip, parent: "层级 1", name: "层级 2")
            expected.directories.formUnion(["层级 1", "层级 1/层级 2"])
            try validate(zip, expected, password: password, step: "新建嵌套文件夹", in: fixture.work)
        }
    }

    // MARK: - 校验

    private func validate(_ zip: URL, _ expected: Expected, password: String?, step: String, in work: URL) throws {
        let passwordArgs = password.map { ["-p\($0)"] } ?? []
        if password == nil {
            #expect(try run("/usr/bin/unzip", ["-tqq", zip.path], in: work) == 0, "unzip -t 失败：\(step)")
        }
        if FormatMatrixTests.hasSevenZip {
            #expect(try run(Self.sevenZip, ["t", "-bso0", "-bsp0"] + passwordArgs + [zip.path], in: work) == 0, "7zz t 失败：\(step)")
            let out = work.appendingPathComponent("7zz-\(UUID().uuidString)")
            #expect(try run(Self.sevenZip, ["x", "-bso0", "-bsp0", "-o" + out.path] + passwordArgs + [zip.path], in: work) == 0)
            compare(directory: out, with: expected, tool: "7zz", step: step)
        }
        if password == nil {
            let out = work.appendingPathComponent("ditto-\(UUID().uuidString)")
            #expect(try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], in: work) == 0, "ditto 解压失败：\(step)")
            compare(directory: out, with: expected, tool: "ditto", step: step)
        }
        // 本应用：目录树与内容
        let reader = try ZipArchive.open(zip)
        let files = Set(reader.tree.items.values.filter { !$0.isDirectory }.map(\.path))
        #expect(files == Set(expected.files.keys), "本应用列表不符（\(step)）：多出 \(files.subtracting(expected.files.keys).sorted())，缺少 \(Set(expected.files.keys).subtracting(files).sorted())")
        for directory in expected.directories {
            #expect(reader.tree.items[directory]?.isDirectory == true, "本应用缺少目录 \(directory)（\(step)）")
        }
        for (path, data) in expected.files {
            guard let item = reader.tree.items[path] else { continue }
            let target = work.appendingPathComponent(UUID().uuidString)
            try reader.extractFile(item, to: target, password: password)
            #expect(SHA256.hash(data: try Data(contentsOf: target)) == SHA256.hash(data: data), "本应用内容不符 \(path)（\(step)）")
        }
    }

    private func compare(directory: URL, with expected: Expected, tool: String, step: String) {
        var actual: [String: Data] = [:]
        var directories = Set<String>()
        let base = directory.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count)).precomposedStringWithCanonicalMapping
            if path.hasPrefix("__MACOSX") || path.hasSuffix(".DS_Store") { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.insert(path)
            } else {
                actual[path] = try? Data(contentsOf: url)
            }
        }
        #expect(Set(actual.keys) == Set(expected.files.keys),
                "\(tool) 解压列表不符（\(step)）：多出 \(Set(actual.keys).subtracting(expected.files.keys).sorted())，缺少 \(Set(expected.files.keys).subtracting(actual.keys).sorted())")
        for (path, data) in expected.files where actual[path] != data {
            Issue.record("\(tool) 内容不符 \(path)（\(step)）")
        }
        #expect(expected.directories.isSubset(of: directories), "\(tool) 缺少目录 \(expected.directories.subtracting(directories).sorted())（\(step)）")
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
