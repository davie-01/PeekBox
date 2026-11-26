// PeekSevenZip.cpp：7-Zip 只读桥接。
//
// 打开时按固定顺序尝试文件系统与容器格式。容器（DMG、GPT、MBR、虚拟磁盘等）的每个分区再当作新的流尝试打开，
// 直到遇到文件系统为止；每个识别出的文件系统称为一个"卷"。只有一个卷时直接把它的内容放在根目录，
// 多个卷时每个卷占一个顶层目录。识别不出文件系统、又不是分区表元数据的较大分区作为原始分区文件列出。

#include "Common/Common.h"
#include "Common/MyWindows.h"
#include "Common/MyInitGuid.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <vector>

#include "Common/MyCom.h"
#include "Common/MyString.h"
#include "Common/UTFConvert.h"
#include "Windows/PropVariant.h"

#include "7zip/ICoder.h"
#include "7zip/IPassword.h"
#include "7zip/IProgress.h"
#include "7zip/IStream.h"
#include "7zip/Archive/IArchive.h"
#include "7zip/Common/FileStreams.h"

#include "7zVersion.h"
#include "7zip/IDecl.h"

#include "PeekSevenZip.h"

// 本文件包含 MyInitGuid.h，接口 GUID 在这里定义一次；ArchiveExports.cpp 中的 CLSID 只是声明，也在这里定义
Z7_DEFINE_GUID(CLSID_CArchiveHandler,
    k_7zip_GUID_Data1, k_7zip_GUID_Data2, k_7zip_GUID_Data3_Common,
    0x10, 0x00, 0x00, 0x01, 0x10, 0x00, 0x00, 0x00);

STDAPI GetNumberOfFormats(UINT32 *numFormats);
STDAPI GetHandlerProperty2(UInt32 formatIndex, PROPID propID, PROPVARIANT *value);
STDAPI CreateArchiver(const GUID *clsid, const GUID *iid, void **outObject);

namespace {

/// 尝试顺序：文件系统在前，分区与容器格式在后。MBR 没有签名，FAT / NTFS 引导扇区也以 55 AA 结尾，必须最后试；
/// UDF 排在 ISO 前面：Windows 安装盘这类 UDF + ISO 桥接镜像，ISO 9660 部分放不下 4 GB 以上的文件
const char *const kFormatOrder[] = {
    "Dmg", "APFS", "HFS", "Udf", "Iso", "NTFS", "FAT", "Ext", "SquashFS", "CramFS",
    "GPT", "APM", "VHDX", "VHD", "VMDK", "QCOW", "VDI", "Sparse", "MBR",
};

/// 本身不是文件系统、内容是分区或整块磁盘的格式
const char *const kContainers[] = {
    "Dmg", "GPT", "APM", "MBR", "VHDX", "VHD", "VMDK", "QCOW", "VDI", "Sparse",
};

constexpr int kMaxDepth = 6;
/// 小于此大小、又识别不出文件系统的分区视为分区表元数据（GPT 头、保护性 MBR、空闲区），不列出
constexpr UInt64 kMinRawPartitionSize = 1 << 20;
/// 小于此大小的分区不尝试打开：保护性 MBR（512 字节）会被当成一张 MBR 分区表，解析出一个并不存在的分区
constexpr UInt64 kMinOpenablePartitionSize = 64 << 10;

/// HFS+ 根目录下的私有目录：硬链接与目录硬链接的实际数据，不是用户内容
std::string restoreBlankNames(const std::string &path) {
    std::string result;
    size_t start = 0;
    while (start <= path.size()) {
        const size_t slash = path.find('/', start);
        const std::string component = path.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        if (!result.empty() || start > 0) result += '/';
        result += component == "[]" ? " " : component;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return result;
}

bool isHfsPrivateRoot(const std::string &path) {
    return path == "[HFS+ Private Data]" || path.compare(0, 28, ".HFS+ Private Directory Data") == 0;
}

bool equalsIgnoreCase(const std::string &a, const char *b) {
    return strcasecmp(a.c_str(), b) == 0;
}

bool isContainer(const std::string &format) {
    for (const char *name : kContainers)
        if (equalsIgnoreCase(format, name)) return true;
    return false;
}

std::string toUTF8(const wchar_t *text) {
    if (!text) return {};
    AString out;
    ConvertUnicodeToUTF8(UString(text), out);
    return std::string(out.Ptr(), out.Len());
}

std::string stringProperty(IInArchive *archive, UInt32 index, PROPID prop) {
    NWindows::NCOM::CPropVariant value;
    if (archive->GetProperty(index, prop, &value) != S_OK || value.vt != VT_BSTR) return {};
    return toUTF8(value.bstrVal);
}

bool boolProperty(IInArchive *archive, UInt32 index, PROPID prop) {
    NWindows::NCOM::CPropVariant value;
    if (archive->GetProperty(index, prop, &value) != S_OK) return false;
    return value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE;
}

bool uint64Property(IInArchive *archive, UInt32 index, PROPID prop, UInt64 &out) {
    NWindows::NCOM::CPropVariant value;
    if (archive->GetProperty(index, prop, &value) != S_OK) return false;
    switch (value.vt) {
    case VT_UI8: out = value.uhVal.QuadPart; return true;
    case VT_UI4: out = value.ulVal; return true;
    case VT_UI2: out = value.uiVal; return true;
    case VT_UI1: out = value.bVal; return true;
    default: return false;
    }
}

char *duplicate(const std::string &text) {
    return strdup(text.c_str());
}

std::string sanitizeComponent(std::string name) {
    std::replace(name.begin(), name.end(), '/', '_');
    while (!name.empty() && (name.back() == ' ' || name.back() == '.')) name.pop_back();
    return name.empty() ? std::string("_") : name;
}

// MARK: - 回调

Z7_CLASS_IMP_COM_2(COpenCallback, IArchiveOpenCallback, ICryptoGetTextPassword)
public:
    bool passwordRequested = false;
};

Z7_COM7F_IMF(COpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(COpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(COpenCallback::CryptoGetTextPassword(BSTR *)) {
    // 加密镜像（如 AES 加密的 DMG）暂不支持
    passwordRequested = true;
    return E_ABORT;
}

/// 写入单个目标文件：O_EXCL 保证不覆盖已存在的文件
Z7_CLASS_IMP_COM_1(CFileOutStream, ISequentialOutStream)
public:
    int fd = -1;
    ~CFileOutStream() { closeFile(); }
    bool create(const char *path) {
        fd = ::open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        return fd >= 0;
    }
    bool closeFile() {
        if (fd < 0) return true;
        const bool ok = ::close(fd) == 0;
        fd = -1;
        return ok;
    }
};

Z7_COM7F_IMF(CFileOutStream::Write(const void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    const char *bytes = static_cast<const char *>(data);
    UInt32 done = 0;
    while (done < size) {
        const ssize_t written = ::write(fd, bytes + done, size - done);
        if (written < 0) {
            if (errno == EINTR) continue;
            if (processed) *processed = done;
            return HRESULT_FROM_WIN32(errno);
        }
        done += static_cast<UInt32>(written);
    }
    if (processed) *processed = done;
    return S_OK;
}

/// 读入内存，最多 limit 字节（读符号链接目标）
Z7_CLASS_IMP_COM_1(CMemoryOutStream, ISequentialOutStream)
public:
    std::string data;
    size_t limit = 4096;
    bool truncated = false;
};

Z7_COM7F_IMF(CMemoryOutStream::Write(const void *bytes, UInt32 size, UInt32 *processed)) {
    const size_t room = data.size() < limit ? limit - data.size() : 0;
    if (size > room) truncated = true;
    data.append(static_cast<const char *>(bytes), std::min<size_t>(room, size));
    if (processed) *processed = size;
    return S_OK;
}

/// 提取回调：targets 中的条目写入文件；toMemory 时改为读入 buffers
Z7_CLASS_IMP_COM_2(CExtractCallback, IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    std::map<UInt32, std::string> targets;
    bool toMemory = false;
    size_t memoryLimit = 4096;
    std::map<UInt32, std::string> buffers;
    PSZStatus status = PSZ_OK;
    std::string detail;
    std::vector<std::string> created;
private:
    void fail(PSZStatus code, const std::string &path) {
        if (status != PSZ_OK) return;
        status = code;
        detail = path;
    }
    CFileOutStream *_fileSpec = nullptr;
    CMemoryOutStream *_memorySpec = nullptr;
    CMyComPtr<ISequentialOutStream> _current;
    UInt32 _currentIndex = 0;
    std::string _currentPath;
};

Z7_COM7F_IMF(CExtractCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(CExtractCallback::SetCompleted(const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(CExtractCallback::CryptoGetTextPassword(BSTR *)) { return E_ABORT; }
Z7_COM7F_IMF(CExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(CExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askMode)) {
    *outStream = nullptr;
    if (askMode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    const auto target = targets.find(index);
    if (target == targets.end()) return S_OK;
    _currentIndex = index;
    _currentPath = target->second;
    if (toMemory) {
        _memorySpec = new CMemoryOutStream;
        _memorySpec->limit = memoryLimit;
        _current = _memorySpec;
    } else {
        auto *spec = new CFileOutStream;
        CMyComPtr<ISequentialOutStream> stream = spec;
        if (!spec->create(target->second.c_str())) {
            fail(PSZ_WRITE_FAILED, target->second);
            return E_FAIL;
        }
        created.push_back(target->second);
        _fileSpec = spec;
        _current = stream;
    }
    CMyComPtr<ISequentialOutStream> handed = _current;
    *outStream = handed.Detach();
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::SetOperationResult(Int32 result)) {
    if (_fileSpec) {
        if (!_fileSpec->closeFile()) fail(PSZ_WRITE_FAILED, _currentPath);
        _fileSpec = nullptr;
    }
    if (_memorySpec) {
        // 超出上限的不采用（截断的扩展属性比没有更糟）
        if (result == NArchive::NExtract::NOperationResult::kOK && !_memorySpec->truncated)
            buffers[_currentIndex] = _memorySpec->data;
        _memorySpec = nullptr;
    }
    _current.Release();
    using namespace NArchive::NExtract::NOperationResult;
    switch (result) {
    case kOK: break;
    case kUnsupportedMethod: fail(PSZ_UNSUPPORTED_METHOD, _currentPath); break;
    default: fail(PSZ_DATA_ERROR, _currentPath); break;
    }
    return S_OK;
}

// MARK: - 打开

struct FormatRef {
    std::string name;
    GUID classID;
};

const std::vector<FormatRef> &orderedFormats() {
    static const std::vector<FormatRef> formats = [] {
        std::vector<FormatRef> all;
        UInt32 count = 0;
        GetNumberOfFormats(&count);
        for (UInt32 i = 0; i < count; i++) {
            NWindows::NCOM::CPropVariant name, classID;
            GetHandlerProperty2(i, NArchive::NHandlerPropID::kName, &name);
            GetHandlerProperty2(i, NArchive::NHandlerPropID::kClassID, &classID);
            if (name.vt != VT_BSTR || classID.vt != VT_BSTR) continue;
            FormatRef ref;
            ref.name = toUTF8(name.bstrVal);
            memcpy(&ref.classID, classID.bstrVal, sizeof(GUID));
            all.push_back(ref);
        }
        std::vector<FormatRef> ordered;
        for (const char *wanted : kFormatOrder)
            for (const auto &ref : all)
                if (equalsIgnoreCase(ref.name, wanted)) ordered.push_back(ref);
        return ordered;
    }();
    return formats;
}

}  // namespace

struct PSZLevel {
    CMyComPtr<IInArchive> archive;
    CMyComPtr<IInStream> stream;
    std::string format;
};

struct PSZEntry {
    size_t level;
    UInt32 index;
    std::string path;
    UInt64 size = 0;
    Int64 mtimeSec = 0;
    Int32 mtimeNsec = 0;
    bool hasSize = false, hasMtime = false, isDir = false, isSymlink = false, isRawPartition = false;
    bool hasLinkTarget = false;
    std::string linkTarget;
    std::string filesystemHint;
    /// 扩展属性：名称与所在层中交替数据流的序号（提取文件时一并写回）
    std::vector<std::pair<std::string, UInt32>> attributes;
};

struct PSZArchive {
    std::vector<PSZLevel> levels;
    std::vector<PSZEntry> entries;
    std::string format;
    std::string volumeName;
};

namespace {

bool openStream(IInStream *stream, PSZLevel &level, bool &passwordRequested) {
    for (const auto &ref : orderedFormats()) {
        CMyComPtr<IInArchive> archive;
        if (CreateArchiver(&ref.classID, &IID_IInArchive, (void **)&archive) != S_OK || !archive) continue;
        if (stream->Seek(0, STREAM_SEEK_SET, nullptr) != S_OK) return false;
        auto *callbackSpec = new COpenCallback;
        CMyComPtr<IArchiveOpenCallback> callback = callbackSpec;
        const UInt64 maxCheckStart = 0;
        const HRESULT result = archive->Open(stream, &maxCheckStart, callback);
        if (callbackSpec->passwordRequested) passwordRequested = true;
        if (result == S_OK) {
            UInt32 count = 0;
            archive->GetNumberOfItems(&count);
            // 打开成功但没有任何条目的容器（如误判的 MBR）继续尝试后面的格式
            if (count == 0 && isContainer(ref.name)) { archive->Close(); continue; }
            level.archive = archive;
            level.stream = stream;
            level.format = ref.name;
            return true;
        }
        archive->Close();
    }
    return false;
}

struct Volume {
    size_t level;
    std::string label;   // 多卷时作顶层目录名
};

struct RawPartition {
    size_t level;
    UInt32 index;
    std::string name;
    UInt64 size;
    std::string filesystemHint;
};

/// 按签名认出 7-Zip 不能浏览的文件系统或加密卷，供界面提示（不解析）
std::string detectFilesystem(IInStream *stream) {
    if (!stream) return {};
    std::vector<Byte> head(0x10048, 0);
    if (stream->Seek(0, STREAM_SEEK_SET, nullptr) != S_OK) return {};
    UInt32 total = 0;
    while (total < head.size()) {
        UInt32 read = 0;
        if (stream->Read(head.data() + total, (UInt32)(head.size() - total), &read) != S_OK || read == 0) break;
        total += read;
    }
    auto at = [&](size_t offset, const char *magic, size_t length) {
        return offset + length <= total && memcmp(head.data() + offset, magic, length) == 0;
    };
    if (at(3, "EXFAT   ", 8)) return "exFAT";
    if (at(3, "-FVE-FS-", 8)) return "BitLocker";
    if (at(0, "LUKS\xBA\xBE", 6)) return "LUKS";
    if (at(32, "NXSB", 4)) return "APFS";
    if (at(0, "XFSB", 4)) return "XFS";
    if (at(0x10040, "_BHRfS_M", 8)) return "Btrfs";
    if (at(3, "NTFS    ", 8)) return "NTFS";
    return {};
}

/// 递归展开容器：把识别出的文件系统加入 volumes，识别不出的较大分区加入 raws
void expand(PSZArchive &arc, size_t levelIndex, int depth, std::vector<Volume> &volumes,
            std::vector<RawPartition> &raws, std::vector<std::string> &chain, bool &passwordRequested) {
    if (!isContainer(arc.levels[levelIndex].format) || depth >= kMaxDepth) {
        volumes.push_back({levelIndex, {}});
        return;
    }
    IInArchive *archive = arc.levels[levelIndex].archive;
    CMyComPtr<IInArchiveGetStream> getStream;
    archive->QueryInterface(IID_IInArchiveGetStream, (void **)&getStream);
    UInt32 count = 0;
    archive->GetNumberOfItems(&count);
    for (UInt32 i = 0; i < count; i++) {
        if (boolProperty(archive, i, kpidIsDir)) continue;
        UInt64 size = 0;
        const bool hasSize = uint64Property(archive, i, kpidSize, size);
        std::string name = stringProperty(archive, i, kpidPath);
        if (name.empty()) name = "partition-" + std::to_string(i);

        bool opened = false;
        CMyComPtr<IInStream> sub;
        if (getStream && (!hasSize || size >= kMinOpenablePartitionSize)) {
            CMyComPtr<ISequentialInStream> sequential;
            if (getStream->GetStream(i, &sequential) == S_OK && sequential
                && sequential->QueryInterface(IID_IInStream, (void **)&sub) == S_OK && sub) {
                PSZLevel level;
                if (openStream(sub, level, passwordRequested)) {
                    arc.levels.push_back(level);
                    chain.push_back(level.format);
                    const size_t child = arc.levels.size() - 1;
                    const size_t before = volumes.size();
                    expand(arc, child, depth + 1, volumes, raws, chain, passwordRequested);
                    for (size_t v = before; v < volumes.size(); v++)
                        if (volumes[v].label.empty()) volumes[v].label = name;
                    opened = true;
                }
            }
        }
        if (!opened && (!hasSize || size >= kMinRawPartitionSize))
            raws.push_back({levelIndex, i, name, size, detectFilesystem(sub)});
    }
}

void fileTime(IInArchive *archive, UInt32 index, PSZEntry &entry) {
    NWindows::NCOM::CPropVariant value;
    if (archive->GetProperty(index, kpidMTime, &value) != S_OK || value.vt != VT_FILETIME) return;
    const UInt64 ticks = ((UInt64)value.filetime.dwHighDateTime << 32) | value.filetime.dwLowDateTime;
    const UInt64 epoch = 116444736000000000ULL;   // 1601 → 1970，单位 100ns
    if (ticks == 0) return;
    const Int64 delta = (Int64)(ticks - epoch);
    Int64 sec = delta / 10000000;
    Int64 rem = delta % 10000000;
    if (rem < 0) { rem += 10000000; sec -= 1; }
    entry.mtimeSec = sec;
    entry.mtimeNsec = (Int32)(rem * 100);
    entry.hasMtime = true;
}

/// HFS 把卷根目录本身作为条目列出，路径都以卷名开头；这一层去掉，卷名另行保存
std::string hfsRootName(IInArchive *archive, UInt32 count) {
    std::string root;
    for (UInt32 i = 0; i < count; i++) {
        // 扩展属性流挂在卷根目录上时路径为 "卷名:属性名"，不在卷根之下，不参与判断
        if (boolProperty(archive, i, kpidIsAltStream)) continue;
        const std::string path = stringProperty(archive, i, kpidPath);
        const auto slash = path.find('/');
        const std::string first = slash == std::string::npos ? path : path.substr(0, slash);
        if (root.empty()) root = first;
        else if (first != root) return {};
    }
    return root;
}

/// HFS+ / APFS 的交替数据流对应的扩展属性名；不应写回的返回空
std::string attributeName(const std::string &format, const std::string &streamName) {
    // HFS 的资源分叉在 7-Zip 中名为 "rsrc"
    const std::string name = equalsIgnoreCase(format, "HFS") && streamName == "rsrc" ? "com.apple.ResourceFork" : streamName;
    // decmpfs 为透明压缩的数据（7-Zip 已解压），fs.symlink 为 APFS 存放链接目标的内部属性，
    // 隔离属性由调用方按归档统一设置
    if (name.empty() || name == "com.apple.decmpfs" || name == "com.apple.fs.symlink" || name == "com.apple.quarantine")
        return {};
    return name;
}

void addVolumeEntries(PSZArchive &arc, const Volume &volume, const std::string &prefix) {
    IInArchive *archive = arc.levels[volume.level].archive;
    UInt32 count = 0;
    archive->GetNumberOfItems(&count);
    const std::string &format = arc.levels[volume.level].format;
    std::string strip;
    if (equalsIgnoreCase(format, "HFS")) strip = hfsRootName(archive, count);

    // 扩展属性只在 HFS+ / APFS 上按 macOS 的扩展属性写回（NTFS 的交替数据流语义不同）
    CMyComPtr<IArchiveGetRawProps> rawProps;
    if (equalsIgnoreCase(format, "HFS") || equalsIgnoreCase(format, "APFS"))
        archive->QueryInterface(IID_IArchiveGetRawProps, (void **)&rawProps);
    std::map<UInt32, size_t> entryOfIndex;
    std::map<UInt32, std::vector<std::pair<std::string, UInt32>>> streamsOf;   // 父条目序号 → (属性名, 流序号)
    std::set<UInt32> compressed;   // 带 decmpfs 的文件：其资源分叉是压缩数据，不写回

    for (UInt32 i = 0; i < count; i++) {
        // 交替数据流（扩展属性、资源分叉、NTFS ADS）与辅助条目不作为独立文件显示
        if (boolProperty(archive, i, kpidIsAltStream)) {
            UInt32 parent = 0, parentType = 0;
            if (rawProps && rawProps->GetParent(i, &parent, &parentType) == S_OK
                && parentType == NParentType::kAltStream) {
                const std::string stream = stringProperty(archive, i, kpidName);
                if (stream == "com.apple.decmpfs") compressed.insert(parent);
                const std::string name = attributeName(format, stream);
                if (!name.empty()) streamsOf[parent].push_back({name, i});
            }
            continue;
        }
        if (boolProperty(archive, i, kpidIsAux)) continue;
        std::string path = stringProperty(archive, i, kpidPath);
        if (!strip.empty()) {
            if (path == strip) continue;
            if (path.compare(0, strip.size() + 1, strip + "/") == 0) path = path.substr(strip.size() + 1);
        }
        if (path.empty()) continue;
        if (equalsIgnoreCase(format, "HFS")) {
            const auto slash = path.find('/');
            if (isHfsPrivateRoot(slash == std::string::npos ? path : path.substr(0, slash))) continue;
            // 7-Zip 把名称为空或以空格开头的 HFS 条目显示为 "[]"。安装盘常用一个名为空格的
            // 替身指向 /Applications，还原为空格，与 Finder 挂载后看到的一致
            path = restoreBlankNames(path);
        }
        PSZEntry entry;
        entry.level = volume.level;
        entry.index = i;
        entry.path = prefix.empty() ? path : prefix + "/" + path;
        entry.isDir = boolProperty(archive, i, kpidIsDir);
        entry.hasSize = !entry.isDir && uint64Property(archive, i, kpidSize, entry.size);
        UInt64 attrib = 0;
        if (uint64Property(archive, i, kpidPosixAttrib, attrib)) entry.isSymlink = S_ISLNK((mode_t)attrib);
        if (!entry.isSymlink && !stringProperty(archive, i, kpidSymLink).empty()) entry.isSymlink = true;
        fileTime(archive, i, entry);
        entryOfIndex[i] = arc.entries.size();
        arc.entries.push_back(std::move(entry));
    }
    for (auto &streams : streamsOf) {
        const auto found = entryOfIndex.find(streams.first);
        if (found == entryOfIndex.end()) continue;
        PSZEntry &entry = arc.entries[found->second];
        if (entry.isDir || entry.isSymlink) continue;
        for (auto &stream : streams.second) {
            if (stream.first == "com.apple.ResourceFork" && compressed.count(streams.first)) continue;
            entry.attributes.push_back(stream);
        }
    }
    if (!prefix.empty()) return;
    if (!strip.empty()) {
        arc.volumeName = strip;
        return;
    }
    // 其他文件系统的卷标：FAT / NTFS / ext 为 kpidVolumeName，APFS 的 kpidName 为 "卷名.apfs"
    NWindows::NCOM::CPropVariant value;
    if (archive->GetArchiveProperty(kpidVolumeName, &value) == S_OK && value.vt == VT_BSTR) {
        arc.volumeName = toUTF8(value.bstrVal);
    } else if (equalsIgnoreCase(format, "APFS")) {
        NWindows::NCOM::CPropVariant name;
        if (archive->GetArchiveProperty(kpidName, &name) == S_OK && name.vt == VT_BSTR) {
            std::string label = toUTF8(name.bstrVal);
            if (label.size() > 5 && label.compare(label.size() - 5, 5, ".apfs") == 0) label.resize(label.size() - 5);
            arc.volumeName = label;
        }
    }
    while (!arc.volumeName.empty() && arc.volumeName.back() == ' ') arc.volumeName.pop_back();
}

/// 读出各符号链接的目标（链接内容就是目标路径，通常很短）
void readLinkTargets(PSZArchive &arc) {
    std::map<size_t, std::map<UInt32, std::string>> groups;
    for (const auto &entry : arc.entries)
        if (entry.isSymlink && entry.index != UINT32_MAX && (!entry.hasSize || entry.size <= 4096))
            groups[entry.level][entry.index] = entry.path;
    for (auto &group : groups) {
        auto *callbackSpec = new CExtractCallback;
        CMyComPtr<IArchiveExtractCallback> callback = callbackSpec;
        callbackSpec->toMemory = true;
        callbackSpec->targets = group.second;
        std::vector<UInt32> order;
        for (const auto &target : group.second) order.push_back(target.first);
        arc.levels[group.first].archive->Extract(order.data(), (UInt32)order.size(), 0, callback);
        for (auto &entry : arc.entries) {
            if (entry.level != group.first || !entry.isSymlink) continue;
            const auto found = callbackSpec->buffers.find(entry.index);
            if (found == callbackSpec->buffers.end() || found->second.empty()) continue;
            entry.linkTarget = found->second;
            entry.hasLinkTarget = true;
        }
    }
}

}  // namespace

namespace {

/// 把已提取文件的扩展属性（代码签名 com.apple.cs.*、资源分叉等）写回，与 Finder 从挂载的镜像拷贝一致。
/// 非 Mach-O 文件的代码签名就存在扩展属性里，缺了会导致整个 App 的签名校验失败
void applyAttributes(PSZArchive &arc, size_t level, const std::map<UInt32, std::string> &targets) {
    std::map<UInt32, std::pair<std::string, std::string>> streams;   // 流序号 → (目标文件, 属性名)
    for (const auto &entry : arc.entries) {
        if (entry.level != level || entry.attributes.empty()) continue;
        const auto target = targets.find(entry.index);
        if (target == targets.end()) continue;
        for (const auto &attribute : entry.attributes) streams[attribute.second] = {target->second, attribute.first};
    }
    if (streams.empty()) return;
    auto *callbackSpec = new CExtractCallback;
    CMyComPtr<IArchiveExtractCallback> callback = callbackSpec;
    callbackSpec->toMemory = true;
    callbackSpec->memoryLimit = 64 << 20;
    std::vector<UInt32> order;
    for (const auto &stream : streams) {
        callbackSpec->targets[stream.first] = stream.second.first;
        order.push_back(stream.first);
    }
    arc.levels[level].archive->Extract(order.data(), (UInt32)order.size(), 0, callback);
    for (const auto &stream : streams) {
        const auto data = callbackSpec->buffers.find(stream.first);
        if (data == callbackSpec->buffers.end()) continue;
        // 个别属性受系统保护（如 com.apple.provenance）写不进去，忽略
        setxattr(stream.second.first.c_str(), stream.second.second.c_str(), data->second.data(), data->second.size(),
                 0, XATTR_NOFOLLOW);
    }
}

}  // namespace

extern "C" {

PSZArchive *psz_open(const char *path, PSZStatus *status_out) {
    auto report = [&](PSZStatus status) { if (status_out) *status_out = status; };
    report(PSZ_OK);
    try {
        auto arc = std::make_unique<PSZArchive>();
        auto *fileSpec = new CInFileStream;
        CMyComPtr<IInStream> file = fileSpec;
        if (!fileSpec->Open(path)) {
            report(PSZ_UNREADABLE);
            return nullptr;
        }
        // 加密 DMG：v2 以 "encrcdsa" 开头，v1 以 "cdsaencr" 结尾
        {
            char head[8] = {};
            char tail[8] = {};
            UInt32 read = 0;
            UInt64 length = 0;
            file->Read(head, sizeof head, &read);
            if (file->Seek(-8, STREAM_SEEK_END, &length) == S_OK) file->Read(tail, sizeof tail, &read);
            if (memcmp(head, "encrcdsa", 8) == 0 || memcmp(tail, "cdsaencr", 8) == 0) {
                report(PSZ_ENCRYPTED);
                return nullptr;
            }
        }
        bool passwordRequested = false;
        PSZLevel top;
        if (!openStream(file, top, passwordRequested)) {
            report(passwordRequested ? PSZ_ENCRYPTED : PSZ_UNRECOGNIZED);
            return nullptr;
        }
        arc->levels.push_back(top);
        std::vector<std::string> chain{top.format};
        std::vector<Volume> volumes;
        std::vector<RawPartition> raws;
        expand(*arc, 0, 0, volumes, raws, chain, passwordRequested);

        const bool single = volumes.size() + raws.size() == 1;
        std::vector<std::string> usedNames;
        auto uniqueName = [&](std::string name) {
            name = sanitizeComponent(name);
            std::string candidate = name;
            for (int n = 2; std::find(usedNames.begin(), usedNames.end(), candidate) != usedNames.end(); n++)
                candidate = name + " " + std::to_string(n);
            usedNames.push_back(candidate);
            return candidate;
        };
        for (const auto &volume : volumes) {
            std::string prefix;
            if (!single) {
                // 多卷时优先用卷名作目录名（HFS 的卷根目录名），否则用分区名
                IInArchive *archive = arc->levels[volume.level].archive;
                UInt32 count = 0;
                archive->GetNumberOfItems(&count);
                std::string label = equalsIgnoreCase(arc->levels[volume.level].format, "HFS")
                    ? hfsRootName(archive, count) : std::string();
                if (label.empty()) label = volume.label.empty() ? arc->levels[volume.level].format : volume.label;
                prefix = uniqueName(label);
                PSZEntry dir;
                dir.level = volume.level;
                dir.index = UINT32_MAX;
                dir.path = prefix;
                dir.isDir = true;
                arc->entries.push_back(dir);
            }
            addVolumeEntries(*arc, volume, prefix);
        }
        for (const auto &raw : raws) {
            PSZEntry entry;
            entry.level = raw.level;
            entry.index = raw.index;
            entry.path = uniqueName(raw.name);
            entry.size = raw.size;
            entry.hasSize = true;
            entry.isRawPartition = true;
            entry.filesystemHint = raw.filesystemHint;
            arc->entries.push_back(entry);
        }
        readLinkTargets(*arc);

        // 格式链：外层容器 + 各卷文件系统
        std::string format;
        for (size_t i = 0; i < arc->levels.size(); i++) {
            if (!isContainer(arc->levels[i].format)) continue;
            if (format.find(arc->levels[i].format) != std::string::npos) continue;
            if (!format.empty()) format += " > ";
            format += arc->levels[i].format;
        }
        std::string filesystems;
        for (const auto &volume : volumes) {
            const std::string &name = arc->levels[volume.level].format;
            if (isContainer(name) || filesystems.find(name) != std::string::npos) continue;
            if (!filesystems.empty()) filesystems += ", ";
            filesystems += name;
        }
        if (!filesystems.empty()) format += (format.empty() ? "" : " > ") + filesystems;
        arc->format = format;
        return arc.release();
    } catch (...) {
        report(PSZ_INTERNAL);
        return nullptr;
    }
}

void psz_close(PSZArchive *archive) {
    if (!archive) return;
    // 内层依赖外层的流：从内往外关闭
    for (auto it = archive->levels.rbegin(); it != archive->levels.rend(); ++it) {
        if (it->archive) it->archive->Close();
        it->archive.Release();
        it->stream.Release();
    }
    delete archive;
}

uint32_t psz_item_count(const PSZArchive *archive) {
    return archive ? (uint32_t)archive->entries.size() : 0;
}

bool psz_item(const PSZArchive *archive, uint32_t index, PSZItem *out) {
    if (!archive || !out || index >= archive->entries.size()) return false;
    const PSZEntry &entry = archive->entries[index];
    out->path = entry.path.c_str();
    out->size = entry.size;
    out->has_size = entry.hasSize;
    out->mtime_sec = entry.mtimeSec;
    out->mtime_nsec = entry.mtimeNsec;
    out->has_mtime = entry.hasMtime;
    out->is_dir = entry.isDir;
    out->is_symlink = entry.isSymlink;
    out->is_raw_partition = entry.isRawPartition;
    out->link_target = entry.hasLinkTarget ? entry.linkTarget.c_str() : nullptr;
    out->filesystem_hint = entry.filesystemHint.empty() ? nullptr : entry.filesystemHint.c_str();
    return true;
}

const char *psz_format(const PSZArchive *archive) {
    return archive ? archive->format.c_str() : "";
}

const char *psz_volume_name(const PSZArchive *archive) {
    return archive ? archive->volumeName.c_str() : "";
}

PSZStatus psz_extract(PSZArchive *archive, const uint32_t *indices, const char *const *targets,
                      uint32_t count, char **detail_out) {
    if (detail_out) *detail_out = nullptr;
    if (!archive) return PSZ_INTERNAL;
    try {
        // 按所在层分组，每层一次 Extract（条目序号需升序）
        std::map<size_t, std::map<UInt32, std::string>> groups;
        for (uint32_t i = 0; i < count; i++) {
            if (indices[i] >= archive->entries.size()) return PSZ_INTERNAL;
            const PSZEntry &entry = archive->entries[indices[i]];
            if (entry.isDir || entry.index == UINT32_MAX) continue;
            groups[entry.level][entry.index] = targets[i];
        }
        for (auto &group : groups) {
            auto *callbackSpec = new CExtractCallback;
            CMyComPtr<IArchiveExtractCallback> callback = callbackSpec;
            callbackSpec->targets = group.second;
            std::vector<UInt32> order;
            for (const auto &target : group.second) order.push_back(target.first);
            const HRESULT result = archive->levels[group.first].archive->Extract(
                order.data(), (UInt32)order.size(), 0, callback);
            PSZStatus status = callbackSpec->status;
            if (status == PSZ_OK && result != S_OK) status = result == E_OUTOFMEMORY ? PSZ_INTERNAL : PSZ_DATA_ERROR;
            if (status != PSZ_OK) {
                for (const auto &path : callbackSpec->created) ::unlink(path.c_str());
                if (detail_out && !callbackSpec->detail.empty()) *detail_out = duplicate(callbackSpec->detail);
                return status;
            }
            applyAttributes(*archive, group.first, group.second);
            // 7-Zip 对空文件不一定调用 GetStream：补建未生成的目标
            for (const auto &target : group.second) {
                struct stat info;
                if (::stat(target.second.c_str(), &info) != 0) {
                    const int fd = ::open(target.second.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
                    if (fd >= 0) ::close(fd);
                }
            }
        }
        return PSZ_OK;
    } catch (...) {
        return PSZ_INTERNAL;
    }
}

const char *psz_version(void) {
    return MY_VERSION_NUMBERS;
}

void psz_free(void *pointer) {
    free(pointer);
}

}  // extern "C"
