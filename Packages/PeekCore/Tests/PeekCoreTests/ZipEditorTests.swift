import CLibzip
import Foundation
import Testing
@testable import PeekCore

@Suite struct ZipEditorTests {
    /// 解压后逐字节比对，确认未改名的内容原样保留
    private func contents(of zip: URL, _ path: String) throws -> Data {
        let archive = try ZipArchive.open(zip)
        let item = try #require(archive.tree.items[path])
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        try archive.extractFile(item, to: target, password: nil)
        return try Data(contentsOf: target)
    }

    @Test func renamesFileAndKeepsContent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let before = try ZipArchive.open(zip).tree.items.count

        let newPath = try ZipEditor.rename(archive: zip, path: "config/format.json", to: "格式.json", trashOldVersion: false)

        #expect(newPath == "config/格式.json")
        let tree = try ZipArchive.open(zip).tree
        #expect(tree.items["config/format.json"] == nil)
        #expect(tree.items.count == before)
        #expect(try contents(of: zip, "config/格式.json") == Data("{}".utf8))
        #expect(try contents(of: zip, "config/deep/大文件.bin") == Data(repeating: 7, count: 600_000))
        // 不留临时文件与旧版本
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).filter { $0 != "content" }
        #expect(leftovers == ["sample.zip"])
    }

    @Test(arguments: [false, true])
    func renamesDirectoryWithDescendants(noDirEntries: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // -D：不写目录条目，config 只是由后代路径推导出的隐式目录
        let zip = try fixture.zip("sample.zip", extra: noDirEntries ? ["-D"] : [])

        try ZipEditor.rename(archive: zip, path: "config", to: "settings", trashOldVersion: false)

        let tree = try ZipArchive.open(zip).tree
        #expect(tree.items["config"] == nil)
        #expect(tree.items["settings/format.json"] != nil)
        #expect(tree.items["settings/deep"]?.isDirectory == true)
        #expect(try contents(of: zip, "settings/deep/大文件.bin") == Data(repeating: 7, count: 600_000))
    }

    @Test func rejectsExistingAndInvalidNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")

        #expect(throws: ZipEditor.EditError.nameExists("config")) {
            try ZipEditor.rename(archive: zip, path: "README.md", to: "config", trashOldVersion: false)
        }
        #expect(throws: ZipEditor.EditError.invalidName) {
            try ZipEditor.rename(archive: zip, path: "README.md", to: "a/b", trashOldVersion: false)
        }
        #expect(throws: ZipEditor.EditError.invalidName) {
            try ZipEditor.rename(archive: zip, path: "README.md", to: "  ", trashOldVersion: false)
        }
    }

    /// Windows 压缩的包：文件名是 GBK 原始字节、没有 UTF-8 标志。改文件夹名后后代路径都应正确，新名字写为 UTF-8
    @Test func renamesGBKDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = fixture.work.appendingPathComponent("gbk.zip")
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        var code: Int32 = 0
        let handle = try #require(zip_open(zip.path, ZIP_CREATE | ZIP_EXCL, &code))
        func raw(_ name: String) -> [CChar] { (Array(name.data(using: gb18030)!) + [0]).map { CChar(bitPattern: $0) } }
        #expect(zip_dir_add(handle, raw("资料/"), zip_flags_t(ZIP_FL_ENC_RAW)) >= 0)
        for (name, content) in [("资料/说明.txt", "说明"), ("资料/子目录/数据.csv", "1,2")] {
            // 数据在 zip_close 时才读取：先写到临时文件
            let file = fixture.work.appendingPathComponent(UUID().uuidString)
            try Data(content.utf8).write(to: file)
            let source = try #require(zip_source_file(handle, file.path, 0, -1))
            #expect(zip_file_add(handle, raw(name), source, zip_flags_t(ZIP_FL_ENC_RAW)) >= 0)
        }
        #expect(zip_close(handle) == 0)
        #expect(Set(try ZipArchive.open(zip).tree.items.keys) == ["资料", "资料/说明.txt", "资料/子目录", "资料/子目录/数据.csv"])

        try ZipEditor.rename(archive: zip, path: "资料", to: "文档", trashOldVersion: false)

        let tree = try ZipArchive.open(zip).tree
        #expect(Set(tree.items.keys) == ["文档", "文档/说明.txt", "文档/子目录", "文档/子目录/数据.csv"])
        #expect(try contents(of: zip, "文档/说明.txt") == Data("说明".utf8))
        #expect(try contents(of: zip, "文档/子目录/数据.csv") == Data("1,2".utf8))
    }

    @Test func deletesFilesAndDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")

        let deleted = try ZipEditor.delete(archive: zip, paths: ["README.md", "config/deep"], trashOldVersion: false)

        // config/deep/ 目录条目与其中的大文件.bin
        #expect(deleted == 3)
        let tree = try ZipArchive.open(zip).tree
        #expect(tree.items["README.md"] == nil)
        #expect(tree.items["config/deep"] == nil)
        #expect(tree.items["config/deep/大文件.bin"] == nil)
        #expect(try contents(of: zip, "config/format.json") == Data("{}".utf8))
    }

    @Test func refusesDeletingEverything() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let roots = try ZipArchive.open(zip).tree.children[""] ?? []

        #expect(throws: ZipEditor.EditError.wouldBeEmpty) {
            try ZipEditor.delete(archive: zip, paths: roots, trashOldVersion: false)
        }
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    @Test func refusesNonZip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = try fixture.bsdtar("sample.tar.gz")
        #expect(throws: ZipEditor.EditError.notZip) {
            try ZipEditor.rename(archive: archive, path: "README.md", to: "x.md", trashOldVersion: false)
        }
    }

    /// 新建文件夹查重：同层、忽略大小写、Unicode 规范化；其他层的同名不算冲突
    @Test func siblingNamesDetectCollisions() throws {
        var tree = ArchiveTree()
        for (index, path) in ["Docs/", "Docs/caf\u{E9}.txt", "资料/", "其他/docs/"].enumerated() {
            tree.add(rawPath: path, isDirectory: path.hasSuffix("/"), entryIndex: index, size: nil, modified: nil, isEncrypted: false)
        }
        let root = try ZipEditor.SiblingNames(tree: tree, parent: "")
        #expect(throws: ZipEditor.EditError.nameExists("docs")) { try root.folderPath(for: "docs") }
        #expect(try root.folderPath(for: "新文件夹") == "新文件夹")
        let docs = try ZipEditor.SiblingNames(tree: tree, parent: "Docs")
        // NFD 形式的 café 与已有的 NFC 形式视为同名
        #expect(throws: ZipEditor.EditError.nameExists("cafe\u{301}.txt")) { try docs.folderPath(for: "cafe\u{301}.txt") }
        #expect(throws: ArchiveError.entryNotFound("不存在")) { try ZipEditor.SiblingNames(tree: tree, parent: "不存在") }

        // 10 万条目：建立一次集合 + 10 次查询
        var big = ArchiveTree()
        for index in 0..<100_000 {
            big.add(rawPath: "dir/f\(index).txt", isDirectory: false, entryIndex: index, size: 1, modified: nil, isEncrypted: false)
        }
        let start = ContinuousClock.now
        let names = try ZipEditor.SiblingNames(tree: big, parent: "dir")
        let built = ContinuousClock.now
        for attempt in 0..<10 { _ = try? names.folderPath(for: "新建 \(attempt)") }
        print("SIBLING build=\(built - start) query10=\(ContinuousClock.now - built)")
    }

    /// 删除与来源去重共用的祖先判断：a/b-x 不是 a/b 的后代（排序时它夹在 a/b 与 a/b/c 之间）
    @Test func ancestorLookupHandlesSimilarPrefixes() {
        let selected: Set<String> = ["a/b", "c"]
        #expect(ZipEditor.isSelfOrDescendant("a/b", of: selected))
        #expect(ZipEditor.isSelfOrDescendant("a/b/c/d.txt", of: selected))
        #expect(!ZipEditor.isSelfOrDescendant("a/b-x", of: selected))
        #expect(!ZipEditor.isSelfOrDescendant("a/b-x/c", of: selected))
        #expect(!ZipEditor.isSelfOrDescendant("a", of: selected))
        #expect(ZipEditor.isSelfOrDescendant("c/x", of: selected))
        // 绝对路径（拖入来源）
        #expect(ZipEditor.isSelfOrDescendant("/tmp/x/y", of: ["/tmp/x"]))
        #expect(!ZipEditor.isSelfOrDescendant("/tmp/xy", of: ["/tmp/x"]))
    }
}
