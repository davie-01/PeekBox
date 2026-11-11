import Foundation
import Testing
@testable import PeekCore

@Suite struct FolderSourceTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekCoreTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("b-dir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Demo.app"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("10".utf8).write(to: root.appendingPathComponent("file10.txt"))
        try Data("2".utf8).write(to: root.appendingPathComponent("file2.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        return root
    }

    @Test func listsDirectChildrenAndSkipsHidden() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try await FolderSource(rootURL: root, showHidden: false).children(of: nil)
        #expect(Set(entries.map(\.name)) == ["a.txt", "b-dir", "Demo.app", "file10.txt", "file2.txt"])

        let text = try #require(entries.first { $0.name == "a.txt" })
        #expect(text.size == 5)
        #expect(!text.isDirectory)

        #expect(entries.first { $0.name == "b-dir" }?.isDirectory == true)
        // 包按单一项目处理
        #expect(entries.first { $0.name == "Demo.app" }?.isDirectory == false)
    }

    @Test func showsHiddenWhenRequested() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try await FolderSource(rootURL: root, showHidden: true).children(of: nil)
        #expect(entries.contains { $0.name == ".hidden" })
    }

    @Test func naturalSortWithFoldersFirst() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try await FolderSource(rootURL: root, showHidden: false).children(of: nil)
        let sorted = entries.sortedForDisplay(foldersFirst: true).map(\.name)
        #expect(sorted == ["b-dir", "a.txt", "Demo.app", "file2.txt", "file10.txt"])
    }
}
