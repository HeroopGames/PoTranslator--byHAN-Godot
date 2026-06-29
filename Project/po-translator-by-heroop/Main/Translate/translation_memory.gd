# === PoTranslatorByHAN · 翻译记忆 ===
# 以 msgid 为 key，记录每条 msgid 被翻译的次数和结果
# 同一 msgid 翻译 2 次及以上 → 存入记忆，后续翻译命中时优先使用
class_name TranslationMemory
extends RefCounted

var _mem_path: String
var _data: Dictionary = {}  # { "msgid": {"text": "译文", "count": int} }

## 初始化记忆文件路径
func init(memory_dir: String):
	_mem_path = memory_dir.path_join("translate_memory.json")
	_load()

## 从文件加载记忆数据
func _load():
	if not FileAccess.file_exists(_mem_path):
		return
	var f := FileAccess.open(_mem_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var err := json.parse(f.get_as_text())
	f.close()
	if err != OK:
		return
	_data = json.data if json.data is Dictionary else {}

## 保存记忆数据到文件（紧凑格式，无缩进，写入更快）
func save():
	var dir := _mem_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(_mem_path, FileAccess.WRITE)
	if f == null:
		printerr("[TranslationMemory] 无法写入: ", _mem_path)
		return
	var json := JSON.stringify(_data)
	f.store_string(json)
	f.close()

## 查询记忆：msgid 命中且 count >= 2 时返回译文，否则返回空字符串
func lookup(msgid: String) -> String:
	if not _data.has(msgid):
		return ""
	var entry: Dictionary = _data[msgid]
	if entry.get("count", 0) >= 2:
		return entry.get("text", "")
	return ""

## 记录一次翻译结果：增加计数，≥2 时更新译文
func record(msgid: String, translated_text: String):
	if _data.has(msgid):
		var entry: Dictionary = _data[msgid]
		var count: int = entry.get("count", 0) + 1
		entry["count"] = count
		if count >= 2:
			entry["text"] = translated_text
	else:
		_data[msgid] = {"text": translated_text, "count": 1}

## 获取记忆条目数量（用于统计）
func size() -> int:
	return _data.size()
