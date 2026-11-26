# 7-Zip 补丁

`Scripts/build-7zip.sh` 每次从固定版本的原始源码出发，按文件名顺序应用本目录的 `*.patch`。

| 补丁 | 原因 |
| --- | --- |
| `udf-symlink.patch` | 7-Zip 26.06 的 UDF 解析遇到符号链接条目（ICB 文件类型 12）时把整个镜像判为无法识别。补丁让 UDF 接受符号链接，并通过 `kpidPosixAttrib` 标为符号链接（PeekBox 只显示、不提取）。 |
