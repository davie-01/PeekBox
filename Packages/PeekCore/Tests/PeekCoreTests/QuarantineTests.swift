import Foundation
import Testing
@testable import PeekCore

/// 提取出的项目继承压缩包的隔离属性（拖出、打开、拷贝、拷进"应用程序"共用）
@Suite struct QuarantineTests {
    static let value = "0083;6aec476b;Safari;41E17B3C-16F7-403F-8CE6-1D8D071D6CE2"

    @Test(arguments: ["zip", "tar.gz", "dmg"])
    func extractedItemsInheritArchiveQuarantine(format: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // 指向外部文件的符号链接：外部文件不应被改动
        let outside = fixture.work.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: fixture.content.appendingPathComponent("config/link").path,
                                                   withDestinationPath: outside.path)
        let archive: URL
        switch format {
        case "zip": archive = try fixture.zip("q.zip", extra: ["-y"])
        case "tar.gz": archive = try fixture.bsdtar("q.tar.gz")
        default:
            archive = fixture.work.appendingPathComponent("q.dmg")
            #expect(try DiskImageTests.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                                "-fs", "HFS+", "-format", "UDZO", archive.path]) == 0)
        }
        #expect(setxattr(archive.path, Quarantine.key, Self.value, Self.value.utf8.count, 0, 0) == 0)

        let reader = try ArchiveSource.openReader(archive, password: nil)
        let out = fixture.work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = out.appendingPathComponent("config")
        let file = out.appendingPathComponent("README.md")
        try reader.extract(path: "config", to: folder, password: nil)
        try reader.extract(path: "README.md", to: file, password: nil)
        Quarantine.inherit(from: archive, to: [folder, file])

        for url in [folder, folder.appendingPathComponent("deep"), folder.appendingPathComponent("deep/大文件.bin"), file] {
            #expect(Quarantine.rawValue(of: url).map { String(decoding: $0, as: UTF8.self) } == Self.value, "\(url.lastPathComponent)")
        }
        #expect(Quarantine.rawValue(of: outside) == nil)
    }

    @Test func unquarantinedArchiveLeavesItemsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = try fixture.zip("plain.zip")
        let target = fixture.work.appendingPathComponent("README.md")
        try ArchiveSource.openReader(archive, password: nil).extract(path: "README.md", to: target, password: nil)
        Quarantine.inherit(from: archive, to: [target])
        #expect(Quarantine.rawValue(of: target) == nil)
    }
}
