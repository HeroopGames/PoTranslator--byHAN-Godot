# === PoTranslatorByHAN · PO 文件解析器/写入器 ===
# 纯静态工具类：读取 / in-place 写入 .po 文件
# 写入时仅修改 msgid/msgstr 内容，保留所有原始格式（注释、空行、缩进、换行）
class_name PoParser
extends RefCounted


# ======== 解析（读入） ========

## 解析 .po 文件，返回 Array[{ "context": "", "msgid": "", "msgstr": "" }]
static func parse_file(file_path: String) -> Array:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return []

	var entries: Array = []
	var in_header := true
	var cur_ctx := ""
	var cur_msgid := ""
	var cur_msgstr := ""
	var collecting_msgid := false
	var collecting_msgstr := false

	while not f.eof_reached():
		var line := f.get_line()

		if line.begins_with("#"):
			continue

		if line.begins_with("msgctxt "):
			if not in_header and cur_msgid != "":
				entries.append(_build_entry(cur_ctx, cur_msgid, cur_msgstr))
			cur_ctx = _strip_po_string(line.substr(8))
			collecting_msgid = false
			collecting_msgstr = false

		elif line.begins_with("msgid "):
			var val := _strip_po_string(line.substr(6))
			if in_header and val == "":
				_slurp_multiline(f)
				in_header = false
				continue
			in_header = false
			cur_msgid = val + _read_continuation(f)
			collecting_msgid = true
			collecting_msgstr = false

		elif line.begins_with("msgstr "):
			cur_msgstr = _strip_po_string(line.substr(7)) + _read_continuation(f)
			collecting_msgid = false
			collecting_msgstr = true

		elif _is_multiline_continuation(line):
			var cont := _strip_po_string(line)
			if collecting_msgid:
				cur_msgid += cont
			elif collecting_msgstr:
				cur_msgstr += cont

		else:
			if not in_header and collecting_msgstr:
				entries.append(_build_entry(cur_ctx, cur_msgid, cur_msgstr))
				cur_msgid = ""
			collecting_msgid = false
			collecting_msgstr = false

	f.close()

	if not in_header and collecting_msgstr and cur_msgid != "":
		entries.append(_build_entry(cur_ctx, cur_msgid, cur_msgstr))

	return entries


## 解析 .po 文件，返回打包数据（线程安全，WorkerThreadPool 可用）
## 返回: { "c": PackedStringArray, "m": PackedStringArray, "s": PackedStringArray, "sl": PackedStringArray }
static func parse_file_packed(file_path: String) -> Dictionary:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return _empty_packed()

	var ctx_list: Array[String] = []
	var mid_list: Array[String] = []
	var mstr_list: Array[String] = []
	var srcloc_list: Array[String] = []
	var in_header := true
	var cur_ctx := ""
	var cur_msgid := ""
	var cur_msgstr := ""
	var cur_srcloc := ""
	var collecting_msgid := false
	var collecting_msgstr := false

	while not f.eof_reached():
		var line := f.get_line()

		if line.begins_with("#. SourceLocation:"):
			cur_srcloc = line.substr(17).strip_edges()
			continue
		elif line.begins_with("#"):
			continue

		if line.begins_with("msgctxt "):
			if not in_header and cur_msgid != "":
				ctx_list.append(cur_ctx)
				mid_list.append(cur_msgid)
				mstr_list.append(cur_msgstr)
				srcloc_list.append(cur_srcloc)
				cur_srcloc = ""
			cur_ctx = _strip_po_string(line.substr(8))
			collecting_msgid = false
			collecting_msgstr = false

		elif line.begins_with("msgid "):
			var val := _strip_po_string(line.substr(6))
			if in_header and val == "":
				_slurp_multiline(f)
				in_header = false
				continue
			in_header = false
			cur_msgid = val + _read_continuation(f)
			collecting_msgid = true
			collecting_msgstr = false

		elif line.begins_with("msgstr "):
			cur_msgstr = _strip_po_string(line.substr(7)) + _read_continuation(f)
			collecting_msgid = false
			collecting_msgstr = true

		elif _is_multiline_continuation(line):
			var cont := _strip_po_string(line)
			if collecting_msgid:
				cur_msgid += cont
			elif collecting_msgstr:
				cur_msgstr += cont

		else:
			if not in_header and collecting_msgstr:
				ctx_list.append(cur_ctx)
				mid_list.append(cur_msgid)
				mstr_list.append(cur_msgstr)
				srcloc_list.append(cur_srcloc)
				cur_msgid = ""
				cur_srcloc = ""
			collecting_msgid = false
			collecting_msgstr = false

	f.close()

	if not in_header and collecting_msgstr and cur_msgid != "":
		ctx_list.append(cur_ctx)
		mid_list.append(cur_msgid)
		mstr_list.append(cur_msgstr)
		srcloc_list.append(cur_srcloc)

	return {
		"c": PackedStringArray(ctx_list),
		"m": PackedStringArray(mid_list),
		"s": PackedStringArray(mstr_list),
		"sl": PackedStringArray(srcloc_list)
	}


static func _build_entry(ctx: String, msgid: String, msgstr: String) -> Dictionary:
	return { "context": ctx, "msgid": msgid, "msgstr": msgstr }

static func _empty_packed() -> Dictionary:
	return { "c": PackedStringArray(), "m": PackedStringArray(), "s": PackedStringArray(), "sl": PackedStringArray() }


# ======== 写入（按行遍历，仅替换 dirtied 条目的 msgid/msgstr 内容） ========

## 读入原始文本 → 按行扫描 → 脏条目重写对应字段 → 其余全部原样保留
## 用 PackedStringArray 收集行，最后一次性 join，避免 O(n²) 字符串拼接
## dirty_indices: Dictionary，key=条目索引，值为脏类型：
##   - true 或 "both": msgid 和 msgstr 都脏
##   - "msgid": 只有 msgid 脏
##   - "msgstr": 只有 msgstr 脏
static func write_file_packed(file_path: String, contexts: PackedStringArray, msgids: PackedStringArray, msgstrs: PackedStringArray, dirty_indices: Dictionary) -> void:
	var raw := FileAccess.get_file_as_string(file_path)
	if raw.is_empty():
		return

	var total_entries := msgids.size()
	if total_entries == 0:
		return

	var pieces := PackedStringArray()
	var entry_idx := 0
	var line_start := 0

	while line_start < raw.length():
		# 提取一行
		var nl := raw.find("\n", line_start)
		var line_end: int = raw.length() if nl == -1 else nl + 1
		var line := raw.substr(line_start, line_end - line_start)

		var stripped := line.strip_edges()

		if stripped.begins_with("msgid ") and entry_idx < total_entries:
			if entry_idx in dirty_indices:
				var dirty_type = dirty_indices[entry_idx]
				var msgid_dirty: bool = false
				var msgstr_dirty: bool = false
				if typeof(dirty_type) == TYPE_BOOL:
					if dirty_type:
						msgid_dirty = true
						msgstr_dirty = true
				elif typeof(dirty_type) == TYPE_STRING:
					if dirty_type == "both" or dirty_type == "msgid":
						msgid_dirty = true
					if dirty_type == "both" or dirty_type == "msgstr":
						msgstr_dirty = true

				if msgid_dirty:
					# 重写 msgid
					pieces.append(_build_po_entry("msgid", msgids[entry_idx]))
					line_start = line_end
					# 跳过原始 msgid 续行
					while line_start < raw.length():
						var nl2 := raw.find("\n", line_start)
						var le2: int = raw.length() if nl2 == -1 else nl2 + 1
						var cont := raw.substr(line_start, le2 - line_start).strip_edges()
						if _is_multiline_continuation(cont):
							line_start = le2
						else:
							break
				else:
					# 保留原始 msgid 行
					pieces.append(line)
					line_start = line_end
					# 保留原始 msgid 续行
					while line_start < raw.length():
						var nl2 := raw.find("\n", line_start)
						var le2: int = raw.length() if nl2 == -1 else nl2 + 1
						var cont := raw.substr(line_start, le2 - line_start).strip_edges()
						if _is_multiline_continuation(cont):
							pieces.append(raw.substr(line_start, le2 - line_start))
							line_start = le2
						else:
							break

				# 处理 msgstr
				if line_start < raw.length():
					var nl3 := raw.find("\n", line_start)
					var le3: int = raw.length() if nl3 == -1 else nl3 + 1
					if raw.substr(line_start, le3 - line_start).strip_edges().begins_with("msgstr "):
						if msgstr_dirty:
							# 跳过原始 msgstr 行及其续行
							line_start = le3
							while line_start < raw.length():
								var nl4 := raw.find("\n", line_start)
								var le4: int = raw.length() if nl4 == -1 else nl4 + 1
								if _is_multiline_continuation(raw.substr(line_start, le4 - line_start).strip_edges()):
									line_start = le4
								else:
									break
							# 写入新 msgstr
							pieces.append(_build_po_entry("msgstr", msgstrs[entry_idx]))
						else:
							# 保留原始 msgstr 行及续行
							pieces.append(raw.substr(line_start, le3 - line_start))
							line_start = le3
							while line_start < raw.length():
								var nl4 := raw.find("\n", line_start)
								var le4: int = raw.length() if nl4 == -1 else nl4 + 1
								if _is_multiline_continuation(raw.substr(line_start, le4 - line_start).strip_edges()):
									pieces.append(raw.substr(line_start, le4 - line_start))
									line_start = le4
								else:
									break
			else:
				# — 干净条目：原样保留 msgid 行及后续所有内容（留待后续迭代处理） —
				pieces.append(line)
				line_start = line_end

			entry_idx += 1
		else:
			# — 非 msgid 行（注释、空行、msgctxt、续行、msgstr 等），原样保留 —
			pieces.append(line)
			line_start = line_end

	# 写入文件
	var out := FileAccess.open(file_path, FileAccess.WRITE)
	if out == null:
		return
	out.store_string("".join(pieces))
	out.close()


static func _build_po_entry(prefix: String, text: String) -> String:
	if text == "":
		return prefix + ' ""\n'
	var tok := text.split("\n")
	if tok.size() <= 1:
		return prefix + " " + _po_quote(text) + "\n"
	var r := prefix + " " + _po_quote(tok[0]) + "\n"
	for j in range(1, tok.size()):
		r += '"' + _escape_po(tok[j]) + '"\n'
	return r


## 写入 PO 文件（字典数组版）：保留 header，全量序列化
static func write_file(file_path: String, entries: Array) -> void:
	var header := _read_header(file_path)
	var out := FileAccess.open(file_path, FileAccess.WRITE)
	if out == null:
		return
	if not header.is_empty():
		out.store_string(header)

	for e in entries:
		var ctx: String = e.get("context", "")
		if ctx != "":
			out.store_string("msgctxt " + _po_quote(ctx) + "\n")
		out.store_string(_format_po_entry("msgid", e.get("msgid", "")))
		out.store_string(_format_po_entry("msgstr", e.get("msgstr", "")))
		out.store_string("\n")
	out.close()


# ======== 字符串辅助 ========

static func _strip_po_string(s: String) -> String:
	var t := s.strip_edges()
	if t.begins_with("\"") and t.ends_with("\""):
		t = t.substr(1, t.length() - 2)
	return t.replace("\\n", "\n").replace("\\t", "\t").replace("\\\"", "\"").replace("\\\\", "\\")

static func _po_quote(s: String) -> String:
	return "\"" + _escape_po(s) + "\""

static func _escape_po(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", "\\t")

static func _is_multiline_continuation(line: String) -> bool:
	return line.strip_edges().begins_with("\"")

static func _read_continuation(file: FileAccess) -> String:
	var result := ""
	while not file.eof_reached():
		var pos_before := file.get_position()
		var line := file.get_line()
		if _is_multiline_continuation(line):
			result += _strip_po_string(line)
		else:
			file.seek(pos_before)
			break
	return result

static func _read_header(file_path: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return ""
	var raw := f.get_as_text()
	f.close()

	var first := raw.find("\nmsgctxt ")
	if first == -1:
		first = raw.find("\nmsgid ")
	if first == -1 and (raw.begins_with("msgctxt ") or raw.begins_with("msgid ")):
		first = 0
	if first > 0:
		return raw.substr(0, first + 1)
	elif first == -1:
		return raw
	return ""

static func _format_po_entry(prefix: String, text: String) -> String:
	if text == "":
		return prefix + " \"\"\n"
	var lines := text.split("\n")
	if lines.size() <= 1:
		return prefix + " " + _po_quote(text) + "\n"

	var result := prefix + " " + _po_quote(lines[0]) + "\n"
	var last := lines.size() - 1
	for i in range(1, last):
		result += "\"" + _escape_po(lines[i]) + "\"\n"
	if lines[last] != "":
		result += "\"" + _escape_po(lines[last]) + "\"\n"
	else:
		result += "\"\"\n"
	return result

static func _slurp_multiline(file: FileAccess):
	while not file.eof_reached():
		var pos_before := file.get_position()
		var line := file.get_line()
		var s := line.strip_edges()
		if not (s.begins_with("\"") and s != "\"\""):
			file.seek(pos_before)
			break
