// PeekBox 与 7-Zip 之间的只读 C 接口：打开磁盘镜像，逐层深入分区与文件系统，列出条目并按条目提取。
// 由 Scripts/build-7zip.sh 与 7-Zip 源码一同编译为 CSevenZip.xcframework。
#ifndef PEEK_SEVENZIP_H
#define PEEK_SEVENZIP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PSZArchive PSZArchive;

/// 打开与提取的结果。文案由调用方按状态本地化
typedef enum {
    PSZ_OK = 0,
    /// 文件无法读取
    PSZ_UNREADABLE = 1,
    /// 不是可识别的磁盘镜像或文件系统
    PSZ_UNRECOGNIZED = 2,
    /// 加密的磁盘镜像（暂不支持）
    PSZ_ENCRYPTED = 3,
    /// 提取：无法创建或写入目标文件（detail 为路径）
    PSZ_WRITE_FAILED = 4,
    /// 提取：数据损坏或校验失败
    PSZ_DATA_ERROR = 5,
    /// 提取：不支持的压缩方法
    PSZ_UNSUPPORTED_METHOD = 6,
    PSZ_INTERNAL = 7,
} PSZStatus;

typedef struct {
    /// UTF-8，以 / 分隔，已去掉单一卷时的卷名层；生命周期随归档对象
    const char *path;
    uint64_t size;
    int64_t mtime_sec;
    int32_t mtime_nsec;
    bool has_size;
    bool has_mtime;
    bool is_dir;
    bool is_symlink;
    /// 未能识别文件系统的分区，作为原始分区文件列出
    bool is_raw_partition;
    /// 符号链接的目标（读不到时为 NULL）
    const char *link_target;
    /// 原始分区中按签名认出、但无法浏览的文件系统，如 "exFAT"、"BitLocker"（未认出为 NULL）
    const char *filesystem_hint;
} PSZItem;

/// 打开镜像。失败返回 NULL，原因写入 status_out
PSZArchive *psz_open(const char *path, PSZStatus *status_out);
void psz_close(PSZArchive *archive);

uint32_t psz_item_count(const PSZArchive *archive);
bool psz_item(const PSZArchive *archive, uint32_t index, PSZItem *out);

/// 各层格式，如 "Dmg > HFS"；多个卷时为 "Dmg > GPT > APFS, FAT"
const char *psz_format(const PSZArchive *archive);
/// 单一卷时的卷名（HFS+ 卷根目录名、FAT / NTFS / ext 卷标、APFS 卷名；无则为空字符串）
const char *psz_volume_name(const PSZArchive *archive);

/// 把 indices[i] 提取到 targets[i]（文件必须尚不存在）。失败时 detail_out 为相关路径（调用方用 psz_free 释放）。
/// 非线程安全：同一归档的提取由调用方串行
PSZStatus psz_extract(PSZArchive *archive, const uint32_t *indices, const char *const *targets,
                      uint32_t count, char **detail_out);

const char *psz_version(void);
void psz_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
