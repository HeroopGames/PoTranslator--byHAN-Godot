# === PoTranslatorByHAN · 打开项目 ===
# 弹出 FileDialog 选择 .pohtran 文件 → 验证文件存在且可读 → 通过则以该文件所在目录为项目路径打开
extends Node

signal project_opened(path: String)
signal open_failed(reason: String)


## 启动打开流程：弹出文件选择对话框，筛选 .pohtran
func start_open() -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = "选择项目文件"
	dialog.ok_button_text = "打开项目"
	dialog.cancel_button_text = "取消"
	dialog.add_filter("*.pohtran", "Pohtran 项目")
	dialog.current_dir = _get_desktop_path()
	dialog.file_selected.connect(_on_file_selected.bind(dialog))
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
	var desktop_cn := home.path_join("桌面")
	if DirAccess.dir_exists_absolute(desktop_cn):
		return desktop_cn
	return home


## 用户选定 .pohtran 文件后验证
func _on_file_selected(file_path: String, dialog: FileDialog) -> void:
	dialog.queue_free()

	# 验证文件存在
	if not FileAccess.file_exists(file_path):
		open_failed.emit("项目文件不存在: " + file_path)
		return

	# 验证文件可读（试读）
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		open_failed.emit("无法读取项目文件: " + file_path)
		return
	f.close()

	# 项目路径 = .pohtran 所在目录
	var project_dir := file_path.get_base_dir()
	project_opened.emit(project_dir)
