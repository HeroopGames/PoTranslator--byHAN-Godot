# === PoTranslatorByHAN · PO 条目行（虚拟列表复用单元·双态） ===
# 显示态：Label（轻量）  |  编辑态：TextEdit（点击切换）
# Enter=保存并退回显示态 | Shift+Enter=换行 | Esc=取消编辑 | 焦点离开=自动保存
class_name PoEntry
extends Control

signal entry_saved(entry_index: int, field: String, new_text: String)

@onready var src_label: Label = $Row/SrcLabel
@onready var src_edit: TextEdit = $Row/SrcEdit
@onready var dst_label: Label = $Row/DstLabel
@onready var dst_edit: TextEdit = $Row/DstEdit
@onready var blur_bg: ColorRect = $BlurBg
@onready var backbuffer_copy: BackBufferCopy = $BackBufferCopy

enum EditMode { NONE, SRC, DST }

var _entry_index: int = -1
var _edit_mode: EditMode = EditMode.NONE
var original_src: String = ""
var original_dst: String = ""
var _source: String = ""  # "manual" | "rule" | "memory" | "ai" | "" = 未翻译


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
	src_label.text = msgid
	src_edit.text = msgid
	dst_label.text = msgstr
	dst_edit.text = msgstr

	_apply_colors()
	$Row.queue_sort()


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
	dst_label.add_theme_color_override("font_color", c)
	dst_edit.add_theme_color_override("font_color", c)


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
		src_label.text = new_text
		original_src = new_text
	else:
		dst_label.text = new_text
		original_dst = new_text
	_apply_colors()
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
		src_label.text = save_text
		original_src = save_text
	else:
		dst_label.text = save_text
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
