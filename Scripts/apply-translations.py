"""把英文翻译写入 .xcstrings。

translations-en.json 的值可以是：
- 字符串：普通翻译
- {"one": ..., "other": ...}：整句按唯一的数字参数区分单复数
- {"value": "... %#@name@ ...", "subs": {"name": [参数序号, "lld", 单数, 复数]}}：多参数句子中只对某个数字参数区分单复数
"""
import json, sys

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

def localization(value):
    if isinstance(value, str):
        return unit(value)
    if "one" in value:
        return {"variations": {"plural": {"one": unit(value["one"]), "other": unit(value["other"])}}}
    subs = {}
    for name, (arg, spec, one, other) in value["subs"].items():
        subs[name] = {"argNum": arg, "formatSpecifier": spec,
                      "variations": {"plural": {"one": unit(one), "other": unit(other)}}}
    return {"stringUnit": {"state": "translated", "value": value["value"]}, "substitutions": subs}

translations = json.load(open(sys.argv[1], encoding="utf-8"))
# 代码里的键是中文原文。源语言设为英文（与工程开发语言一致），中文作为显式翻译写入：
# 构建工具不为源语言生成资源，若以中文为源语言，产物里就没有 zh-Hans.lproj，系统会认为不支持中文。
missing = []
for path in sys.argv[2:]:
    catalog = json.load(open(path, encoding="utf-8"))
    catalog["sourceLanguage"] = "en"
    # 代码里已不再使用的文案（sync 标记为 stale）直接删除
    catalog["strings"] = {k: v for k, v in catalog["strings"].items() if v.get("extractionState") != "stale"}
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale":
            continue
        if key not in translations:
            # 在 Xcode 中手动维护、已有英文翻译的条目保留原样
            if entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("state") == "translated":
                continue
            missing.append(f"{path}: {key!r}")
            continue
        localizations = entry.setdefault("localizations", {})
        localizations["en"] = localization(translations[key])
        localizations["zh-Hans"] = unit(key)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
if missing:
    print("缺少英文翻译：\n" + "\n".join(missing))
    sys.exit(1)
print("translations applied")
