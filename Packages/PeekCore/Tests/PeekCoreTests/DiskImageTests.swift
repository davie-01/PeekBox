import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PeekCore

/// 磁盘镜像：用 hdiutil 把格式矩阵的参考内容做成各种 DMG / ISO，经 ArchiveSource 打开（应选中 7-Zip），
/// 核对目录结构并逐个提取比对内容。hdiutil 只用 create / makehybrid，不挂载
@Suite(.serialized) struct DiskImageTests {
    enum Maker: String, CaseIterable, CustomTestStringConvertible {
        case hfsUDZO, hfsUDBZ, hfsULFO, hfsULMO, hfsUDRO, apfsUDZO, apfsULFO, fat32, isoJoliet, isoHybrid, udf, udfISO

        var testDescription: String { rawValue }

        /// 期望的格式链
        var format: String {
            switch self {
            case .hfsUDZO, .hfsUDBZ, .hfsULFO, .hfsULMO, .hfsUDRO: "Dmg > HFS"
            case .apfsUDZO, .apfsULFO: "Dmg > APFS"
            case .fat32: "Dmg > FAT"
            case .isoJoliet, .isoHybrid: "Iso"
            // 同时带 UDF 与 ISO 9660 时优先 UDF（ISO 9660 放不下 4 GB 以上的文件）
            case .udf, .udfISO: "Udf"
            }
        }

        func make(from source: URL, in work: URL) throws -> URL {
            func hdiutil(_ arguments: [String]) throws {
                #expect(try DiskImageTests.run("/usr/bin/hdiutil", arguments) == 0, "hdiutil \(arguments.first ?? "")")
            }
            func create(fs: String, format: String) throws -> URL {
                let url = work.appendingPathComponent("\(rawValue).dmg")
                try hdiutil(["create", "-quiet", "-ov", "-srcfolder", source.path, "-fs", fs, "-format", format,
                             "-volname", "PeekBox 测试", url.path])
                return url
            }
            switch self {
            case .hfsUDZO: return try create(fs: "HFS+", format: "UDZO")
            case .hfsUDBZ: return try create(fs: "HFS+", format: "UDBZ")
            case .hfsULFO: return try create(fs: "HFS+", format: "ULFO")
            case .hfsULMO: return try create(fs: "HFS+", format: "ULMO")
            case .hfsUDRO: return try create(fs: "HFS+", format: "UDRO")
            case .apfsUDZO: return try create(fs: "APFS", format: "UDZO")
            case .apfsULFO: return try create(fs: "APFS", format: "ULFO")
            case .fat32: return try create(fs: "MS-DOS FAT32", format: "UDRO")
            case .isoJoliet, .isoHybrid, .udf, .udfISO:
                let url = work.appendingPathComponent("\(rawValue).iso")
                let filesystems = switch self {
                case .isoJoliet: ["-iso", "-joliet"]
                case .udf: ["-udf"]
                case .udfISO: ["-udf", "-iso", "-joliet"]
                default: ["-hfs", "-iso", "-joliet"]
                }
                try hdiutil(["makehybrid", "-quiet", "-o", url.path] + filesystems + [source.path])
                return url
            }
        }
    }

    @Test(arguments: Maker.allCases)
    func readsAndExtractsEverything(maker: Maker) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reference = try FormatMatrixTests.Reference(in: fixture.work)
        let image = try maker.make(from: reference.root, in: fixture.work)

        let reader = try await ArchiveSource(rootURL: image, showHidden: true).reader()
        let archive = try #require(reader as? SevenZipArchive, "应由 7-Zip 读取")
        #expect(archive.formatName == maker.format)
        if maker.format == "Dmg > HFS" { #expect(archive.volumeName == "PeekBox 测试") }

        // 卷根目录下的系统目录（.fseventsd、.Trashes 等）不在参考内容中
        let items = reader.tree.items.values.filter { !$0.path.hasPrefix(".") }
        let files = Set(items.filter { !$0.isDirectory }.map(\.path))
        #expect(files == Set(reference.files.keys),
                "多出 \(files.subtracting(reference.files.keys).sorted())，缺少 \(Set(reference.files.keys).subtracting(files).sorted())")
        #expect(reader.tree.items["空目录"]?.isDirectory == true)

        let out = fixture.work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (path, expected) in reference.files {
            let item = try #require(reader.tree.items[path])
            let target = out.appendingPathComponent(UUID().uuidString)
            try reader.extractFile(item, to: target, password: nil)
            let actual = try Data(contentsOf: target)
            #expect(SHA256.hash(data: actual) == SHA256.hash(data: expected), "内容不一致：\(path)")
        }

        // 目录整体提取走批量接口
        let folder = out.appendingPathComponent("文档")
        try reader.extract(path: "文档", to: folder, password: nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("草稿/初稿 (1).txt")) == reference.files["文档/草稿/初稿 (1).txt"])
    }

    @Test func symlinkIsShownButNotExtracted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(atPath: fixture.content.appendingPathComponent("link").path,
                                                   withDestinationPath: "README.md")
        let image = fixture.work.appendingPathComponent("link.dmg")
        #expect(try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                   "-fs", "HFS+", "-format", "UDZO", image.path]) == 0)
        let reader = try SevenZipArchive.open(image)
        #expect(reader.tree.items["link"]?.isSpecial == true)
        #expect(reader.tree.items["link"]?.linkTarget == "README.md")
        #expect(reader.tree.items["README.md"]?.isSpecial == false)
        // HFS+ 私有目录（硬链接数据）不显示
        #expect(!reader.tree.items.keys.contains { $0.contains("HFS+ Private") })
    }

    /// 安装盘常见的布局：卷根目录带扩展属性（com.apple.provenance）、一个名为空格的替身指向 /Applications。
    /// 卷根上的扩展属性流路径为 "卷名:属性名"、不在卷根之下，曾导致卷名层没去掉、HFS+ 私有目录露出来。
    /// hdiutil -srcfolder 不会把扩展属性写到卷根，样本是挂载可写镜像后制作的（Fixtures/installer-layout.dmg，
    /// 卷名"安装"，含 README.md、App.app/bin 与名为空格的替身）
    @Test func installerLayoutShowsVolumeContents() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/installer-layout.dmg", withExtension: nil))
        let reader = try SevenZipArchive.open(url)
        #expect(reader.formatName == "Dmg > HFS")
        #expect(reader.volumeName == "安装")
        #expect(Set(reader.tree.children[""] ?? []) == [" ", "README.md", "App.app"])
        #expect(reader.tree.items[" "]?.isSpecial == true)
        #expect(reader.tree.items[" "]?.linkTarget == "/Applications")
        #expect(reader.tree.items["App.app/bin"]?.size == 4)
    }

    /// 应用包按 Finder 的习惯显示：不展开、显示总大小与应用种类，图标取包内的 .icns
    @Test func applicationBundleIsShownAsOneItem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let app = fixture.content.appendingPathComponent("Demo.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIconFile": "Demo"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        let icns = try Data(contentsOf: URL(fileURLWithPath:
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns"))
        try icns.write(to: app.appendingPathComponent("Resources/Demo.icns"))
        try Data(count: 1000).write(to: app.appendingPathComponent("MacOS/Demo"))
        let image = fixture.work.appendingPathComponent("app.dmg")
        #expect(try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                   "-fs", "HFS+", "-format", "UDZO", image.path]) == 0)

        let source = ArchiveSource(rootURL: image, showHidden: false)
        let demo = try #require(try await source.children(of: nil).first { $0.name == "Demo.app" })
        #expect(demo.isPackage && !demo.isExpandable && !demo.isFolderLike)
        #expect(demo.size == Int64(plist.count + icns.count + 1000))
        #expect(demo.kind == UTType(filenameExtension: "app", conformingTo: .directory)?.localizedDescription)
        #expect(await source.bundleIconData(for: demo) == icns)
    }

    @Test func fatVolumeLabelIsReported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = fixture.work.appendingPathComponent("fat.dmg")
        #expect(try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                   "-fs", "MS-DOS FAT32", "-volname", "PEEKBOX", "-format", "UDRO",
                                                   image.path]) == 0)
        #expect(try SevenZipArchive.open(image).volumeName == "PEEKBOX")
    }

    /// 7-Zip 的 UDF 遇到符号链接条目会拒绝整个镜像（已打补丁，见 SevenZipBridge/patches）
    @Test func udfWithSymlinkOpens() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(atPath: fixture.content.appendingPathComponent("link").path,
                                                   withDestinationPath: "README.md")
        let image = fixture.work.appendingPathComponent("udf.iso")
        #expect(try Self.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-udf", "-o", image.path,
                                                   fixture.content.path]) == 0)
        let reader = try SevenZipArchive.open(image)
        #expect(reader.formatName == "Udf")
        #expect(reader.tree.items["link"]?.isSpecial == true)
        #expect(reader.tree.items["config/deep/大文件.bin"]?.size == 600_000)
    }

    @Test func encryptedImageIsReportedAsUnsupported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = fixture.work.appendingPathComponent("encrypted.dmg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-srcfolder", fixture.content.path, "-fs", "APFS",
                             "-encryption", "AES-128", "-stdinpass", image.path]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("secret".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(throws: ArchiveError.failed(String(localized: "这是加密的磁盘镜像，暂不支持预览", bundle: CoreStrings.bundle))) {
            _ = try SevenZipArchive.open(image)
        }
    }

    /// 7-Zip 没有 exFAT：分区以原始分区文件列出，仍可整体提取
    @Test func unknownFileSystemIsListedAsRawPartition() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = fixture.work.appendingPathComponent("exfat.dmg")
        #expect(try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                   "-fs", "ExFAT", "-format", "UDRO", image.path]) == 0)
        let reader = try SevenZipArchive.open(image)
        let files = reader.tree.items.values.filter { !$0.isDirectory }
        #expect(files.count == 1)
        let partition = try #require(files.first)
        // 按签名认出 exFAT，以磁盘映像文件命名，拖出后可在 Finder 中挂载
        #expect(partition.path == String(localized: "分区 1（exFAT）.img", bundle: CoreStrings.bundle))
        let target = fixture.work.appendingPathComponent("partition.img")
        try reader.extractFile(partition, to: target, password: nil)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64 == partition.size)
    }

    @Test func detectsDiskImageBySignature() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = fixture.work.appendingPathComponent("image.dmg")
        #expect(try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", fixture.content.path,
                                                   "-format", "UDZO", image.path]) == 0)
        let renamed = fixture.work.appendingPathComponent("image.bin")
        try FileManager.default.moveItem(at: image, to: renamed)
        #expect(DiskImage.matches(renamed))
        #expect(!DiskImage.matches(fixture.content.appendingPathComponent("README.md")))
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
