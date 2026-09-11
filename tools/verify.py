#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RecoilPad 工程一致性校验。

在没有 Xcode 的环境下能查出的最要命的一类问题是：
某个 target 用了一个不在它编译范围内的类型 —— Xcode 里表现为
"cannot find type 'X' in scope"，但要等整个工程配完才暴露。

这里把它提前到文件层面：
  1. Swift 结构（括号平衡，剥离注释与字符串）
  2. plist / entitlements 可解析
  3. project.yml 引用的路径全部存在
  4. 每个 Swift 文件都被至少一个 target 覆盖
  5. 跨 target 类型引用可达性   <- 核心
  6. bundle id 与扩展点标识一致

用法：python3 tools/verify.py
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_YML = ROOT / "project.yml"

problems: list[str] = []
warnings: list[str] = []


# --------------------------------------------------------------- 工具

def strip_swift(src: str) -> str:
    """去注释与字符串字面量，保留结构字符。支持嵌套块注释和字符串插值。"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            continue
        if src.startswith('"""', i):
            i += 3
            while i < n and not src.startswith('"""', i):
                if src.startswith("\\(", i):
                    out.append("(")
                    i += 2
                    d = 1
                    while i < n and d:
                        if src[i] == "(":
                            d += 1
                        elif src[i] == ")":
                            d -= 1
                            if d == 0:
                                out.append(")")
                                i += 1
                                break
                        i += 1
                    continue
                i += 1
            i += 3
            continue
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                if src.startswith("\\(", i):
                    out.append("(")
                    i += 2
                    d = 1
                    while i < n and d:
                        if src[i] == "(":
                            d += 1
                        elif src[i] == ")":
                            d -= 1
                            if d == 0:
                                out.append(")")
                                i += 1
                                break
                        i += 1
                    continue
                i = i + 2 if src[i] == "\\" else i + 1
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def section(title: str) -> None:
    print()
    print("=" * 64)
    print(f" {title}")
    print("=" * 64)


# --------------------------------------------------------------- 1. Swift 语法

section("Swift 语法")

swift_files = sorted(ROOT.rglob("*.swift"))
if not swift_files:
    problems.append("没有找到任何 .swift 文件")

# 优先用 tree-sitter 做真正的语法树解析 —— 它能报出语法错误的位置，
# 比数括号强得多（括号计数看不出 `guard let x = x else` 少了个 else）。
# 装不上就退回括号计数，至少能拦住最粗暴的那类错误。
_parser = None
try:
    from tree_sitter import Language, Parser as _TSParser
    import tree_sitter_swift as _ts_swift
    try:
        _parser = _TSParser(Language(_ts_swift.language()))
    except TypeError:
        _parser = _TSParser()
        _parser.set_language(Language(_ts_swift.language()))
except Exception:
    _parser = None

if _parser is None:
    print(" [!] 未安装 tree-sitter-swift，退回括号计数")
    print("     pip install tree-sitter tree-sitter-swift")


def _walk_errors(node, src: bytes, out: list, depth: int = 0) -> None:
    """收集 ERROR / MISSING 节点。ERROR 内部不再下钻，避免一处错刷出几十条。"""
    is_error = getattr(node, "is_error", None)
    is_error = (node.type == "ERROR") if is_error is None else bool(is_error)
    is_missing = bool(getattr(node, "is_missing", False))

    if is_error or is_missing:
        line = node.start_point[0] + 1
        col = node.start_point[1] + 1
        snippet = src[node.start_byte:node.end_byte][:70]
        text = snippet.decode("utf-8", "replace").replace("\n", "\\n")
        kind = "MISSING" if is_missing else "ERROR"
        out.append(f"{kind} @{line}:{col} <{node.type}> `{text}`")
        return

    for child in node.children:
        _walk_errors(child, src, out, depth + 1)


for path in swift_files:
    rel = path.relative_to(ROOT)
    raw = path.read_bytes()
    lines = raw.count(b"\n") + 1

    if _parser is not None:
        tree = _parser.parse(raw)
        issues: list[str] = []
        if tree.root_node.has_error:
            _walk_errors(tree.root_node, raw, issues)
        status = "OK " if not issues else "FAIL"
        print(f" [{status}] {str(rel):<46} {lines:>4} 行  {len(issues)} 处语法错误")
        for issue in issues[:12]:
            print(f"        {issue}")
        if len(issues) > 12:
            print(f"        ... 另有 {len(issues) - 12} 处")
        if issues:
            problems.append(f"{rel} 有 {len(issues)} 处 Swift 语法错误")
    else:
        text = path.read_text(encoding="utf-8")
        stripped = strip_swift(text)
        bad = []
        for o, c, name in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
            d = stripped.count(o) - stripped.count(c)
            if d:
                bad.append(f"{name}{d:+d}")
        print(f" [{'OK ' if not bad else 'FAIL'}] {str(rel):<46} {lines:>4} 行  {' '.join(bad)}")
        if bad:
            problems.append(f"{rel} 结构不平衡: {bad}")


# --------------------------------------------------------------- 2. plist

section("plist / entitlements")
for path in sorted(list(ROOT.rglob("*.plist")) + list(ROOT.rglob("*.entitlements"))):
    rel = path.relative_to(ROOT)
    try:
        with path.open("rb") as fh:
            data = plistlib.load(fh)
        print(f" [OK ] {str(rel):<46} {len(data)} 个顶层键")
        if path.name.startswith("Broadcast-Info"):
            pid = data.get("NSExtension", {}).get("NSExtensionPointIdentifier")
            if pid != "com.apple.broadcast-services-upload":
                problems.append(f"{rel} 扩展点标识错误: {pid}")
    except Exception as exc:  # noqa: BLE001
        print(f" [FAIL] {rel}: {exc}")
        problems.append(f"{rel} 解析失败: {exc}")


# --------------------------------------------------------------- 2.5 YAML

section("YAML 合法性")

try:
    import yaml as _yaml
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False
    print(" [!] 未安装 pyyaml，跳过 YAML 深度校验（pip install pyyaml）")

yaml_docs: dict[str, object] = {}

for rel in ("project.yml",
            ".github/workflows/build.yml",
            ".github/workflows/ota.yml",
            ".github/workflows/testflight.yml"):
    path = ROOT / rel
    if not path.exists():
        print(f" [FAIL] {rel} 不存在")
        problems.append(f"缺少 {rel}")
        continue
    if not HAVE_YAML:
        print(f" [ -- ] {rel} 存在，未深度校验")
        continue
    try:
        doc = _yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f" [FAIL] {rel}: {exc}")
        problems.append(f"{rel} YAML 解析失败: {exc}")
        continue
    yaml_docs[rel] = doc
    print(f" [OK ] {rel}")

if HAVE_YAML and isinstance(yaml_docs.get("project.yml"), dict):
    tgts = yaml_docs["project.yml"].get("targets") or {}
    expected_targets = {"RecoilPad", "RecoilPadBroadcast", "RecoilPadTests"}
    missing_targets = expected_targets - set(tgts)
    print(f" [{'OK ' if not missing_targets else 'FAIL'}] project.yml 定义 target: {sorted(tgts)}")
    if missing_targets:
        problems.append(f"project.yml 缺少 target: {sorted(missing_targets)}")
    for tname, tcfg in tgts.items():
        for key in ("type", "platform", "sources"):
            if not tcfg.get(key):
                problems.append(f"target {tname} 缺少 {key}")
                print(f"        FAIL {tname} 缺少 {key}")

if HAVE_YAML:
    for rel, doc in yaml_docs.items():
        if not rel.startswith(".github/workflows/") or not isinstance(doc, dict):
            continue
        jobs = doc.get("jobs") or {}
        if not jobs:
            problems.append(f"{rel} 没有定义 jobs")
            print(f" [FAIL] {rel} 没有定义 jobs")
            continue
        for jname, job in jobs.items():
            if not job.get("runs-on"):
                problems.append(f"{rel} job {jname} 缺少 runs-on")
                print(f"        FAIL {jname} 缺少 runs-on")
            steps = job.get("steps") or []
            if not steps:
                problems.append(f"{rel} job {jname} 没有 steps")
                print(f"        FAIL {jname} 没有 steps")
                continue
            for i, step in enumerate(steps, 1):
                if not step.get("name"):
                    warnings.append(f"{rel} {jname} 第 {i} 个 step 缺 name")
                if not (step.get("uses") or step.get("run")):
                    problems.append(f"{rel} job {jname} step {i} 既无 uses 也无 run")
                    print(f"        FAIL {jname} step[{i}] 缺少 uses/run")
            print(f" [OK ] {rel} / {jname}: {len(steps)} 个 step, runs-on={job.get('runs-on')}")


# --------------------------------------------------------------- 3. project.yml

section("project.yml")

if not PROJECT_YML.exists():
    problems.append("缺少 project.yml")
    yml = ""
else:
    yml = PROJECT_YML.read_text(encoding="utf-8")

# 提取每个 target 的 sources。
# 必须做 YAML 层级感知：schemes: 段下也有 "  RecoilPad:" 这样的键，
# 不限定在 targets: 段内解析的话会把 target 定义覆盖成空。
targets: dict[str, dict] = {}
current_target = None
in_sources = False
top_section = None

for raw in yml.splitlines():
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue

    # 0 缩进 = 顶层键，切换段
    if re.match(r"^\S", raw):
        top_section = raw.split(":", 1)[0].strip()
        current_target = None
        in_sources = False
        continue

    if top_section != "targets":
        continue

    # 2 空格键 = target 名
    if re.match(r"^  \S+:\s*$", raw):
        current_target = stripped.rstrip(":")
        targets[current_target] = {"sources": [], "bundle_id": None, "info": None, "ent": None}
        in_sources = False
        continue

    if current_target is None:
        continue

    if re.match(r"^    sources:\s*$", raw):
        in_sources = True
        continue
    if re.match(r"^    \w", raw):
        in_sources = False

    m = re.match(r"^\s+-\s+path:\s*(\S+)", raw)
    if m and in_sources:
        targets[current_target]["sources"].append(m.group(1))
        continue

    # 行首锚定，避免 INFOPLIST_FILE 被 GENERATE_INFOPLIST_FILE 子串命中
    for key, field in ((r"^\s*PRODUCT_BUNDLE_IDENTIFIER:", "bundle_id"),
                       (r"^\s*INFOPLIST_FILE:", "info"),
                       (r"^\s*CODE_SIGN_ENTITLEMENTS:", "ent")):
        if re.match(key, raw):
            targets[current_target][field] = raw.split(":", 1)[1].strip().strip('"')

for name, cfg in targets.items():
    srcs = ", ".join(cfg["sources"]) or "(无)"
    print(f" [{'OK ' if cfg['sources'] else 'FAIL'}] {name:<20} sources: {srcs}")
    print(f"        bundle={cfg['bundle_id']}  info={cfg['info']}  ent={cfg['ent']}")
    if not cfg["sources"]:
        problems.append(f"{name} 没有配置 sources")
    for key in ("info", "ent"):
        if cfg[key] and not (ROOT / cfg[key]).exists():
            problems.append(f"{name} 引用的 {cfg[key]} 不存在")
            print(f"        FAIL {cfg[key]} 不存在")

# 文件覆盖检查
covered: set[Path] = set()
for cfg in targets.values():
    for s in cfg["sources"]:
        p = ROOT / s
        if not p.exists():
            problems.append(f"project.yml 声明的路径不存在: {s}")
            continue
        if p.is_dir():
            covered.update(p.rglob("*.swift"))
        else:
            covered.add(p)

uncovered = [f for f in swift_files if f not in covered]
print()
if uncovered:
    for f in uncovered:
        print(f" [FAIL] 未被任何 target 覆盖: {f.relative_to(ROOT)}")
        problems.append(f"{f.relative_to(ROOT)} 没有被编译进任何 target")
else:
    print(f" [OK ] 全部 {len(swift_files)} 个 Swift 文件都被 target 覆盖")


# --------------------------------------------------------------- 4. 跨 target 可达性

section("跨 target 类型可达性")

decl_re = re.compile(r"\b(?:struct|class|enum|protocol|actor)\s+(\w+)")
use_re = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\b")

# 类型 -> 定义它的文件
owner: dict[str, Path] = {}
for path in swift_files:
    src = strip_swift(path.read_text(encoding="utf-8"))
    for m in decl_re.finditer(src):
        owner.setdefault(m.group(1), path)
    # extension 也算定义来源，用于跨文件扩展
    for m in re.finditer(r"\bextension\s+(\w+)", src):
        owner.setdefault(m.group(1), path)

# 每个 target 能见到的文件集合
target_visible: dict[str, set[Path]] = {}
for name, cfg in targets.items():
    visible: set[Path] = set()
    for s in cfg["sources"]:
        p = ROOT / s
        if p.is_dir():
            visible.update(p.rglob("*.swift"))
        elif p.exists():
            visible.add(p)
    target_visible[name] = visible

# 排除测试 target：它靠 @testable import 拿主 target 的全部类型
main_targets = {k: v for k, v in target_visible.items() if "Tests" not in k}

violations = 0
for name, visible in main_targets.items():
    for path in sorted(visible):
        src = strip_swift(path.read_text(encoding="utf-8"))
        used = {m.group(1) for m in use_re.finditer(src)}
        for tname in sorted(used):
            if tname not in owner:
                continue                    # SDK 或外部类型
            if owner[tname] in visible:
                continue                    # 同 target，可见
            # 该类型所在的任何文件是否在本 target 可见
            home = owner[tname]
            if any(home == v for v in visible):
                continue
            print(f" [FAIL] {name} 的 {path.relative_to(ROOT)}")
            print(f"        引用了 {tname}，但它定义在 {home.relative_to(ROOT)}，不在本 target")
            problems.append(f"{name} 引用不可达类型 {tname}（定义于 {home.relative_to(ROOT)}）")
            violations += 1

if violations == 0:
    print(" [OK ] 没有跨 target 的不可达引用")


# --------------------------------------------------------------- 5. 武器库数据
#
# XCTest 里有等价断言，但那个要 Mac 才能跑。这里直接从源码里把 make(...)
# 调用解析出来验一遍 —— 这 11 组弹道是手写的，出错概率比代码本身高。

section("武器库数据")

weapon_src = ROOT / "Shared" / "WeaponLibrary.swift"
if weapon_src.exists():
    text = weapon_src.read_text(encoding="utf-8")
    call_re = re.compile(
        r'make\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*\.(\w+)\s*,\s*([0-9.]+)\s*,\s*\[(.*?)\]'
        r'\s*(?:,\s*drift:\s*([0-9.]+))?\s*\)',
        re.S,
    )
    weapons = []
    for m in call_re.finditer(text):
        wid, display, cat, rpm, body, drift = m.groups()
        ys = [float(v) for v in re.findall(r"[0-9]+(?:\.[0-9]+)?", body)]
        weapons.append({
            "id": wid, "display": display, "category": cat,
            "rpm": float(rpm), "dy": ys,
            "drift": float(drift) if drift else 0.0,
        })

    print(f" 解析到 {len(weapons)} 把武器")

    ids = [w["id"] for w in weapons]
    if len(set(ids)) != len(ids):
        dup = sorted({i for i in ids if ids.count(i) > 1})
        print(f" [FAIL] id 重复: {dup}")
        problems.append(f"武器 id 重复: {dup}")
    else:
        print(" [OK ] id 唯一")

    for w in weapons:
        bad = []
        if not (100 < w["rpm"] < 2000):
            bad.append(f"rpm={w['rpm']} 越界")
        if len(w["dy"]) < 20:
            bad.append(f"弹道只有 {len(w['dy'])} 发")
        if any(v < 0 for v in w["dy"]):
            bad.append("出现负上跳")
        if any(v >= 0.5 for v in w["dy"]):
            bad.append("单发上跳过大")
        total = sum(w["dy"])
        print(f" [{'OK ' if not bad else 'FAIL'}] {w['id']:<12} {w['display']:<12} "
              f"rpm={w['rpm']:>5.0f}  {len(w['dy']):>2} 发  "
              f"总上跳={total:.3f}  漂移={w['drift']:.3f}  {' '.join(bad)}")
        if bad:
            problems.append(f"武器 {w['id']}: {'; '.join(bad)}")

    if not weapons:
        problems.append("解析不到任何 make(...) 调用，正则可能已失效")
else:
    problems.append("找不到 Shared/WeaponLibrary.swift")


# --------------------------------------------------------------- 5. 标识符一致性

section("标识符一致性")

app_model = ROOT / "App" / "RecoilPadApp.swift"
if app_model.exists():
    src = app_model.read_text(encoding="utf-8")

    # broadcastExtensionID 现在是运行时计算属性（因为免费账号签名会给 bundle id
    # 加 team 后缀，写死的值对不上），所以这里不再找 `= "字面量"` 的赋值形式，
    # 改为确认它回退用的默认值是对的。
    m = re.search(r'broadcastExtensionID\s*=\s*"([^"]+)"', src)
    if m:
        declared_id = m.group(1)
        form = "静态字面量"
    else:
        # 计算属性：取里面第一个 return 的字面量 / 或 fallback 变量
        m2 = re.search(r'let\s+fallback\s*=\s*"([^"]+)"', src)
        declared_id = m2.group(1) if m2 else None
        form = "运行时解析（从 appex 的 Info.plist 读取真实 id）"

    yml_id = targets.get("RecoilPadBroadcast", {}).get("bundle_id")
    print(f" broadcastExtensionID 取值方式 = {form}")
    print(f"   回退默认值      = {declared_id}")
    print(f"   project.yml 扩展 id = {yml_id}")
    if declared_id != yml_id:
        print(" [FAIL] 回退值与 project.yml 里的扩展 bundle id 不一致")
        problems.append(f"broadcastExtensionID 回退值({declared_id}) 与扩展 bundle id({yml_id}) 不一致")
    else:
        print(" [OK ] 一致（回退路径正确）")

handler = ROOT / "Broadcast" / "SampleHandler.swift"
ext_plist = ROOT / "Support" / "Broadcast-Info.plist"
if handler.exists() and ext_plist.exists():
    src = handler.read_text(encoding="utf-8")
    class_ok = bool(re.search(r"class\s+SampleHandler\s*:\s*RPBroadcastSampleHandler", src))
    with ext_plist.open("rb") as fh:
        pid = plistlib.load(fh).get("NSExtension", {})
    principal = pid.get("NSExtensionPrincipalClass", "")
    print(f" SampleHandler 继承正确       = {class_ok}")
    print(f" NSExtensionPrincipalClass    = {principal}")
    if not class_ok:
        problems.append("SampleHandler 没有继承 RPBroadcastSampleHandler")
    if not principal.endswith(".SampleHandler"):
        problems.append(f"NSExtensionPrincipalClass 未指向 SampleHandler: {principal}")
    elif class_ok:
        print(" [OK ] 扩展入口正确")

# App Group 两边都声明
app_ent = ROOT / "Support" / "RecoilPad.entitlements"
bcast_ent = ROOT / "Support" / "Broadcast.entitlements"
group = "group.com.yg.recoilpad"
for ent in (app_ent, bcast_ent):
    if not ent.exists():
        problems.append(f"缺少 {ent.name}")
        continue
    with ent.open("rb") as fh:
        data = plistlib.load(fh)
    groups = data.get("com.apple.security.application-groups", [])
    ok = group in groups
    print(f" [{'OK ' if ok else 'FAIL'}] {ent.name:<32} App Group {group if ok else '缺失'}")
    if not ok:
        problems.append(f"{ent.name} 未声明 App Group，跨进程共享会失效")


# --------------------------------------------------------------- 结论

section("结论")
if warnings:
    for w in warnings:
        print(f" 警告: {w}")
if problems:
    print(f" {len(problems)} 个问题：")
    for p in problems:
        print(f"   - {p}")
    sys.exit(1)
print(" 全部通过。")
