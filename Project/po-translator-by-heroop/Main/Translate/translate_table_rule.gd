# === PoTranslatorByHAN · Excel 规则表桥接 ===
# 通过 Python + openpyxl 读取 翻译规则.xlsx，返回 JSON
# GDScript 侧运行规则引擎：正则保护 → 前后缀 → 片段匹配 → 精确匹配 → 语境 → 自定义白名单
class_name TranslateTableRule
extends RefCounted

# — Python 读取脚本（内嵌，避免外部文件依赖） —
const PY_SCRIPT := """
import json, sys, openpyxl

xlsx_path = sys.argv[1]
po_name = sys.argv[2]   # PO 文件名（不含 .po）

wb = openpyxl.load_workbook(xlsx_path, data_only=True)

def col_for_name(sheet, name):
    for c in range(1, sheet.max_column + 1):
        if str(sheet.cell(2, c).value or "").strip() == name:
            return c
    return -1

result = {
    "regex": [],         # [pattern, ...]
    "prefix": [],        # [[src, tgt], ...]
    "suffix": [],        # [[src, tgt], ...]
    "substring": [],     # [[src, tgt], ...]
    "exact": [],         # [[src, tgt], ...]
    "context": [],       # [[msgid, keyword, tgt], ...]
    "custom_exact": []   # [[src, tgt], ...]  用户自定义工作表，后命中覆盖
}

for name in wb.sheetnames:
    ws = wb[name]
    if ws.max_row < 3:
        continue
    col = col_for_name(ws, po_name)

    if name == "》正则保护":
        for r in range(3, ws.max_row + 1):
            v = str(ws.cell(r, 1).value or "").strip()
            if v:
                result["regex"].append(v)

    elif name == "》前后缀规则":
        if col > 0:
            for r in range(3, ws.max_row + 1):
                src = str(ws.cell(r, 1).value or "").strip()
                pos = str(ws.cell(r, 2).value or "").strip()
                tgt = str(ws.cell(r, col).value or "").strip()
                if src and pos and tgt:
                    if pos == "前缀":
                        result["prefix"].append([src, tgt])
                    elif pos == "后缀":
                        result["suffix"].append([src, tgt])

    elif name == "》片段匹配":
        if col > 0:
            for r in range(3, ws.max_row + 1):
                src = str(ws.cell(r, 1).value or "").strip()
                tgt = str(ws.cell(r, col).value or "").strip()
                if src and tgt:
                    result["substring"].append([src, tgt])

    elif name == "》精确匹配":
        if col > 0:
            for r in range(3, ws.max_row + 1):
                src = str(ws.cell(r, 1).value or "").strip()
                tgt = str(ws.cell(r, col).value or "").strip()
                if src and tgt:
                    result["exact"].append([src, tgt])

    elif name == "》语境翻译":
        if col > 0:
            for r in range(3, ws.max_row + 1):
                mid = str(ws.cell(r, 1).value or "").strip()
                kw  = str(ws.cell(r, 2).value or "").strip()
                tgt = str(ws.cell(r, col).value or "").strip()
                if mid and kw and tgt:
                    result["context"].append([mid, kw, tgt])

    elif not name.startswith("》"):
        # 用户自定义工作表 → 视为精确匹配（后命中覆盖）
        if col > 0:
            for r in range(3, ws.max_row + 1):
                src = str(ws.cell(r, 1).value or "").strip()
                tgt = str(ws.cell(r, col).value or "").strip()
                if src and tgt:
                    result["custom_exact"].append([src, tgt])

print(json.dumps(result, ensure_ascii=False))
"""


# — 缓存 —
var _regex_patterns: Array[RegEx] = []
var _prefix_rules: Array = []      # [{src, tgt}]
var _suffix_rules: Array = []      # [{src, tgt}]
var _substring_rules: Array = []   # [{src, tgt}]
var _exact_rules: Array = []       # [{src, tgt}]
var _context_rules: Array = []     # [{msgid, keyword, tgt}]
var _custom_exact: Array = []      # [{src, tgt}]
var _loaded: bool = false
var _po_name: String = ""


# ======== 加载 ========

## 加载 Excel 规则表（通过 Python + openpyxl）
## xlsx_path: 翻译规则.xlsx 的完整路径
## po_file_name: 当前 PO 文件名（不含 .po 后缀，用于匹配列头）
func load_rules(xlsx_path: String, po_file_name: String) -> void:
	_regex_patterns.clear()
	_prefix_rules.clear()
	_suffix_rules.clear()
	_substring_rules.clear()
	_exact_rules.clear()
	_context_rules.clear()
	_custom_exact.clear()
	_loaded = false
	_po_name = po_file_name

	if xlsx_path.is_empty() or not FileAccess.file_exists(xlsx_path):
		print("[TranslateTableRule] 规则表不存在: %s" % xlsx_path)
		return

	# 用临时文件写入 Python 脚本（避免命令行长度限制）
	var tmp_py := OS.get_user_data_dir().path_join("_po_tran_rule.py")
	var f := FileAccess.open(tmp_py, FileAccess.WRITE)
	if f == null:
		printerr("[TranslateTableRule] 无法写入临时脚本: %s" % tmp_py)
		return
	f.store_string(PY_SCRIPT)
	f.close()

	var output: Array = []
	var exit_code := OS.execute("python", [tmp_py, xlsx_path, po_file_name], output, true)
	if exit_code != 0:
		# 试 python3
		var out3: Array = []
		exit_code = OS.execute("python3", [tmp_py, xlsx_path, po_file_name], out3, true)
		if exit_code == 0:
			output = out3

	# 清理临时文件
	DirAccess.remove_absolute(tmp_py)

	if exit_code != 0 or output.is_empty():
		printerr("[TranslateTableRule] Python 执行失败，exit=%d" % exit_code)
		return

	var parsed = JSON.parse_string(output[0])
	if parsed == null or not (parsed is Dictionary):
		printerr("[TranslateTableRule] JSON 解析失败")
		return

	# — 编译正则 —
	for pat in parsed.get("regex", []):
		var re := RegEx.new()
		if re.compile(str(pat)) == OK:
			_regex_patterns.append(re)

	# — 缓存规则 —
	for r in parsed.get("prefix", []):
		if r is Array and r.size() >= 2:
			_prefix_rules.append({"src": str(r[0]), "tgt": str(r[1])})
	for r in parsed.get("suffix", []):
		if r is Array and r.size() >= 2:
			_suffix_rules.append({"src": str(r[0]), "tgt": str(r[1])})
	for r in parsed.get("substring", []):
		if r is Array and r.size() >= 2:
			_substring_rules.append({"src": str(r[0]), "tgt": str(r[1])})
	for r in parsed.get("exact", []):
		if r is Array and r.size() >= 2:
			_exact_rules.append({"src": str(r[0]), "tgt": str(r[1])})
	for r in parsed.get("context", []):
		if r is Array and r.size() >= 3:
			_context_rules.append({"msgid": str(r[0]), "keyword": str(r[1]), "tgt": str(r[2])})
	for r in parsed.get("custom_exact", []):
		if r is Array and r.size() >= 2:
			_custom_exact.append({"src": str(r[0]), "tgt": str(r[1])})

	_loaded = true
	print("[TranslateTableRule] 加载完成: regex=%d prefix=%d suffix=%d substr=%d exact=%d ctx=%d custom=%d" % [
		_regex_patterns.size(), _prefix_rules.size(), _suffix_rules.size(),
		_substring_rules.size(), _exact_rules.size(), _context_rules.size(), _custom_exact.size()
	])


## 是否已加载规则
func has_rules() -> bool:
	return _loaded


# ======== 规则引擎 ========

## 对一批待翻译条目应用规则
## entries: Array[{ "index": int, "msgid": String, "context": String }]
## 返回: { index: translated_text } — 仅包含被规则匹配到的条目
func apply_rules(entries: Array) -> Dictionary:
	var results: Dictionary = {}  # { index: translated_text }

	if entries.is_empty() or not _loaded:
		return results

	# 对每条 msgid 独立执行规则链
	for e in entries:
		var idx: int = e["index"]
		var msgid: String = e["msgid"]
		var ctx: String = e.get("context", "")
		var translated := _apply_rule_chain(msgid, ctx)
		if translated != "" and translated != msgid:
			results[idx] = translated
	return results


## 单条规则链：前后缀 → 片段匹配 → 精确匹配 → 语境 → 自定义白名单
func _apply_rule_chain(msgid: String, context: String) -> String:
	var text := msgid

	# ① 前后缀替换（叠加生效）
	for rule in _prefix_rules:
		if text.begins_with(rule["src"]):
			text = rule["tgt"] + text.substr(rule["src"].length())
	for rule in _suffix_rules:
		if text.ends_with(rule["src"]):
			text = text.substr(0, text.length() - rule["src"].length()) + rule["tgt"]

	# ② 片段替换
	for rule in _substring_rules:
		text = text.replace(rule["src"], rule["tgt"])

	# ③ 精确匹配（匹配的是经过前后缀+片段处理后的文本）
	for rule in _exact_rules:
		if text == rule["src"]:
			return rule["tgt"]

	# ④ 语境翻译（后命中覆盖，类比 CSS 级联）
	var ctx_result := ""
	for rule in _context_rules:
		if text == rule["msgid"] and rule["keyword"] in context:
			ctx_result = rule["tgt"]
	if ctx_result != "":
		return ctx_result

	# ⑤ 自定义白名单精确匹配（后命中覆盖）
	var custom_result := ""
	for rule in _custom_exact:
		if text == rule["src"]:
			custom_result = rule["tgt"]
	if custom_result != "":
		return custom_result

	# 如果经过了前后缀/片段处理，返回转换后的 text（供 API 翻译使用）
	if text != msgid:
		return text

	return ""


# ======== 正则保护 ========

## 对文本应用正则保护：匹配部分替换为占位符
## 返回 { "text": 带占位符的文本, "map": {placeholder: original} }
func apply_regex_protect(text: String) -> Dictionary:
	var pmap: Dictionary = {}
	if _regex_patterns.is_empty():
		return {"text": text, "map": pmap}

	var result := text
	var counter := 0
	for re in _regex_patterns:
		for m in re.search_all(result):
			var original := m.get_string()
			var placeholder := "__PO_PROT_%d__" % counter
			pmap[placeholder] = original
			result = result.replace(original, placeholder)
			counter += 1
	return {"text": result, "map": pmap}


## 恢复正则保护的占位符
func restore_regex_protect(text: String, pmap: Dictionary) -> String:
	if pmap.is_empty():
		return text
	var result := text
	for placeholder in pmap:
		result = result.replace(placeholder, pmap[placeholder])
	return result
