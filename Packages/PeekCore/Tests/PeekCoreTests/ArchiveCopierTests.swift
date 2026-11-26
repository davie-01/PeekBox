import Foundation
import Testing
@testable import PeekCore

/// 从镜像拷到真实文件夹（安装盘把 App 拖到"应用程序"）：符号链接重建、隔离属性继承、同名处理、失败不留残余
@Suite(.serialized) struct ArchiveCopierTests {
    /// 带 framework 符号链接的 App：Demo.app/Contents/Frameworks/Kit.framework/{Kit → Versions/Current/Kit, Versions/Current → A}
    static func makeImage(in fixture: Fixture, quarantine: String? = nil) throws -> URL {
        let fm = FileManager.default
        let framework = fixture.content.appendingPathComponent("Demo.app/Contents/Frameworks/Kit.framework")
        try fm.createDirectory(at: framework.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try Data("kit".utf8).write(to: framework.appendingPathComponent("Versions/A/Kit"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Kit").path, withDestinationPath: "Versions/Current/Kit")
        try Data("main".utf8).write(to: fixture.content.appendingPathComponent("Demo.app/Contents/Info.plist"))
        let image = fixture.work.appendingPathComponent("demo.dmg")
        #expect(try DiskImageTests.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                            "-fs", "HFS+", "-format", "UDZO", image.path]) == 0)
        if let quarantine {
            #expect(setxattr(image.path, Quarantine.key, quarantine, quarantine.utf8.count, 0, 0) == 0)
        }
        return image
    }

    /// 测试不动用户的废纸篓
    static func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    static func destination(in fixture: Fixture) throws -> URL {
        let url = fixture.work.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copiesAppWithSymlinksAndQuarantine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let quarantine = "0081;6745a1b2;Safari;"
        let image = try Self.makeImage(in: fixture, quarantine: quarantine)
        let destination = try Self.destination(in: fixture)
        let reader = try SevenZipArchive.open(image)

        let summary = try ArchiveCopier.copy(reader: reader, archive: image, paths: ["Demo.app"], to: destination,
                                             password: nil, control: ZipWriteControl(), trash: Self.remove) { _ in .init(.cancel) }
        #expect(summary.added == 1 && summary.replaced == 0)
        let app = destination.appendingPathComponent("Demo.app")
        let framework = app.appendingPathComponent("Contents/Frameworks/Kit.framework")
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path) == "A")
        #expect(try String(contentsOf: framework.appendingPathComponent("Kit"), encoding: .utf8) == "kit")
        // 隔离属性：App 本身与其中的文件都继承
        for url in [app, app.appendingPathComponent("Contents/Info.plist")] {
            let value = Quarantine.rawValue(of: url).map { String(decoding: $0, as: UTF8.self) }
            #expect(value == quarantine, "\(url.lastPathComponent)")
        }
        // 暂存目录已清理
        #expect(try fm.contentsOfDirectory(atPath: destination.path) == ["Demo.app"])
    }

    @Test func conflictReplaceMovesOldToTrashAndKeepBothRenames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = try Self.makeImage(in: fixture)
        let destination = try Self.destination(in: fixture)
        let reader = try SevenZipArchive.open(image)
        let fm = FileManager.default
        let existing = destination.appendingPathComponent("Demo.app")
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existing.appendingPathComponent("marker"))

        var asked: [ZipEditor.ImportConflict] = []
        let keepBoth = try ArchiveCopier.copy(reader: reader, archive: image, paths: ["Demo.app"], to: destination,
                                              password: nil, control: ZipWriteControl(), trash: Self.remove) { asked.append($0); return .init(.keepBoth) }
        #expect(asked.count == 1 && asked[0].path == "Demo.app" && asked[0].existingIsDirectory)
        #expect(keepBoth.added == 1)
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("Demo 2.app/Contents/Info.plist").path))
        #expect(fm.fileExists(atPath: existing.appendingPathComponent("marker").path))

        let replace = try ArchiveCopier.copy(reader: reader, archive: image, paths: ["Demo.app"], to: destination,
                                             password: nil, control: ZipWriteControl(), trash: Self.remove) { _ in .init(.replace) }
        #expect(replace.replaced == 1)
        #expect(!fm.fileExists(atPath: existing.appendingPathComponent("marker").path))
        #expect(fm.fileExists(atPath: existing.appendingPathComponent("Contents/Info.plist").path))

        #expect(throws: ZipEditor.EditError.cancelled) {
            _ = try ArchiveCopier.copy(reader: reader, archive: image, paths: ["Demo.app"], to: destination,
                                       password: nil, control: ZipWriteControl(), trash: Self.remove) { _ in .init(.cancel) }
        }
        #expect(Set(try fm.contentsOfDirectory(atPath: destination.path)) == ["Demo.app", "Demo 2.app"])
    }

    /// 扩展属性（非 Mach-O 文件的代码签名就存在 com.apple.cs.* 里）随文件写回；镜像内文件自带的隔离属性不带出
    @Test(arguments: ["HFS+", "APFS"])
    func extendedAttributesAreRestored(fs: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.content.appendingPathComponent("README.md")
        let signature = Data((0..<200).map { UInt8($0) })
        #expect(signature.withUnsafeBytes { setxattr(file.path, "com.apple.cs.CodeDirectory", $0.baseAddress, signature.count, 0, 0) } == 0)
        #expect(setxattr(file.path, Quarantine.key, "0081;0;x;", 9, 0, 0) == 0)
        let image = fixture.work.appendingPathComponent("attrs.dmg")
        #expect(try DiskImageTests.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                            "-fs", fs, "-format", "UDZO", image.path]) == 0)
        let reader = try SevenZipArchive.open(image)
        let target = fixture.work.appendingPathComponent("out.md")
        try reader.extractFile(try #require(reader.tree.items["README.md"]), to: target, password: nil)

        let length = getxattr(target.path, "com.apple.cs.CodeDirectory", nil, 0, 0, 0)
        var restored = Data(count: max(length, 0))
        _ = restored.withUnsafeMutableBytes { getxattr(target.path, "com.apple.cs.CodeDirectory", $0.baseAddress, length, 0, 0) }
        #expect(restored == signature)
        #expect(Quarantine.rawValue(of: target) == nil)
        #expect(try Data(contentsOf: target) == Data("readme".utf8))
    }

    /// 符号链接 a → 外部目录之后，a/ 下的链接不会创建到外部目录里
    @Test func symlinkCannotRedirectLaterLinksOutside() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.work.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var tree = ArchiveTree()
        tree.add(rawPath: "pkg", isDirectory: true, entryIndex: nil, size: nil, modified: nil, isEncrypted: false)
        tree.add(rawPath: "pkg/a", isDirectory: false, entryIndex: 0, size: 0, modified: nil, isEncrypted: false,
                 isSpecial: true, linkTarget: outside.path)
        tree.add(rawPath: "pkg/a/evil", isDirectory: false, entryIndex: 1, size: 0, modified: nil, isEncrypted: false,
                 isSpecial: true, linkTarget: "/tmp")
        let reader = TreeOnlyReader(tree: tree)
        let target = fixture.work.appendingPathComponent("out")
        try reader.extract(path: "pkg", to: target, password: nil)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil").path))
    }
}

/// 只有目录树、没有文件内容的读取器（测试符号链接处理）
private struct TreeOnlyReader: ArchiveReader {
    let tree: ArchiveTree
    func extractFile(_ item: ArchiveTree.Item, to destination: URL, password: String?) throws {
        try Data().write(to: destination)
    }
}
