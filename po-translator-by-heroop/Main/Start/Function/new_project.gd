# === PoTranslatorByHAN · 新建项目 ===
# 弹出 FileDialog 选择父目录 → 输入项目名 → 创建项目文件夹 → 复制模板 + 生成 project.pohtran
extends Node

signal project_created(path: String)
signal creation_failed(reason: String)

const TEMPLATE_PATH: String = "res://Main/Start/Function/template/"
const POHTRAN_FILE: String = "project.pohtran"


## 启动新建流程：弹出目录选择对话框
func start_new() -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "选择项目存放目录"
	dialog.ok_button_text = "在此创建"
	dialog.cancel_button_text = "取消"
	dialog.current_dir = _get_desktop_path()
	dialog.dir_selected.connect(_on_parent_dir_selected.bind(dialog))
	dialog.canceled.connect(func(): dialog.queue_free())
	get_tree().root.add_child(dialog)
	_localize_file_dialog(dialog)
	dialog.popup_centered_ratio(0.65)


## 将 FileDialog 内部按钮文本本地化为中文
func _localize_file_dialog(dialog: FileDialog) -> void:
	var text_map := {
		"Delete": "删除",
		"Create Folder": "新建文件夹",
		"Refresh": "刷新",
		"Show Hidden Files": "显示隐藏文件",
		"Filename": "文件名",
		"Filter": "筛选",
		"Favorites": "收藏夹",
		"Computer": "此电脑",
		"Res://": "项目资源",
		"User://": "用户目录",
	}
	var buttons := dialog.find_children("*", "Button", true, false)
	for btn in buttons:
		if btn is Button:
			var txt: String = btn.text
			if text_map.has(txt):
				btn.text = text_map[txt]
	var labels := dialog.find_children("*", "Label", true, false)
	for lbl in labels:
		if lbl is Label:
			var txt: String = lbl.text
			if text_map.has(txt):
				lbl.text = text_map[txt]


func _get_desktop_path() -> String:
	var home := OS.get_environment("USERPROFILE")
	if home.is_empty():
		home = OS.get_environment("HOME")
	if home.is_empty():
		return ""
	var desktop := home.path_join("Desktop")
	if DirAccess.dir_exists_absolute(desktop):
		return desktop
	# 中文 Windows：桌面 文件夹
	var desktop_cn := home.path_join("桌面")
	if DirAccess.dir_exists_absolute(desktop_cn):
		return desktop_cn
	return home


## 用户选完父目录后，弹出名称输入
func _on_parent_dir_selected(parent_dir: String, dialog: FileDialog) -> void:
	dialog.queue_free()
	_ask_project_name(parent_dir)


func _ask_project_name(parent_dir: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "新建项目"
	dialog.ok_button_text = "创建"

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(360, 0)

	var label := Label.new()
	label.text = "项目名称："
	vbox.add_child(label)

	var line_edit := LineEdit.new()
	line_edit.placeholder_text = "输入项目名称"
	line_edit.custom_minimum_size = Vector2(0, 32)
	vbox.add_child(line_edit)

	dialog.add_child(vbox)
	dialog.confirmed.connect(func():
		var proj_name := line_edit.text.strip_edges()
		if proj_name.is_empty():
			creation_failed.emit("项目名称不能为空")
			dialog.queue_free()
			return
		_create_project(parent_dir, proj_name)
		dialog.queue_free()
	)

	get_tree().root.add_child(dialog)
	dialog.popup_centered()
	line_edit.grab_focus()


## 创建项目文件夹、复制模板、生成 project.pohtran
func _create_project(parent_dir: String, project_name: String) -> void:
	var project_path := parent_dir.path_join(project_name)

	# 检查路径是否已存在
	if DirAccess.dir_exists_absolute(project_path):
		creation_failed.emit("路径已存在: " + project_path)
		return

	# 创建项目目录
	var err := DirAccess.make_dir_recursive_absolute(project_path)
	if err != OK:
		creation_failed.emit("创建目录失败: " + project_path)
		return

	# 复制模板文件（跳过 project.pohtran 模板，后面单独生成）
	var template_dirs := DirAccess.open(TEMPLATE_PATH)
	if template_dirs == null:
		creation_failed.emit("无法读取模板目录: " + TEMPLATE_PATH)
		return

	template_dirs.list_dir_begin()
	var file_name := template_dirs.get_next()
	while file_name != "":
		if not file_name.begins_with(".") and file_name != POHTRAN_FILE:
			var src := TEMPLATE_PATH.path_join(file_name)
			var dst := project_path.path_join(file_name)
			if template_dirs.current_is_dir():
				DirAccess.make_dir_recursive_absolute(dst)
				_copy_dir_recursive(src, dst)
			else:
				DirAccess.copy_absolute(src, dst)
		file_name = template_dirs.get_next()
	template_dirs.list_dir_end()

	# 生成 project.pohtran（读取模板中的 license 数组 + 当前日期）
	var template_pohtran_path := TEMPLATE_PATH.path_join(POHTRAN_FILE)
	var license_lines: Array = []
	var tpl_file := FileAccess.open(template_pohtran_path, FileAccess.READ)
	if tpl_file != null:
		var tpl_json = JSON.parse_string(tpl_file.get_as_text())
		tpl_file.close()
		if tpl_json != null and tpl_json.has("license"):
			license_lines = tpl_json["license"]

	var pohtran_dict := {
		"version": 1,
		"name": project_name,
		"created": Time.get_datetime_string_from_system(),
		"license": license_lines
	}
	var pohtran_content := JSON.stringify(pohtran_dict, "\t")
	var pohtran_path := project_path.path_join(POHTRAN_FILE)
	var pohtran_file := FileAccess.open(pohtran_path, FileAccess.WRITE)
	if pohtran_file == null:
		creation_failed.emit("无法创建项目标记文件: " + pohtran_path)
		return
	pohtran_file.store_string(pohtran_content)
	pohtran_file.close()

	var memory_dir := project_path.path_join("翻译记忆")
	DirAccess.make_dir_recursive_absolute(memory_dir)
	var memory_file_path := memory_dir.path_join("translate_memory.json")
	var memory_file := FileAccess.open(memory_file_path, FileAccess.WRITE)
	if memory_file != null:
		memory_file.store_string("{}")
		memory_file.close()

	project_created.emit(project_path)


func _copy_dir_recursive(src: String, dst: String) -> void:
	var dir := DirAccess.open(src)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			var src_file := src.path_join(file_name)
			var dst_file := dst.path_join(file_name)
			if dir.current_is_dir():
				DirAccess.make_dir_recursive_absolute(dst_file)
				_copy_dir_recursive(src_file, dst_file)
			else:
				DirAccess.copy_absolute(src_file, dst_file)
		file_name = dir.get_next()
	dir.list_dir_end()
