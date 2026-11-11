import Foundation

/// 由后台服务代读的压缩包。单独预览分卷包时，沙盒扩展只能读被预览的那一个文件，读不到同目录的其他卷；
/// 后台服务不在沙盒中，由它解析目录树、把条目直接提取到目标位置（拖出目标、检查器临时文件等），扩展不经手数据。
/// 接口是同步的，调用方已在后台线程。
struct BrokerArchiveReader: ArchiveReader {
    let archiveURL: URL
    let tree: ArchiveTree

    static func open(_ url: URL, password: String?) throws -> BrokerArchiveReader {
        BrokerArchiveReader(archiveURL: url, tree: try BrokerClient.shared.archiveTree(url, password: password))
    }

    func extractFile(_ item: ArchiveTree.Item, to destination: URL, password: String?) throws {
        try extractFiles([(item, destination)], password: password)
    }

    func extractFiles(_ jobs: [(item: ArchiveTree.Item, target: URL)], password: String?) throws {
        guard !jobs.isEmpty else { return }
        try BrokerClient.shared.extractEntries(archiveURL, jobs: jobs.map { ($0.item.path, $0.target) }, password: password)
    }
}
