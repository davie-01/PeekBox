import Foundation
import Security
import Testing
@testable import PeekCore

/// 测试样本：content/ 下 README.md、config/format.json、config/deep/大文件.bin（600 KB）、empty/、.hidden
struct Fixture {
    let work: URL
    var content: URL { work.appendingPathComponent("content") }

    init() throws {
        let fm = FileManager.default
        work = fm.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID().uuidString)")
        try fm.createDirectory(at: content.appendingPathComponent("config/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: content.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: content.appendingPathComponent("README.md"))
        try Data("{}".utf8).write(to: content.appendingPathComponent("config/format.json"))
        try Data(repeating: 7, count: 600_000).write(to: content.appendingPathComponent("config/deep/大文件.bin"))
        try Data().write(to: content.appendingPathComponent(".hidden"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: work) }

    @discardableResult
    func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.currentDirectoryURL = directory ?? content
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// /usr/bin/zip；noDirEntries 时用 -D，不写目录条目
    func zip(_ name: String, extra: [String] = []) throws -> URL {
        let url = work.appendingPathComponent(name)
        #expect(try run("/usr/bin/zip", ["-q", "-r"] + extra + [url.path, "."]) == 0)
        return url
    }

    /// /usr/bin/tar（bsdtar）按扩展名自动选择格式：.tar.gz / .tar.xz / .7z
    func bsdtar(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        #expect(try run("/usr/bin/tar", ["-a", "-cf", url.path, "."]) == 0)
        return url
    }
}

@Suite struct ZipArchiveTests {
    @Test func indexesTreeAndHidesDotFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = ArchiveSource(rootURL: try fixture.zip("sample.zip"), showHidden: false)

        let root = try await source.children(of: nil)
        #expect(Set(root.map(\.name)) == ["README.md", "config", "empty"])
        let config = try #require(root.first { $0.name == "config" })
        let deep = try #require(try await source.children(of: config).first { $0.name == "deep" })
        let big = try #require(try await source.children(of: deep).first)
        #expect(big.name == "大文件.bin" && big.size == 600_000)
        #expect(source.loadedReader is ZipArchive)

        let withHidden = ArchiveSource(rootURL: source.rootURL, showHidden: true)
        #expect(try await withHidden.children(of: nil).contains { $0.name == ".hidden" })
    }

    @Test func infersDirectoriesWithoutDirectoryEntries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = try ZipArchive.open(try fixture.zip("nodirs.zip", extra: ["-D"]))
        let deep = try #require(archive.tree.items["config/deep"])
        #expect(deep.isDirectory && deep.entryIndex == nil)
        #expect(archive.tree.children["config/deep"] == ["config/deep/大文件.bin"])
    }

    @Test func extractsFileAndDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = try ZipArchive.open(try fixture.zip("sample.zip"))
        let readme = fixture.work.appendingPathComponent("README.md")
        try archive.extract(path: "README.md", to: readme, password: nil)
        #expect(try String(contentsOf: readme, encoding: .utf8) == "readme")

        let config = fixture.work.appendingPathComponent("config-out")
        try archive.extract(path: "config", to: config, password: nil)
        #expect(try Data(contentsOf: config.appendingPathComponent("deep/大文件.bin")) == Data(repeating: 7, count: 600_000))

        #expect(throws: ArchiveError.destinationExists("README.md")) {
            try archive.extract(path: "README.md", to: readme, password: nil)
        }
    }

    @Test func detectsCorruptedData() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.zip("sample.zip")
        var bytes = try Data(contentsOf: url)
        let header = try #require(bytes.range(of: Data("大文件.bin".utf8)))
        for offset in (header.upperBound + 200)..<(header.upperBound + 264) { bytes[offset] ^= 0xFF }
        try bytes.write(to: url)

        let archive = try ZipArchive.open(url)
        let target = fixture.work.appendingPathComponent("big.bin")
        #expect(throws: ArchiveError.self) {
            try archive.extract(path: "config/deep/大文件.bin", to: target, password: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func encryptedEntriesNeedCorrectPassword() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = try ZipArchive.open(try fixture.zip("locked.zip", extra: ["-P", "pass word"]))
        #expect(archive.tree.items["README.md"]?.isEncrypted == true)

        let target = fixture.work.appendingPathComponent("README.md")
        #expect(throws: ArchiveError.passwordRequired) {
            try archive.extract(path: "README.md", to: target, password: nil)
        }
        // 大文件的传统加密校验字节误判时会在 CRC 阶段暴露，同样应报密码错误
        #expect(throws: ArchiveError.wrongPassword) {
            try archive.extract(path: "config/deep/大文件.bin", to: target, password: "wrong")
        }
        try archive.extract(path: "README.md", to: target, password: "pass word")
        #expect(try String(contentsOf: target, encoding: .utf8) == "readme")
    }

    @Test func verifiesPasswordBeforeUnlocking() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = ArchiveSource(rootURL: try fixture.zip("locked.zip", extra: ["-P", "pass word"]), showHidden: false)
        _ = try await source.children(of: nil)

        await #expect(throws: ArchiveError.wrongPassword) { try await source.unlock(with: "wrong") }
        #expect(source.password == nil)
        try await source.unlock(with: "pass word")
        #expect(source.password == "pass word")
    }

    /// 单独预览分卷包时目录树与错误经 XPC 从后台服务传给扩展：编码往返后内容不变
    @Test func treeAndErrorsSurviveEncodingForBroker() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.zip("split.zip", extra: ["-s", "64k"])
        let tree = try ArchiveSource.openReader(url, password: nil).tree
        let decoded = try JSONDecoder().decode(ArchiveTree.self, from: JSONEncoder().encode(tree))
        #expect(decoded.items.count == tree.items.count)
        #expect(decoded.children == tree.children)
        for (path, item) in tree.items {
            let copy = try #require(decoded.items[path])
            #expect(copy.name == item.name && copy.isDirectory == item.isDirectory && copy.entryIndex == item.entryIndex
                    && copy.size == item.size && copy.modified == item.modified && copy.isEncrypted == item.isEncrypted)
        }
        for error in [ArchiveError.passwordRequired, .wrongPassword, .destinationExists("a.txt"), .failed("x")] {
            #expect(try JSONDecoder().decode(ArchiveError.self, from: JSONEncoder().encode(error)) == error)
        }
    }

    /// 分卷 ZIP：libzip 报多卷，回退 XADMaster；测试进程不在沙盒中，能读到其他卷
    @Test func splitZipFallsBackToXADMaster() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // 随机数据不可压缩，保证确实分出多卷
        var random = Data(count: 300_000)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 300_000, $0.baseAddress!) }
        try random.write(to: fixture.content.appendingPathComponent("random.bin"))
        let url = try fixture.zip("split.zip", extra: ["-s", "64k"])
        #expect(FileManager.default.fileExists(atPath: fixture.work.appendingPathComponent("split.z01").path))
        #expect(throws: ArchiveError.volumesUnreachable("split.zip")) { try ZipArchive.open(url) }
        // 末卷开头不是 PK 时同样应走 libzip 识别为分卷（实测 split.zip 开头为 83 9b f3 0f）
        var bytes = try Data(contentsOf: url)
        bytes[0] = 0x00
        let headless = fixture.work.appendingPathComponent("headless.zip")
        try bytes.write(to: headless)
        #expect(throws: ArchiveError.volumesUnreachable("headless.zip")) { try ArchiveSource.open(headless, password: nil) }

        let source = ArchiveSource(rootURL: url, showHidden: false)
        #expect(try await source.children(of: nil).contains { $0.name == "README.md" })
        #expect(source.loadedReader is XADArchive)
    }

    @Test func decodesNonUTF8Names() {
        let gbk: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4, 0x2E, 0x74, 0x78, 0x74] // "中文.txt"
        #expect(NameEncoding.decode(Data(gbk), as: NameEncoding.detect([Data(gbk)])) == "中文.txt")
        #expect(NameEncoding.decode(Data("普通.txt".utf8), as: NameEncoding.detect([Data("普通.txt".utf8)])) == "普通.txt")
    }
}

@Suite struct XADArchiveTests {
    @Test(arguments: ["sample.tar.gz", "sample.tar.xz", "sample.7z"])
    func browsesAndExtracts(name: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = ArchiveSource(rootURL: try fixture.bsdtar(name), showHidden: false)

        let root = try await source.children(of: nil)
        #expect(Set(root.map(\.name)).isSuperset(of: ["README.md", "config"]))
        #expect(source.loadedReader is XADArchive)

        let reader = try #require(source.loadedReader)
        let out = fixture.work.appendingPathComponent("out-\(name)")
        try reader.extract(path: "config", to: out, password: nil)
        #expect(try Data(contentsOf: out.appendingPathComponent("deep/大文件.bin")) == Data(repeating: 7, count: 600_000))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("format.json").path))
    }

    /// 文件名加密的 7z 只有 7zz 能生成。依次查找 PATH（如 `brew install sevenzip`）与仓库的 build/tools/7zz，都没有时相关用例跳过
    static let sevenZip: URL = {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("7zz")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../../build/tools/7zz").standardized
    }()

    /// ZIP64 条目声明解压大小 2^63（130 字节样本），曾在转换为 Int64 时使进程崩溃
    @Test func oversizedZip64EntryIsRejected() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/zip64_size_overflow.zip", withExtension: nil))
        #expect(throws: ArchiveError.self) { _ = try ZipArchive.open(url) }
        #expect([Int64.max, 1, 2].saturatingSum == .max)
    }

    /// 文件名加密的 RAR：RAR4 缺密码时 XAD 报 XADInputError，RAR5 报 XADPasswordError，都应识别为需要密码
    @Test(arguments: ["rar4_encrypted_filenames.rar", "rar5_encrypted_filenames.rar"])
    func headerEncryptedRarNeedsPassword(name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
        let source = ArchiveSource(rootURL: url, showHidden: false)
        await #expect(throws: ArchiveError.passwordRequired) { try await source.children(of: nil) }
        await #expect(throws: ArchiveError.wrongPassword) { try await source.unlock(with: "wrong") }
        #expect(source.password == nil)
        try await source.unlock(with: "password")
        #expect(try await source.children(of: nil).count > 0)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: sevenZip.path)))
    func headerEncrypted7zNeedsPassword() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.work.appendingPathComponent("locked.7z")
        #expect(try fixture.run(Self.sevenZip.path, ["a", "-t7z", "-ppass word", "-mhe=on", url.path, "."]) == 0)

        let source = ArchiveSource(rootURL: url, showHidden: false)
        await #expect(throws: ArchiveError.passwordRequired) { try await source.children(of: nil) }
        await #expect(throws: ArchiveError.wrongPassword) { try await source.unlock(with: "wrong") }
        #expect(source.password == nil)
        try await source.unlock(with: "pass word")
        #expect(try await source.children(of: nil).contains { $0.name == "README.md" && $0.isEncrypted })

        let target = fixture.work.appendingPathComponent("README.md")
        try source.loadedReader?.extract(path: "README.md", to: target, password: source.password)
        #expect(try String(contentsOf: target, encoding: .utf8) == "readme")
    }
}

@Suite struct VolumeInfoTests {
    @Test func detectsVolumeNames() {
        func detect(_ name: String) -> VolumeInfo? { VolumeInfo.detect(URL(fileURLWithPath: "/tmp/" + name)) }
        #expect(detect("a.7z.001") == .first)
        #expect(detect("a.7z.003") == .part(number: 3, firstName: "a.7z.001"))
        #expect(detect("a.part1.rar") == .first)
        #expect(detect("a.part02.rar") == .part(number: 2, firstName: "a.part01.rar"))
        #expect(detect("a.r00") == .part(number: 2, firstName: "a.rar"))
        #expect(detect("a.z01") == .part(number: 1, firstName: "a.zip"))
        #expect(detect("a.zip") == nil)
        #expect(detect("a.rar") == nil)
    }

    /// 单独预览时据第二卷能否读到决定是否交给后台服务
    @Test func locatesSecondVolume() {
        func second(_ name: String) -> String? { VolumeInfo.secondVolume(of: URL(fileURLWithPath: "/tmp/" + name))?.lastPathComponent }
        #expect(second("a.7z.001") == "a.7z.002")
        #expect(second("a.part1.rar") == "a.part2.rar")
        #expect(second("a.part01.rar") == "a.part02.rar")
        #expect(second("分卷.zip") == "分卷.z01")
        #expect(second("a.7z.002") == nil)
        #expect(second("a.rar") == nil)
    }

    @Test func middleVolumeIsRejectedWithHint() async throws {
        let source = ArchiveSource(rootURL: URL(fileURLWithPath: "/tmp/x.part2.rar"), showHidden: false)
        await #expect(throws: ArchiveError.notFirstVolume("x.part1.rar")) { try await source.children(of: nil) }
    }
}

@Suite struct FolderArchiveTests {
    /// 展开过的压缩包读取器不无限累积，超出上限时释放最久未用的（保留压缩包对象与密码）
    @Test func limitsLoadedArchiveReaders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.work.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<6 {
            _ = try fixture.zip("folder/a\(index).zip")
        }
        let source = FolderSource(rootURL: folder, showHidden: false)
        let entries = try await source.children(of: nil).filter(\.isArchive).sorted { $0.name < $1.name }
        #expect(entries.count == 6)
        for entry in entries { _ = try await source.children(of: entry) }
        let loaded = entries.compactMap { $0.fileURL }.filter { source.archiveSource(for: $0)?.loadedReader != nil }
        #expect(loaded.count <= 4)
        #expect(source.archiveSource(for: entries.last!.fileURL!)?.loadedReader != nil)
        // 被释放的仍可再次读取
        #expect(try await source.children(of: entries[0]).count > 0)
    }

    @Test func folderSourceExpandsArchives() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.zip("sample.zip")
        _ = try fixture.bsdtar("sample.7z")
        let folder = FolderSource(rootURL: fixture.work, showHidden: false)
        let listed = try await folder.children(of: nil)

        for name in ["sample.zip", "sample.7z"] {
            let archive = try #require(listed.first { $0.name == name })
            #expect(archive.isArchive && archive.isExpandable && !archive.isDirectory)
            let inside = try await folder.children(of: archive)
            #expect(Set(inside.map(\.name)).isSuperset(of: ["README.md", "config"]))
            let archiveURL = try #require(archive.fileURL)
            #expect(inside.allSatisfy { $0.archiveURL == archiveURL && $0.fileURL == nil })
            #expect(folder.archiveSource(for: archiveURL)?.loadedReader != nil)
        }
    }
}
