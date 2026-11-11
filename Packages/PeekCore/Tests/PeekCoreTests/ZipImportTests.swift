import Foundation
import Testing
@testable import PeekCore

@Suite struct ZipImportTests {
    private func read(_ archive: URL, _ path: String) throws -> Data {
        let reader = try ZipArchive.open(archive)
        let item = try #require(reader.tree.items[path])
        let target = archive.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        try reader.extractFile(item, to: target, password: nil)
        return try Data(contentsOf: target)
    }

    private func input(_ fixture: Fixture, _ name: String, _ content: String) throws -> URL {
        let folder = fixture.work.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test func locatesZipBeforeItsFirstExpansion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let source = FolderSource(rootURL: fixture.work, showHidden: false)
        let archive = try #require(source.archiveSource(for: zip))
        #expect(archive.loadedReader == nil)
        #expect(source.archiveSource(for: fixture.work.appendingPathComponent("notes.txt")) == nil)
    }

    @Test func importsTreeAndEmptyDirectoriesWithoutChangingExistingContent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let source = fixture.work.appendingPathComponent("资料")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("中文.txt"))
        let count = try ZipEditor.addFiles(archive: zip, sources: [source], parent: "config", trashOldVersion: false) { _ in
            Issue.record("No conflict expected"); return .init(.cancel)
        }
        #expect(count.entries == 3)
        #expect(count.added == 1)
        #expect(try read(zip, "config/资料/中文.txt") == Data("hello".utf8))
        #expect(try ZipArchive.open(zip).tree.items["config/资料/空目录"]?.isDirectory == true)
        #expect(try read(zip, "config/deep/大文件.bin") == Data(repeating: 7, count: 600_000))
        #expect(try fixture.run("/usr/bin/unzip", ["-tqq", zip.path]) == 0)
    }

    @Test func replacesDirectoryAsAnExplicitWhole() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let source = fixture.work.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        try ZipEditor.addFiles(archive: zip, sources: [source], parent: "", trashOldVersion: false) { conflict in
            #expect(conflict.existingIsDirectory && conflict.incomingIsDirectory)
            return .init(.replace)
        }
        let tree = try ZipArchive.open(zip).tree
        #expect(tree.items["config/deep"] == nil)
        #expect(tree.items["config/format.json"] == nil)
        #expect(try read(zip, "config/new.txt") == Data("new".utf8))
        #expect(try read(zip, "README.md") == Data("readme".utf8))
    }

    @Test func keepsBothFilesAndPreservesSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let file = try input(fixture, "README.md", "new")
        try ZipEditor.addFiles(archive: zip, sources: [file], parent: "", trashOldVersion: false) { _ in .init(.keepBoth) }
        #expect(try read(zip, "README.md") == Data("readme".utf8))
        #expect(try read(zip, "README 2.md") == Data("new".utf8))
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }

    @Test func replacementOfFilePreservesOtherEntries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let file = try input(fixture, "README.md", "new")
        let before = try ZipArchive.open(zip).tree.items.count
        try ZipEditor.addFiles(archive: zip, sources: [file], parent: "", trashOldVersion: false) { _ in .init(.replace) }
        #expect(try read(zip, "README.md") == Data("new".utf8))
        #expect(try ZipArchive.open(zip).tree.items.count == before)
        #expect(try read(zip, "config/format.json") == Data("{}".utf8))
    }

    @Test func skipAndCancelLeaveArchiveByteIdentical() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let before = try Data(contentsOf: zip)
        let file = try input(fixture, "README.md", "new")
        #expect(try ZipEditor.addFiles(archive: zip, sources: [file], parent: "", trashOldVersion: false) { _ in .init(.skip) }.entries == 0)
        #expect(try Data(contentsOf: zip) == before)
        #expect(throws: ZipEditor.EditError.cancelled) {
            try ZipEditor.addFiles(archive: zip, sources: [file], parent: "", trashOldVersion: false) { _ in .init(.cancel) }
        }
        #expect(try Data(contentsOf: zip) == before)
    }

    @Test func appliesConflictChoiceToBatch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let a = try input(fixture, "README.md", "new")
        let b = try input(fixture, ".hidden", "new hidden")
        var prompts = 0
        try ZipEditor.addFiles(archive: zip, sources: [a, b], parent: "", trashOldVersion: false) { _ in
            prompts += 1; return .init(.keepBoth, applyToAll: true)
        }
        #expect(prompts == 1)
        #expect(try read(zip, "README 2.md") == Data("new".utf8))
    }

    @Test func detectsChangedInputBeforeCommit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let before = try Data(contentsOf: zip)
        let a = try input(fixture, "A.txt", "before")
        let b = try input(fixture, "README.md", "replacement")
        #expect(throws: ZipEditor.EditError.sourceChanged("A.txt")) {
            try ZipEditor.addFiles(archive: zip, sources: [a, b], parent: "", trashOldVersion: false) { _ in
                try Data("after".utf8).write(to: a)
                return .init(.skip)
            }
        }
        #expect(try Data(contentsOf: zip) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).allSatisfy { !$0.hasPrefix(".peekbox-transaction-") })
    }

    @Test func rejectsExternalArchiveChangeDuringConflictPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let a = try input(fixture, "A.txt", "new")
        let b = try input(fixture, "README.md", "replacement")
        var external = try Data(contentsOf: zip)
        external.append(Data("external".utf8))
        #expect(throws: ZipEditor.EditError.modifiedExternally) {
            try ZipEditor.addFiles(archive: zip, sources: [a, b], parent: "", trashOldVersion: false) { _ in
                try external.write(to: zip)
                return .init(.skip)
            }
        }
        #expect(try Data(contentsOf: zip) == external)
    }

    @Test func rejectsSymlinksAndSelfImportWithoutChangingArchive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let before = try Data(contentsOf: zip)
        let link = fixture.work.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.content)
        for source in [link, zip] {
            #expect(throws: ZipEditor.EditError.self) {
                try ZipEditor.addFiles(archive: zip, sources: [source], parent: "", trashOldVersion: false) { _ in .init(.cancel) }
            }
        }
        #expect(try Data(contentsOf: zip) == before)
    }

    @Test func rejectsAddingToEncryptedZip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("encrypted.zip", extra: ["-P", "pass word"])
        #expect(throws: ZipEditor.EditError.encryptedWrite) { try ZipEditor.checkAdditions(zip) }
    }

    @Test func createsNestedDirectoryAndRejectsAmbiguousNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let path = try ZipEditor.createDirectory(archive: zip, parent: "config/deep", name: "新文件夹")
        #expect(path == "config/deep/新文件夹")
        #expect(try ZipArchive.open(zip).tree.items[path]?.isDirectory == true)
        #expect(throws: ZipEditor.EditError.nameExists("CONFIG")) {
            try ZipEditor.createDirectory(archive: zip, parent: "", name: "CONFIG")
        }
        for name in ["../evil", "..", "a\0b", "a\\b"] {
            #expect(throws: ZipEditor.EditError.invalidName) { try ZipEditor.createDirectory(archive: zip, parent: "", name: name) }
        }
    }

    @Test func preCancelledWriteLeavesArchiveUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let before = try Data(contentsOf: zip)
        let control = ZipWriteControl()
        control.cancel()
        #expect(throws: ZipEditor.EditError.cancelled) {
            try ZipEditor.createDirectory(archive: zip, parent: "", name: "new", control: control)
        }
        #expect(try Data(contentsOf: zip) == before)
    }

    @Test func recoversOnlyAbandonedCopiesAndStaging() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let before = try Data(contentsOf: zip)
        let root = fixture.work.appendingPathComponent("transactions")
        let workspace = try ZipWriteWorkspace(archive: zip, root: root)
        try Data("partial archive".utf8).write(to: workspace.archiveCopy)
        let part = workspace.archiveCopy.appendingPathExtension("Ab12xY.part")
        try Data("partial compression".utf8).write(to: part)
        try Data("staged input".utf8).write(to: workspace.directory.appendingPathComponent("input-0"))
        ZipWriteWorkspace.cleanupAbandoned(root: root)
        #expect(!FileManager.default.fileExists(atPath: workspace.archiveCopy.path))
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
        #expect(try Data(contentsOf: zip) == before)
    }

    @Test func reportsSummaryAndRemainingConflicts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let incoming = fixture.work.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        // README.md 与 config 重名，new.txt 不重名
        let readme = incoming.appendingPathComponent("README.md")
        let config = incoming.appendingPathComponent("config")
        let fresh = incoming.appendingPathComponent("new.txt")
        try Data("new readme".utf8).write(to: readme)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fresh)

        var remaining: [String: Int] = [:]
        let summary = try ZipEditor.addFiles(archive: zip, sources: [readme, config, fresh], parent: "",
                                             trashOldVersion: false) { conflict in
            remaining[conflict.path] = conflict.remainingConflicts
            return .init(conflict.path == "README.md" ? .replace : .skip)
        }
        // 按路径排序处理：README.md（大写）排在 config 之前，处理它时后面还有 config 一个冲突
        #expect(remaining == ["README.md": 1, "config": 0])
        #expect(summary.added == 1)
        #expect(summary.replaced == 1)
        #expect(summary.skipped == 1)
        #expect(try read(zip, "README.md") == Data("new readme".utf8))
        #expect(try ZipArchive.open(zip).tree.items["config/format.json"] != nil)
    }
}

@Suite struct ZipImportMemoryTests {
    /// 进程内存占用峰值（与活动监视器"内存"一列同口径）
    private func footprintPeak() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.ledger_phys_footprint_peak : 0
    }

    /// 导入大文件时按块流式暂存，内存不随文件大小增长（曾因读块未及时释放，导入 1.9 GB 文件时占用 1.9 GB）。
    /// 峰值按整个测试进程计，并行的其他测试也会抬高它：文件取 1 GB、门槛 256 MB，退化时差距仍一目了然
    @Test func importingLargeFileDoesNotBufferItInMemory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let zip = try fixture.zip("sample.zip")
        let large = fixture.work.appendingPathComponent("large.bin")
        let size: Int64 = 1 << 30
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()

        let before = footprintPeak()
        try ZipEditor.addFiles(archive: zip, sources: [large], parent: "", trashOldVersion: false) { _ in .init(.cancel) }
        let growth = footprintPeak() - before
        #expect(growth < 256 << 20, "导入 1 GB 文件时内存峰值增加 \(growth >> 20) MB")
        #expect(try ZipArchive.open(zip).tree.items["large.bin"]?.size == size)
    }
}
