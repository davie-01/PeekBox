import CLibzip
import CryptoKit
import Foundation
import Testing
@testable import PeekCore

/// 格式矩阵：同一份参考内容用各种工具打包，逐个核对目录结构与每个文件的内容。
/// 7zz 的查找位置见 XADArchiveTests.sevenZip，找不到时相关用例跳过。
@Suite struct FormatMatrixTests {
    static let sevenZip = XADArchiveTests.sevenZip.path
    static var hasSevenZip: Bool { FileManager.default.isExecutableFile(atPath: sevenZip) }

    /// 参考内容：中文 / emoji / 空格与括号文件名、多层目录、空目录、空文件、不可压缩与高度可压缩数据
    struct Reference {
        let root: URL
        let files: [String: Data]
        let emptyDirectories: Set<String> = ["空目录"]

        init(in work: URL) throws {
            root = work.appendingPathComponent("reference")
            var random = Data(count: 1 << 20)
            _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            files = [
                "说明.txt": Data("PeekBox 格式矩阵\n".utf8),
                "文档/报告 2026.md": Data(String(repeating: "# 标题\n内容\n", count: 200).utf8),
                "文档/草稿/初稿 (1).txt": Data("草稿".utf8),
                "数据/random.bin": random,
                "数据/zeros.bin": Data(count: 2 << 20),
                "emoji 😀.txt": Data("😀".utf8),
                "空文件.txt": Data(),
                "a/b/c/d/e/深层.txt": Data("deep".utf8),
            ]
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            for (path, data) in files {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
    }

    enum Maker: String, CaseIterable, CustomTestStringConvertible {
        case zipInfoZip, zipNoDirEntries, zipDitto, zipBsdtar, zipCrypto, zipAES, zipSplit
        case tar, tarGz, tarBz2, tarXz
        case sevenZBsdtar, sevenZSolid, sevenZNonSolid, sevenZEncrypted, sevenZHeaderEncrypted, sevenZVolumes

        var testDescription: String { rawValue }
        var needsSevenZip: Bool { [.zipAES, .sevenZSolid, .sevenZNonSolid, .sevenZEncrypted, .sevenZHeaderEncrypted, .sevenZVolumes].contains(self) }
        var password: String? { [.zipCrypto, .zipAES, .sevenZEncrypted, .sevenZHeaderEncrypted].contains(self) ? "pass word" : nil }
        /// 内容未加密时目录结构可直接读；文件名加密时需先给密码
        var headerEncrypted: Bool { self == .sevenZHeaderEncrypted }
        /// zip -D 不写目录条目，空目录无从保存
        var keepsEmptyDirectories: Bool { self != .zipNoDirEntries }

        /// 生成压缩包，返回要打开的那个文件（分卷为第一卷 / 入口卷）
        func make(_ reference: Reference, in work: URL) throws -> URL {
            let src = reference.root
            func run(_ tool: String, _ arguments: [String]) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.currentDirectoryURL = src
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ArchiveError.failed("\(tool) \(arguments) 退出码 \(process.terminationStatus)")
                }
            }
            let out = { (name: String) in work.appendingPathComponent(name) }
            let sz = FormatMatrixTests.sevenZip
            switch self {
            case .zipInfoZip: try run("/usr/bin/zip", ["-q", "-r", out("a.zip").path, "."]); return out("a.zip")
            case .zipNoDirEntries: try run("/usr/bin/zip", ["-q", "-r", "-D", out("a.zip").path, "."]); return out("a.zip")
            case .zipDitto: try run("/usr/bin/ditto", ["-c", "-k", ".", out("a.zip").path]); return out("a.zip")
            case .zipBsdtar: try run("/usr/bin/bsdtar", ["-a", "-cf", out("a.zip").path, "."]); return out("a.zip")
            case .zipCrypto: try run("/usr/bin/zip", ["-q", "-r", "-P", "pass word", out("a.zip").path, "."]); return out("a.zip")
            case .zipAES: try run(sz, ["a", "-tzip", "-mem=AES256", "-ppass word", out("a.zip").path, "."]); return out("a.zip")
            case .zipSplit: try run("/usr/bin/zip", ["-q", "-r", "-s", "500k", out("a.zip").path, "."]); return out("a.zip")
            case .tar: try run("/usr/bin/bsdtar", ["-cf", out("a.tar").path, "."]); return out("a.tar")
            case .tarGz: try run("/usr/bin/bsdtar", ["-a", "-cf", out("a.tar.gz").path, "."]); return out("a.tar.gz")
            case .tarBz2: try run("/usr/bin/bsdtar", ["-a", "-cf", out("a.tar.bz2").path, "."]); return out("a.tar.bz2")
            case .tarXz: try run("/usr/bin/bsdtar", ["-a", "-cf", out("a.tar.xz").path, "."]); return out("a.tar.xz")
            case .sevenZBsdtar: try run("/usr/bin/bsdtar", ["-a", "-cf", out("a.7z").path, "."]); return out("a.7z")
            case .sevenZSolid: try run(sz, ["a", "-t7z", "-ms=on", out("a.7z").path, "."]); return out("a.7z")
            case .sevenZNonSolid: try run(sz, ["a", "-t7z", "-ms=off", out("a.7z").path, "."]); return out("a.7z")
            case .sevenZEncrypted: try run(sz, ["a", "-t7z", "-ppass word", out("a.7z").path, "."]); return out("a.7z")
            case .sevenZHeaderEncrypted: try run(sz, ["a", "-t7z", "-ppass word", "-mhe=on", out("a.7z").path, "."]); return out("a.7z")
            case .sevenZVolumes: try run(sz, ["a", "-t7z", "-v500k", out("a.7z").path, "."]); return out("a.7z.001")
            }
        }
    }

    @Test(arguments: Maker.allCases)
    func readsAndExtractsEverything(maker: Maker) async throws {
        guard !maker.needsSevenZip || Self.hasSevenZip else { return }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reference = try Reference(in: fixture.work)
        let archive = try maker.make(reference, in: fixture.work)

        let source = ArchiveSource(rootURL: archive, showHidden: true)
        if let password = maker.password {
            if maker.headerEncrypted {
                await #expect(throws: ArchiveError.passwordRequired) { _ = try await source.reader() }
            }
            try await source.unlock(with: password)
        }
        let reader = try await source.reader()
        try Self.verify(reader, against: reference, password: source.password, in: fixture.work,
                        checkEmptyDirectories: maker.keepsEmptyDirectories)
    }

    /// 目录结构与参考一致（忽略 macOS 元数据目录），每个文件逐字节一致
    static func verify(_ reader: any ArchiveReader, against reference: Reference, password: String?, in work: URL,
                       checkEmptyDirectories: Bool = true) throws {
        let items = reader.tree.items.values.filter { !$0.path.hasPrefix("__MACOSX") && !$0.path.hasSuffix(".DS_Store") }
        let files = Set(items.filter { !$0.isDirectory }.map(\.path))
        #expect(files == Set(reference.files.keys),
                "多出 \(files.subtracting(reference.files.keys).sorted())，缺少 \(Set(reference.files.keys).subtracting(files).sorted())")
        for directory in reference.emptyDirectories where checkEmptyDirectories {
            #expect(reader.tree.items[directory]?.isDirectory == true, "缺少空目录 \(directory)")
        }
        let out = work.appendingPathComponent("extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (path, expected) in reference.files {
            guard let item = reader.tree.items[path] else { continue }
            let target = out.appendingPathComponent(UUID().uuidString)
            try reader.extractFile(item, to: target, password: password)
            let actual = try Data(contentsOf: target)
            #expect(actual.count == expected.count && SHA256.hash(data: actual) == SHA256.hash(data: expected),
                    "内容不一致：\(path)")
        }
    }

    // MARK: - 单文件压缩流

    @Test(arguments: ["gz", "bz2"])
    func singleFileStream(ext: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let text = Data(String(repeating: "单文件压缩流\n", count: 1000).utf8)
        let plain = fixture.work.appendingPathComponent("日志.txt")
        try text.write(to: plain)
        let tool = ext == "gz" ? "/usr/bin/gzip" : "/usr/bin/bzip2"
        #expect(try fixture.run(tool, ["-k", plain.path], in: fixture.work) == 0)
        let source = ArchiveSource(rootURL: fixture.work.appendingPathComponent("日志.txt.\(ext)"), showHidden: false)
        let reader = try await source.reader()
        let files = reader.tree.items.values.filter { !$0.isDirectory }
        #expect(files.count == 1)
        let target = fixture.work.appendingPathComponent("out")
        try reader.extractFile(try #require(files.first), to: target, password: nil)
        #expect(try Data(contentsOf: target) == text)
    }

    // MARK: - RAR（无法在本机生成，使用 libarchive 测试集样本）

    @Test(arguments: ["rar5_compressed.rar", "rar5_multiarchive.part01.rar"])
    func rarExtractsAllEntries(name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
        let source = ArchiveSource(rootURL: url, showHidden: true)
        let reader = try await source.reader()
        let files = reader.tree.items.values.filter { !$0.isDirectory && !$0.isSpecial }
        #expect(!files.isEmpty)
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // XAD 解压时校验 CRC，校验失败会抛错
        for item in files {
            let target = fixture.work.appendingPathComponent(UUID().uuidString)
            try reader.extractFile(item, to: target, password: nil)
            #expect(Int64((try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -1) == item.size,
                    "大小不符：\(item.path)")
        }
    }

    // MARK: - 文件名编码（ZIP 无 UTF-8 标志、按本地编码存放的文件名）

    @Test(arguments: [
        ("GB18030", ["资料/说明.txt", "资料/年度报告.docx", "图片/现场照片.jpg"]),
        ("Shift_JIS", ["資料/説明書.txt", "日本語のファイル.txt", "写真/東京タワー.jpg"]),
        ("Big5", ["資料/說明.txt", "繁體中文檔案.txt", "圖片/照片.jpg"]),
    ])
    func decodesLegacyZipNames(encoding: String, names: [String]) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
        let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        let zip = fixture.work.appendingPathComponent("legacy.zip")
        var code: Int32 = 0
        let handle = try #require(zip_open(zip.path, ZIP_CREATE | ZIP_EXCL, &code))
        for name in names {
            let raw = (Array(name.data(using: stringEncoding)!) + [0]).map { CChar(bitPattern: $0) }
            let file = fixture.work.appendingPathComponent(UUID().uuidString)
            try Data(name.utf8).write(to: file)
            let source = try #require(zip_source_file(handle, file.path, 0, -1))
            #expect(zip_file_add(handle, raw, source, zip_flags_t(ZIP_FL_ENC_RAW)) >= 0)
        }
        #expect(zip_close(handle) == 0)

        let tree = try ZipArchive.open(zip).tree
        let decoded = Set(tree.items.values.filter { !$0.isDirectory }.map(\.path))
        #expect(decoded == Set(names), "\(encoding) 解码为 \(decoded.sorted())")
    }
}
