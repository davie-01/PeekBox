import Foundation
import Testing
@testable import PeekCore

/// 缓存失效竞态与压缩包被外部替换后的提取
@Suite struct ArchiveConsistencyTests {
    /// 含 fresh0.txt … fresh9.txt（内容均为 "fresh"）的压缩包：条目数不少于样本包，
    /// 旧目录树里的条目索引在新包中仍然有效，修复前会"成功"提取出新包的内容
    private func freshZip(_ fixture: Fixture) throws -> URL {
        let directory = fixture.work.appendingPathComponent("fresh-src")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (0..<10).map { "fresh\($0).txt" }
        for name in names { try Data("fresh".utf8).write(to: directory.appendingPathComponent(name)) }
        let url = fixture.work.appendingPathComponent("fresh.zip")
        #expect(try fixture.run("/usr/bin/zip", ["-q", url.path] + names, in: directory) == 0)
        return url
    }

    /// 用 Python 快速写出条目很多的压缩包（解析需要较长时间）
    private func bigZip(_ fixture: Fixture, entries: Int) throws -> URL {
        let url = fixture.work.appendingPathComponent("big.zip")
        let script = """
        import sys, zipfile
        with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_STORED) as z:
            for i in range(int(sys.argv[2])):
                z.writestr("dir/f%06d.txt" % i, "x")
        """
        #expect(try fixture.run("/usr/bin/python3", ["-I", "-c", script, url.path, String(entries)]) == 0)
        return url
    }

    @Test func extractionRejectsReplacedArchive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let reader = try ZipArchive.open(zip)
        let item = try #require(reader.tree.items["README.md"])

        // 换成另一个包：旧索引在新包里指向别的条目，不能读出新包的内容
        _ = try FileManager.default.replaceItemAt(zip, withItemAt: try freshZip(fixture))
        let target = fixture.work.appendingPathComponent("out.md")
        #expect(throws: ArchiveError.archiveChanged) { try reader.extractFile(item, to: target, password: nil) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func extractionRejectsRewrittenArchive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let reader = try ZipArchive.open(zip)
        let item = try #require(reader.tree.items["README.md"])

        // 同一个文件被就地改写（inode 不变，大小变化）
        let handle = try FileHandle(forWritingTo: zip)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(throws: ArchiveError.archiveChanged) {
            try reader.extractFile(item, to: fixture.work.appendingPathComponent("out.md"), password: nil)
        }
    }

    @Test func staleLoadDoesNotOverwriteNewerReader() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try bigZip(fixture, entries: 80_000)
        let source = ArchiveSource(rootURL: url, showHidden: false)

        // 大包读取进行中时，文件被换成小包并失效
        let slow = Task { try await source.reader() }
        try await Task.sleep(for: .milliseconds(30))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: try freshZip(fixture))
        source.invalidate()
        let fresh = try await source.reader()
        #expect(fresh.tree.items["fresh0.txt"] != nil)

        // 旧读取后完成：不能把过期的大目录树写回缓存
        let late = try await slow.value
        #expect(late.tree.items["fresh0.txt"] != nil)
        #expect(source.loadedReader?.tree.items.count == 10)
    }

    /// 预览窗口据此判断压缩包是否需要重新读取（写入期间关闭再打开预览、其他程序修改压缩包）
    @Test func detectsArchiveReplacedAfterLoading() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let source = ArchiveSource(rootURL: zip, showHidden: false)
        #expect(!source.hasChangedOnDisk)
        _ = try await source.reader()
        #expect(!source.hasChangedOnDisk)

        _ = try FileManager.default.replaceItemAt(zip, withItemAt: try freshZip(fixture))
        #expect(source.hasChangedOnDisk)

        source.invalidate()
        #expect(!source.hasChangedOnDisk)
        #expect(try await source.reader().tree.items["fresh0.txt"] != nil)
        #expect(!source.hasChangedOnDisk)
    }
}
