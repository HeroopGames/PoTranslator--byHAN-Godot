# === PoTranslatorByHAN · PO 条目行（虚拟列表复用单元·双态） ===
# 显示态：Label（轻量）  |  编辑态：TextEdit（点击切换）
# Enter=保存并退回显示态 | Shift+Enter=换行 | Esc=取消编辑 | 焦点离开=自动保存
class_name PoEntry
extends Control

signal entry_saved(entry_index: int, field: String, new_text: String)
signal entry_hovered(entry_index: int)
signal entry_unhovered(entry_index: int)
signal entry_checked(entry_index: int, checked: bool)
signal entry_translate(entry_index: int)
signal entry_translate_stop(entry_index: int)

@onready var src_label: RichTextLabel = $Row/SrcLabel
@onready var src_edit: TextEdit = $Row/SrcEdit
@onready var dst_label: RichTextLabel = $Row/DstLabel
@onready var dst_edit: TextEdit = $Row/DstEdit
@onready var chk_select: CheckBox = $Row/ChkSelect
@onready var translate_btn: Button = $Row/TranslateBtn
@onready var blur_bg: ColorRect = $BlurBg
@onready var backbuffer_copy: BackBufferCopy = $BackBufferCopy

enum EditMode { NONE, SRC, DST }

var _entry_index: int = -1
var _edit_mode: EditMode = EditMode.NONE
var _is_translating: bool = false
var original_src: String = ""
var original_dst: String = ""
var _source: String = ""  # "manual" | "rule" | "memory" | "ai" | "" = 未翻译

# — 高亮缓存：上次高亮用的搜索词和原始文本 —
var _last_search_text: String = ""
var _last_src_text: String = ""
var _last_dst_text: String = ""


# --------------------- 静态工具：行高估算 ---------------------

## 估算条目行高度（msgid 与 msgstr 取行数较大者）
## label_width 为整行宽度，内部两个 Label 各分半宽
static func measure_height(msgid: String, msgstr: String, label_width: float) -> float:
	var half_w := maxf(label_width - 26.0, 20.0) / 2.0
	var font := ThemeDB.get_default_theme().get_default_font()
	var s1 := font.get_string_size(msgid, HORIZONTAL_ALIGNMENT_LEFT, half_w, 14)
	var text2 := msgstr if not msgstr.is_empty() else msgid
	var s2 := font.get_string_size(text2, HORIZONTAL_ALIGNMENT_LEFT, half_w, 14)
	return maxf(maxf(s1.y, s2.y), 20.0) + 36.0


# --------------------- 数据填充（虚拟列表复用时调用） ---------------------

## 填充条目数据并重置为显示态（直接传参，避免每帧 new Dictionary）
func set_entry(msgid: String, msgstr: String, source: String, row_height: float, entry_index: int):
	_entry_index = entry_index
	custom_minimum_size.y = row_height
	size.y = row_height

	# 先改模式再隐藏控件，防止隐藏时触发 focus_exited 保存
	_edit_mode = EditMode.NONE
	src_label.visible = true
	src_edit.visible = false
	dst_label.visible = true
	dst_edit.visible = false

	original_src = msgid
	original_dst = msgstr
	_source = source
	src_edit.text = msgid
	dst_edit.text = msgstr
	src_label.text = _escape_bbcode(msgid)
	dst_label.text = _escape_bbcode(msgstr)

	# 存储原始文本用于高亮重建
	_last_src_text = msgid
	_last_dst_text = msgstr
	_last_search_text = ""

	_apply_colors()
	$Row.queue_sort()


# --------------------- 搜索高亮 ---------------------

## 对 src_label 和 dst_label 应用搜索高亮（匹配文本加灰色背景）
func apply_search_highlight(search_text: String):
	if search_text == _last_search_text and original_src == _last_src_text and original_dst == _last_dst_text:
		return
	_last_search_text = search_text
	_last_src_text = original_src
	_last_dst_text = original_dst

	src_label.text = _build_highlighted_text(original_src, search_text)
	dst_label.text = _build_highlighted_text(original_dst, search_text)

## 构建带高亮的 BBCode 文本（不区分大小写匹配）
func _build_highlighted_text(raw: String, search: String) -> String:
	if search.is_empty() or raw.is_empty():
		return _escape_bbcode(raw)
	var result := ""
	var lower_raw := raw.to_lower()
	var lower_search := search.to_lower()
	var pos := 0
	while pos < raw.length():
		var found := lower_raw.find(lower_search, pos)
		if found == -1:
			result += _escape_bbcode(raw.substr(pos))
			break
		# 匹配前的普通文本
		if found > pos:
			result += _escape_bbcode(raw.substr(pos, found - pos))
		# 匹配的高亮文本
		var matched := raw.substr(found, search.length())
		result += "[bgcolor=#555555]" + _escape_bbcode(matched) + "[/bgcolor]"
		pos = found + search.length()
	return result

## 转义 BBCode 特殊字符
func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")


# --------------------- 颜色 ---------------------

## 根据翻译来源设置 Label 颜色：手动=绿，规则=黄，记忆=紫，AI=蓝，未翻译=红
func _apply_colors():
	var c: Color
	if original_dst != "" and original_dst != original_src:
		match _source:
			"manual": c = Color(0.3, 1, 0.5, 1)    # 绿色
			"rule":   c = Color(1, 0.85, 0.3, 1)   # 黄色
			"memory": c = Color(0.7, 0.35, 1, 1)   # 紫色
			"ai":     c = Color(0.35, 0.6, 1, 1)   # 蓝色
			_:        c = Color(0.3, 1, 0.5, 1)    # 默认绿色（兼容旧数据）
	else:
		c = Color(0.85, 0.35, 0.35, 1)  # 红色 未翻译
	dst_label.add_theme_color_override("default_color", c)
	dst_edit.add_theme_color_override("font_color", c)
	# 重新应用高亮以刷新颜色
	_last_search_text = ""  # 强制重建高亮


# --------------------- 复选框 ---------------------

## 设置复选框状态（不触发信号）
func set_checked(checked: bool):
	chk_select.set_block_signals(true)
	chk_select.button_pressed = checked
	chk_select.set_block_signals(false)

## 获取当前复选框状态
func is_checked() -> bool:
	return chk_select.button_pressed


# --------------------- 编辑态切换 ---------------------

## 进入编辑态（显示 TextEdit，隐藏 Label，抢焦点）
func _switch_to_edit(which: EditMode):
	_edit_mode = which
	print("[PoEntry] 试图手动修改PO")
	# 更新 BackBufferCopy 区域并显示模糊背景
	_update_blur_rect()
	blur_bg.visible = true
	if which == EditMode.SRC:
		src_label.visible = false
		src_edit.visible = true
		src_edit.grab_focus()
	else:
		dst_label.visible = false
		dst_edit.visible = true
		dst_edit.grab_focus()
	$Row.queue_sort()

## 退出编辑态回到显示态（不保存，仅切换 UI）
func _switch_to_display():
	if _edit_mode == EditMode.NONE:
		return
	var prev := _edit_mode
	_edit_mode = EditMode.NONE
	blur_bg.visible = false
	if prev == EditMode.SRC:
		src_label.visible = true
		src_edit.visible = false
	else:
		dst_label.visible = true
		dst_edit.visible = false
	$Row.queue_sort()

## 更新 BackBufferCopy 区域以匹配当前条目大小
func _update_blur_rect():
	backbuffer_copy.rect = Rect2(Vector2.ZERO, size)


# --------------------- 保存 / 取消 ---------------------

## 保存修改并退回显示态（Enter / 焦点离开 触发）
func _commit_and_display(field: String, new_text: String):
	_save_field(field, new_text)
	print("[PoEntry] PO修改完成")
	if field == "msgid":
		original_src = new_text
		src_label.text = _escape_bbcode(new_text)
	else:
		original_dst = new_text
		dst_label.text = _escape_bbcode(new_text)
		_apply_colors()
	_last_search_text = ""  # 强制重建高亮
	_switch_to_display()

## 丢弃修改并退回显示态（Esc 触发）
func _cancel_and_display(which: EditMode):
	if which == EditMode.SRC:
		src_edit.text = original_src
	else:
		dst_edit.text = original_dst
	_switch_to_display()

## 发出保存信号
func _save_field(field: String, text: String):
	if _entry_index < 0:
		return
	entry_saved.emit(_entry_index, field, text)


# --------------------- 字段间切换辅助（点击另一 Label） ---------------------

## 保存当前编辑字段后切换到另一字段的编辑态
func _save_and_switch(save_field: String, save_text: String, target_mode: EditMode):
	_save_field(save_field, save_text)
	if save_field == "msgid":
		original_src = save_text
	else:
		original_dst = save_text
		_apply_colors()
	_edit_mode = EditMode.NONE  # 先改模式，防止隐藏时焦点离开触发重复保存
	src_label.visible = true
	src_edit.visible = false
	dst_label.visible = true
	dst_edit.visible = false
	_switch_to_edit(target_mode)


# --------------------- Label 点击事件 ---------------------

## 点击原文本 Label → 进入 SRC 编辑态
func _on_src_label_clicked(event: InputEvent):
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	match _edit_mode:
		EditMode.SRC: return
		EditMode.DST: _save_and_switch("msgstr", dst_edit.text, EditMode.SRC)
		_: _switch_to_edit(EditMode.SRC)
	get_viewport().set_input_as_handled()

## 点击译文 Label → 进入 DST 编辑态
func _on_dst_label_clicked(event: InputEvent):
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	match _edit_mode:
		EditMode.DST: return
		EditMode.SRC: _save_and_switch("msgid", src_edit.text, EditMode.DST)
		_: _switch_to_edit(EditMode.DST)
	get_viewport().set_input_as_handled()


# --------------------- 键盘输入拦截 ---------------------

## 拦截 Enter / Esc 键（仅当本条目内的 TextEdit 获得焦点时生效）
func _input(event: InputEvent):
	if not (event is InputEventKey and event.pressed and not event.is_echo()):
		return

	var focused := get_viewport().gui_get_focus_owner()
	if focused != src_edit and focused != dst_edit:
		return

	match event.keycode:
		KEY_ENTER when not event.shift_pressed:
			get_viewport().set_input_as_handled()
			if focused == src_edit:
				_commit_and_display("msgid", src_edit.text)
			else:
				_commit_and_display("msgstr", dst_edit.text)
		KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_cancel_and_display(EditMode.SRC if focused == src_edit else EditMode.DST)


# --------------------- 焦点离开自动保存 ---------------------

## SRC 编辑框失去焦点 → 自动保存 msgid
func _on_src_focus_exited():
	if _edit_mode == EditMode.SRC and _entry_index >= 0:
		_commit_and_display("msgid", src_edit.text)

## DST 编辑框失去焦点 → 自动保存 msgstr
func _on_dst_focus_exited():
	if _edit_mode == EditMode.DST and _entry_index >= 0:
		_commit_and_display("msgstr", dst_edit.text)


# --------------------- 鼠标悬停 ---------------------

func _ready():
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	chk_select.toggled.connect(_on_chk_toggled)
	translate_btn.pressed.connect(_on_translate_btn_pressed)

func _on_mouse_entered():
	if _entry_index >= 0:
		entry_hovered.emit(_entry_index)

func _on_mouse_exited():
	if _entry_index >= 0:
		entry_unhovered.emit(_entry_index)

func _on_chk_toggled(checked: bool):
	if _entry_index >= 0:
		entry_checked.emit(_entry_index, checked)

func _on_translate_btn_pressed():
	if _entry_index < 0:
		return
	if _is_translating:
		entry_translate_stop.emit(_entry_index)
	else:
		entry_translate.emit(_entry_index)


# --------------------- 翻译状态 ---------------------

## 设置“翻译中”状态：msgstr 显示为“翻译中。。。”，按钮变为“停止”
func set_translating(is_translating: bool):
	_is_translating = is_translating
	translate_btn.disabled = false
	if is_translating:
		translate_btn.text = "停止"
		dst_label.text = "翻译中。。。"
		dst_label.add_theme_color_override("default_color", Color(0.5, 0.75, 1, 1))
		# 退出编辑态，避免编辑中触发翻译
		if _edit_mode == EditMode.DST:
			_switch_to_display()
	else:
		translate_btn.text = "翻译"

## 设置“翻译失败”状态：msgstr 显示为“翻译失败”，恢复翻译按钮可用
func set_translate_failed():
	_is_translating = false
	translate_btn.disabled = false
	translate_btn.text = "翻译"
	dst_label.text = "翻译失败"
	dst_label.add_theme_color_override("default_color", Color(1, 0.5, 0.4, 1))
	# 退出编辑态，避免编辑中触发翻译
	if _edit_mode == EditMode.DST:
		_switch_to_display()
