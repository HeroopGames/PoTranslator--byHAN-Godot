# === PoTranslatorByHAN · 翻译界面 ===
# 左上：API 下拉  |  右上：关闭按钮  |  中央：PO 文件选项卡（虚拟列表，固定行高）
# 数据流：全量解析 + 内存数组 + 脏标记 + 延迟批量写回
extends Control

const PoParser = preload("res://Main/Translate/po_parser.gd")
const PoEntryScene = preload("res://Main/Translate/PO/po_entry.tscn")
const PythonBridge = preload("res://Main/Translate/python_http_bridge.gd")
const TranslationMemory = preload("res://Main/Translate/translation_memory.gd")
const ROW_HEIGHT: float = 56.0
const MAX_HIDDEN_POOL: int = 120
const TRANSLATE_BATCH_SIZE: int = 10
const PROGRESS_POLL_MS: int = 300

signal translation_closed

var _project_path: String
var _loaded: bool = false

# — PO 数据存储（key=文件名，仅加载过的文件有数据）
var _po_data: Dictionary = {}
var _po_file_list: Dictionary = {}  # { "file_name": "full_path" }  — 未加载文件路径
var _current_file_name: String = ""

# — 脏数据缓存（_dirty_entries: key=条目索引，存在即表示有 msgid 或 msgstr 修改）
var _dirty_entries: Dictionary = {}
var _dirty_files: Dictionary = {}
var _translation_source: Dictionary = {}

# — 翻译记忆
var _translation_memory: RefCounted = null
var _memory_dirty: bool = false

# — 加载状态
var _loading_file: bool = false
var _thread_result: Dictionary = {}  # 后台线程解析结果暂存

# — 搜索过滤
var _search_text: String = ""
var _exact_search_text: String = ""
var _filtered_indices: Array[int] = []
var _filter_active: bool = false

# — 复选框选中状态（key=条目索引）
var _checked_entries: Dictionary = {}

# — 单条翻译状态 —
var _single_translate_queue: Array[int] = []
var _single_translate_current: int = -1
var _translating_entries: Dictionary = {}  # key=条目索引，正在翻译中
var _failed_entries: Dictionary = {}       # key=条目索引，翻译失败
var _single_translate_task_id: int = -1
var _single_translate_timer: Timer = null
var _single_translate_result_holder: Dictionary = {}

# — 虚拟列表状态
var _entry_heights: Array[float] = []
var _entry_y: Array[float] = []
var _entry_pool: Array[PoEntry] = []
var _hidden_pool: Array[PoEntry] = []   # 缓存已 hide 的节点，避免反复实例化/销毁
var _first_drawn: int = -1
var _last_drawn: int = -1
var _pending_refresh: bool = false

# — 翻译状态 —
var _translating: bool = false
var _cancel_requested: bool = false
var _translate_done: int = 0
var _translate_total: int = 0
var _last_reloaded_done: int = 0
var _lang_list: Array = []
var _toast_label: Label = null
var _toast_click_to_close: bool = false
var _progress_poll_timer: Timer = null

# — 长按清空定时器
var _clear_press_timer: Timer
var _clear_pressing: bool = false

# — API 检测状态
var _api_checking: bool = false
var _api_available: bool = false
var _api_check_task_id: int = -1
var _api_check_timer: Timer = null
var _api_check_result_holder: Dictionary = {}

# — 一键翻译任务（用于取消/关闭时释放 WorkerThreadPool 槽位）
var _translate_task_id: int = -1
# 尚未被 wait_for_task_completion 收集的已完成/在途任务 id
var _orphan_tasks: Array[int] = []

# — API URL 配置（每个 API 独立记忆输入的 URL）
const API_DEFAULT_URLS := {
	"simplytranslate": "http://localhost:5000",
	"lingva": "http://localhost:3000",
}
var _api_url_key: String = "simplytranslate"
var _api_url_edits: Dictionary = {}
var _api_selected_index_backup: int = 0

# — UI 节点
@onready var api_option: OptionButton = $TopBar/ApiOption
@onready var api_check_btn: Button = $TopBar/ApiCheckBtn
@onready var api_url_edit: LineEdit = $TopBar/ApiUrlEdit
@onready var api_url_label: Label = $TopBar/ApiUrlLabel
@onready var main_panel: Panel = $MainPanel
@onready var tab_bar: HBoxContainer = $MainPanel/TabBar
@onready var content_scroll: ScrollContainer = $MainPanel/ContentScroll
@onready var po_list_container: Control = $MainPanel/ContentScroll/PoListContainer
@onready var translate_btn: Button = $TranslateBtn
@onready var translate_progress_box: Panel = $TranslateProgressBox
@onready var translate_progress_bar: ProgressBar = $TranslateProgressBox/TranslateProgressVBox/TranslateProgressBar
@onready var translate_progress_label: Label = $TranslateProgressBox/TranslateProgressVBox/TranslateProgressLabel
@onready var clear_msgstr_btn: Button = $ClearMsgstrBtn
@onready var refresh_btn: Button = $RefreshBtn
@onready var http_request: HTTPRequest = $HttpRequest
@onready var src_lang_option: OptionButton = $TopBar/SrcLangOption
@onready var target_lang_option: OptionButton = $TopBar/TargetLangOption
@onready var search_edit: LineEdit = $MainPanel/SearchEdit
@onready var exact_search_edit: LineEdit = $MainPanel/ExactSearchEdit
@onready var chk_all: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkAll
@onready var chk_ai: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkAI
@onready var chk_manual: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkManual
@onready var chk_rule: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkRule
@onready var chk_memory: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkMemory
@onready var chk_untranslated: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkUntranslated
@onready var chk_empty: CheckBox = $MainPanel/FilterScroll/FilterCheckRow/ChkEmpty
@onready var loading_overlay: ColorRect = $LoadingOverlay
@onready var detail_panel: Panel = $DetailPanel
@onready var detail_index_label: Label = $DetailPanel/DetailScroll/DetailVBox/InfoHBox/IndexLabel
@onready var detail_source_label: Label = $DetailPanel/DetailScroll/DetailVBox/InfoHBox/SourceLabel
@onready var detail_context_label: Label = $DetailPanel/DetailScroll/DetailVBox/ContextLabel
@onready var detail_srcloc_title: Label = $DetailPanel/DetailScroll/DetailVBox/SrcLocTitle
@onready var detail_srcloc_content: Label = $DetailPanel/DetailScroll/DetailVBox/SrcLocContent
@onready var detail_sep2: HSeparator = $DetailPanel/DetailScroll/DetailVBox/Sep2
@onready var detail_sep3: HSeparator = $DetailPanel/DetailScroll/DetailVBox/Sep3
@onready var detail_sep4: HSeparator = $DetailPanel/DetailScroll/DetailVBox/Sep4
@onready var detail_sep5: HSeparator = $DetailPanel/DetailScroll/DetailVBox/Sep5
@onready var detail_sep6: HSeparator = $DetailPanel/DetailScroll/DetailVBox/Sep6
@onready var detail_msgid_content: Label = $DetailPanel/DetailScroll/DetailVBox/MsgidContent
@onready var detail_msgstr_content: Label = $DetailPanel/DetailScroll/DetailVBox/MsgstrContent
@onready var detail_dirty_label: Label = $DetailPanel/DetailScroll/DetailVBox/DirtyLabel
@onready var replace_btn: Button = $TopBar/ReplaceBtn
@onready var replace_edit: LineEdit = $TopBar/ReplaceEdit
@onready var detail_glow_top: ColorRect = $DetailPanel/GlowLineTop
@onready var detail_glow_bottom: ColorRect = $DetailPanel/GlowLineBottom
@onready var detail_scan_line: ColorRect = $DetailPanel/ScanLine
var _detail_hover_idx: int = -1
var _glow_pulse_time: float = 0.0
var _scan_line_pos: float = 0.0


# ======== 生命周期 ========

func _notification(what: int):
	if what == NOTIFICATION_PREDELETE:
		if _translating:
			PythonBridge.cancel_translate()

func _exit_tree():
	# 节点退出前回收所有在途任务，确保 WorkerThreadPool 线程槽全部释放，
	# 否则槽位泄漏会在后续 add_task 时永久阻塞主线程（表现为软件/系统卡死）
	_kill_api_check_timer()
	_kill_single_translate_timer()
	_kill_progress_timer()
	if _api_check_task_id >= 0:
		_release_task(_api_check_task_id)
		_api_check_task_id = -1
	if _single_translate_task_id >= 0:
		_release_task(_single_translate_task_id)
		_single_translate_task_id = -1
	if _translate_task_id >= 0:
		PythonBridge.cancel_translate()
		_release_task(_translate_task_id)
		_translate_task_id = -1
	for tid in _orphan_tasks:
		_release_task(tid)
	_orphan_tasks.clear()

func _ready():
	clear_msgstr_btn.button_down.connect(_on_clear_btn_down)
	clear_msgstr_btn.button_up.connect(_on_clear_btn_up)
	_clear_press_timer = Timer.new()
	_clear_press_timer.one_shot = true
	_clear_press_timer.wait_time = 1.5
	_clear_press_timer.timeout.connect(_on_clear_long_press)
	add_child(_clear_press_timer)

	search_edit.text_submitted.connect(_on_search_text_submitted)
	exact_search_edit.text_submitted.connect(_on_exact_search_text_submitted)

	refresh_btn.pressed.connect(_on_refresh_pressed)
	replace_btn.pressed.connect(_on_replace_pressed)

	chk_all.toggled.connect(_on_all_toggled)
	chk_ai.toggled.connect(_on_filter_toggled)
	chk_manual.toggled.connect(_on_filter_toggled)
	chk_rule.toggled.connect(_on_filter_toggled)
	chk_memory.toggled.connect(_on_filter_toggled)
	chk_untranslated.toggled.connect(_on_filter_toggled)
	chk_empty.toggled.connect(_on_filter_toggled)

	_setup_api_options()
	_setup_lang_options()
	translate_progress_box.visible = false
	_update_api_url_visibility()

	api_option.item_selected.connect(_on_api_option_selected)

	_toast_label = Label.new()
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", 15)
	_toast_label.add_theme_color_override("font_color", Color(0.3, 1, 0.5, 1))
	_toast_label.visible = false
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toast_label)

func _process(delta: float):
	_reap_orphan_tasks()
	if _pending_refresh:
		_pending_refresh = false
		_do_refresh_visible_rows()
	_glow_pulse_time += delta
	var pulse := 0.4 + 0.2 * sin(_glow_pulse_time * 2.0)
	if detail_glow_top:
		detail_glow_top.color = Color(0.3, 1, 0.5, pulse)
	if detail_glow_bottom:
		detail_glow_bottom.color = Color(0.3, 1, 0.5, pulse)
	if detail_scan_line and detail_panel:
		_scan_line_pos += delta * 40.0
		var panel_h := detail_panel.size.y
		if _scan_line_pos > panel_h:
			_scan_line_pos = -4.0
		detail_scan_line.position.y = _scan_line_pos

func _unhandled_input(event: InputEvent):
	if _toast_click_to_close and _toast_label and _toast_label.visible:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_hide_toast()
			get_viewport().set_input_as_handled()


# ======== 静态入口 / UI 事件 ========

static func open(project_path: String, on_closed: Callable):
	var scene := load("res://Main/Translate/translate.tscn") as PackedScene
	var instance := scene.instantiate()
	Engine.get_main_loop().root.add_child(instance)
	instance.setup(project_path)
	instance.translation_closed.connect(func():
		instance.queue_free()
		on_closed.call()
	)

func setup(project_path: String):
	_project_path = project_path
	if not _loaded:
		_start_loading()

func _on_close_pressed():
	if _translating:
		_cancel_requested = true
		PythonBridge.cancel_translate()
		_kill_translate_task("")
	# 关闭前同步回收在途任务，保证线程槽全部释放（检测≤3s、单条翻译≤8s，均会自然结束）
	_kill_api_check_timer()
	if _api_check_task_id >= 0:
		_release_task(_api_check_task_id)
		_api_check_task_id = -1
		_api_checking = false
	_kill_single_translate_timer()
	if _single_translate_task_id >= 0:
		_release_task(_single_translate_task_id)
		_single_translate_task_id = -1
	_flush_save()
	if _translation_memory != null and _memory_dirty:
		_translation_memory.save()
	translation_closed.emit()

func _on_config_pressed():
	if not _project_path.is_empty():
		OS.shell_open(_project_path)

func _on_clear_btn_down():
	_clear_pressing = true
	_clear_press_timer.start()

func _on_refresh_pressed():
	if _current_file_name.is_empty():
		return
	_po_data.erase(_current_file_name)
	await _load_po_file(_current_file_name)
	_show_entries(_current_file_name)
	_show_toast("已刷新")
	_refresh_filter_counts()

func _on_search_text_submitted(new_text: String):
	_search_text = new_text.strip_edges()
	replace_btn.disabled = _search_text.is_empty()
	_apply_filter()

func _on_exact_search_text_submitted(new_text: String):
	_exact_search_text = new_text.strip_edges()
	_apply_filter()

func _apply_filter():
	if _current_file_name.is_empty():
		return

	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	_filtered_indices.clear()

	for idx in msgids.size():
		var mstr: String = msgstrs[idx] if idx < msgstrs.size() else ""
		var mid: String = msgids[idx] if idx < msgids.size() else ""

		# — 部分匹配（不区分大小写） —
		if not _search_text.is_empty():
			if not (_search_text.to_lower() in mid.to_lower() or _search_text.to_lower() in mstr.to_lower()):
				continue

		# — 完全匹配 —
		if not _exact_search_text.is_empty():
			if not (_exact_search_text == mid or _exact_search_text == mstr):
				continue

		var src: String = _translation_source.get(idx, "")
		var is_translated: bool = mstr != "" and mstr != msgids[idx]
		var passed: bool = false

		if src == "ai":
			passed = chk_ai.button_pressed
		elif src == "manual":
			passed = chk_manual.button_pressed
		elif src == "rule":
			passed = chk_rule.button_pressed
		elif src == "memory":
			passed = chk_memory.button_pressed
		elif mstr == "":
			passed = chk_empty.button_pressed
		elif is_translated:
			passed = chk_manual.button_pressed
		else:
			passed = chk_untranslated.button_pressed
		if not passed:
			continue

		_filtered_indices.append(idx)

	var all_checked := chk_ai.button_pressed and chk_manual.button_pressed and chk_rule.button_pressed and chk_memory.button_pressed and chk_untranslated.button_pressed and chk_empty.button_pressed
	_filter_active = not _search_text.is_empty() or not _exact_search_text.is_empty() or not all_checked

	# 每次搜索重置所有对钩为关闭状态
	_checked_entries.clear()

	# 隐藏当前可见节点，放入隐藏池（不销毁，复用）
	_move_visible_to_hidden_pool()
	_entry_pool.clear()
	_rebuild_heights_core()
	content_scroll.scroll_vertical = 0
	_first_drawn = -1
	_last_drawn = -1
	_do_refresh_visible_rows()
	_refresh_filter_counts()

func _refresh_filter_counts():
	"""统计当前文件各来源类型的条目数量，更新复选框标签"""
	if _current_file_name.is_empty():
		return
	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	var total := msgids.size()

	var cnt_ai := 0
	var cnt_manual := 0
	var cnt_rule := 0
	var cnt_memory := 0
	var cnt_untranslated := 0
	var cnt_empty := 0

	for idx in total:
		var mstr: String = msgstrs[idx] if idx < msgstrs.size() else ""
		var mid: String = msgids[idx] if idx < msgids.size() else ""
		var src: String = _translation_source.get(idx, "")

		if src == "ai":
			cnt_ai += 1
		elif src == "manual":
			cnt_manual += 1
		elif src == "rule":
			cnt_rule += 1
		elif src == "memory":
			cnt_memory += 1
		elif mstr == "":
			cnt_empty += 1
		elif mstr != "" and mstr != mid:
			cnt_manual += 1
		else:
			cnt_untranslated += 1

	chk_ai.text = "AI (%d)" % cnt_ai
	chk_manual.text = "手动 (%d)" % cnt_manual
	chk_rule.text = "规则 (%d)" % cnt_rule
	chk_memory.text = "记忆 (%d)" % cnt_memory
	chk_untranslated.text = "未翻译 (%d)" % cnt_untranslated
	chk_empty.text = "空 (%d)" % cnt_empty
	chk_all.text = "全部 (%d)" % total

func _on_all_toggled(checked: bool):
	# 全选/全不选：同步所有子复选框状态（阻止信号避免重复触发 apply_filter）
	chk_ai.set_block_signals(true)
	chk_manual.set_block_signals(true)
	chk_rule.set_block_signals(true)
	chk_memory.set_block_signals(true)
	chk_untranslated.set_block_signals(true)
	chk_empty.set_block_signals(true)
	chk_ai.button_pressed = checked
	chk_manual.button_pressed = checked
	chk_rule.button_pressed = checked
	chk_memory.button_pressed = checked
	chk_untranslated.button_pressed = checked
	chk_empty.button_pressed = checked
	chk_ai.set_block_signals(false)
	chk_manual.set_block_signals(false)
	chk_rule.set_block_signals(false)
	chk_memory.set_block_signals(false)
	chk_untranslated.set_block_signals(false)
	chk_empty.set_block_signals(false)
	_apply_filter()

func _on_filter_toggled(_checked: bool):
	# 同步 ChkAll 状态：全部选中则 ChkAll 选中，否则取消
	var all_on := chk_ai.button_pressed and chk_manual.button_pressed and chk_rule.button_pressed and chk_memory.button_pressed and chk_untranslated.button_pressed and chk_empty.button_pressed
	chk_all.set_block_signals(true)
	chk_all.button_pressed = all_on
	chk_all.set_block_signals(false)
	_apply_filter()

func _on_clear_btn_up():
	_clear_pressing = false
	_clear_press_timer.stop()

func _on_clear_long_press():
	_clear_pressing = false
	if _current_file_name.is_empty():
		return

	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())

	var targets: Array[int]
	if _filtered_indices.is_empty():
		for idx in msgids.size():
			targets.append(idx)
	else:
		targets = _filtered_indices

	for idx in targets:
		if idx < msgstrs.size():
			msgstrs[idx] = ""
		_translation_source.erase(idx)
		_mark_dirty(idx, "msgstr")
	_dirty_files[_current_file_name] = true

	_flush_save()
	_first_drawn = -1
	_last_drawn = -1
	_do_refresh_visible_rows()
	_show_toast("已清空 %d 条翻译" % targets.size())
	_refresh_filter_counts()


# ======== PO 文件加载（仅收集文件名，按需解析） ========

func _start_loading():
	if _project_path.is_empty():
		get_tree().change_scene_to_file("res://Main/Start/start.tscn")
		return

	var dir := DirAccess.open(_project_path)
	if dir == null:
		return

	# 只收集文件名和路径，不解析内容
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.get_extension().to_lower() == "po":
			_po_file_list[fn] = _project_path.path_join(fn)
		fn = dir.get_next()
	dir.list_dir_end()

	if _po_file_list.is_empty():
		return

	_loaded = true
	_build_tabs()

	# 仅加载第一个 PO 文件（后台线程解析，不阻塞 UI）
	var file_names := _po_file_list.keys()
	await _load_po_file(file_names[0])
	_on_tab_changed(file_names[0])

	var mem_dir := _project_path.path_join("翻译记忆")
	_translation_memory = TranslationMemory.new()
	_translation_memory.init(mem_dir)

	_auto_check_api()


func _load_po_file(file_name: String):
	if file_name in _po_data:
		return
	if _loading_file:
		return
	var file_path: String = _po_file_list.get(file_name, "")
	if file_path.is_empty():
		return

	_loading_file = true
	loading_overlay.visible = true
	await get_tree().process_frame

	# 后台线程解析 PO（parse_file_packed 是纯函数，线程安全）
	_thread_result.clear()
	var task_id := WorkerThreadPool.add_task(_parse_file_task.bind(file_path))
	WorkerThreadPool.wait_for_task_completion(task_id)
	var packed: Dictionary = _thread_result

	var msgids: PackedStringArray = packed.get("m", PackedStringArray())
	var contexts: PackedStringArray = packed.get("c", PackedStringArray())
	var src_locs: PackedStringArray = packed.get("sl", PackedStringArray())
	_po_data[file_name] = {
		"contexts": contexts,
		"msgids": msgids,
		"msgstrs": packed.get("s", PackedStringArray()),
		"source_locations": src_locs,
		"file_path": file_path
	}

	loading_overlay.visible = false
	_loading_file = false

## 重新解析当前 PO 文件到 _po_data（不重建 UI，用于翻译过程中增量刷新）
func _reload_current_po_data():
	if _current_file_name.is_empty():
		return
	var file_path: String = _po_file_list.get(_current_file_name, "")
	if file_path.is_empty():
		return
	_thread_result.clear()
	var task_id2 := WorkerThreadPool.add_task(_parse_file_task.bind(file_path))
	WorkerThreadPool.wait_for_task_completion(task_id2)
	var packed: Dictionary = _thread_result
	_po_data[_current_file_name] = {
		"contexts": packed.get("c", PackedStringArray()),
		"msgids": packed.get("m", PackedStringArray()),
		"msgstrs": packed.get("s", PackedStringArray()),
		"source_locations": packed.get("sl", PackedStringArray()),
		"file_path": file_path
	}

## 根据 msgid 片段定位滚动位置（翻译过程中增量刷新时使用）
func _scroll_to_msgid(msgid_fragment: String):
	if msgid_fragment.is_empty():
		return
	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
	# 从后往前找，因为翻译是从前往后推进的，msgid_fragment 是最新完成的条目
	for idx in range(msgids.size() - 1, -1, -1):
		if msgids[idx].begins_with(msgid_fragment):
			var target_y := maxi(0, (idx - 5) * ROW_HEIGHT)
			content_scroll.scroll_vertical = int(target_y)
			return

## 后台线程入口：纯静态解析，不访问场景树，线程安全
func _parse_file_task(file_path: String):
	_thread_result = PoParser.parse_file_packed(file_path)


# ======== 选项卡 ========

func _build_tabs():
	var file_names := _po_file_list.keys()
	if file_names.is_empty():
		return
	main_panel.visible = true

	for i in file_names.size():
		var btn := Button.new()
		btn.text = file_names[i]
		btn.toggle_mode = true
		btn.flat = true
		btn.custom_minimum_size = Vector2(0, 28)
		btn.add_theme_font_size_override("font_size", 13)
		btn.add_theme_stylebox_override("normal", _make_tab_stylebox(false))
		btn.add_theme_stylebox_override("hover", _make_tab_stylebox(false))
		btn.add_theme_stylebox_override("pressed", _make_tab_stylebox(true))
		btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 0.7))
		btn.add_theme_color_override("font_pressed_color", Color(1, 1, 1, 0.7))
		btn.pressed.connect(_on_tab_changed.bind(file_names[i]))
		tab_bar.add_child(btn)
		if i == 0:
			btn.button_pressed = true

func _make_tab_stylebox(active: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0.04, 0, 0.0) if not active else Color(0, 0.08, 0, 0.5)
	s.set_content_margin_all(6)
	if active:
		s.border_width_left = 1
		s.border_width_top = 1
		s.border_width_right = 1
		s.border_width_bottom = 1
		s.border_color = Color(0.3, 1, 0.5, 0.8)
		s.corner_radius_top_left = 4
		s.corner_radius_top_right = 4
		s.corner_radius_bottom_right = 4
		s.corner_radius_bottom_left = 4
	return s

func _on_tab_changed(file_name: String):
	if _translating:
		_cancel_requested = true
		PythonBridge.cancel_translate()
		_kill_translate_task("")

	if not _current_file_name.is_empty():
		_flush_save()
	_dirty_entries.clear()
	_translation_source.clear()

	# 按需加载（后台线程解析，不阻塞 UI）
	if not (file_name in _po_data):
		await _load_po_file(file_name)
	# 加载中或取消时跳过
	if not (file_name in _po_data):
		return

	for child in tab_bar.get_children():
		if child is Button:
			if child.text != file_name:
				child.button_pressed = false
		var active: bool = child.text == file_name
		child.add_theme_stylebox_override("normal", _make_tab_stylebox(active))
		child.add_theme_stylebox_override("hover", _make_tab_stylebox(active))
		child.add_theme_stylebox_override("pressed", _make_tab_stylebox(true))
		if active:
			child.add_theme_color_override("font_color", Color(0.3, 1, 0.5, 1))
			child.add_theme_color_override("font_hover_color", Color(0.3, 1, 0.5, 1))
			child.add_theme_color_override("font_pressed_color", Color(0.3, 1, 0.5, 1))
		else:
			child.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
			child.add_theme_color_override("font_hover_color", Color(1, 1, 1, 0.7))
			child.add_theme_color_override("font_pressed_color", Color(1, 1, 1, 0.7))
	_show_entries(file_name)

	translate_btn.disabled = not _api_available
	translate_btn.text = "一键翻译"
	_set_translate_btn_cancel_style(false)
	translate_progress_box.visible = false


# ======== 虚拟列表（固定行高，避免逐条 measure_height 卡死） ========

func _show_entries(file_name: String):
	_current_file_name = file_name
	_search_text = ""
	_exact_search_text = ""
	_filtered_indices.clear()
	_filter_active = false
	_checked_entries.clear()
	# 清空单条翻译状态（避免跨文件错写）
	_single_translate_queue.clear()
	_single_translate_current = -1
	_translating_entries.clear()
	_failed_entries.clear()
	_kill_single_translate_timer()
	_abandon_task(_single_translate_task_id)
	_single_translate_task_id = -1
	search_edit.text = ""
	exact_search_edit.text = ""
	replace_btn.disabled = true
	var data: Dictionary = _po_data.get(file_name, {})
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())

	# 隐藏当前可见节点，放入隐藏池（不销毁）
	_move_visible_to_hidden_pool()
	_entry_pool.clear()
	_first_drawn = -1
	_last_drawn = -1

	# 固定行高，避免逐条 measure_height 导致大文件卡死
	_entry_heights.clear()
	_entry_y.clear()
	var count := msgids.size()
	_entry_heights.resize(count)
	_entry_y.resize(count)
	var y_acc := 0.0
	for idx in count:
		_entry_heights[idx] = ROW_HEIGHT
		_entry_y[idx] = y_acc
		y_acc += ROW_HEIGHT

	po_list_container.custom_minimum_size.y = y_acc
	content_scroll.scroll_vertical = 0

	var vbar := content_scroll.get_v_scroll_bar()
	if vbar:
		vbar.custom_minimum_size = Vector2(16, 32)
		if not vbar.value_changed.is_connected(_on_scroll_changed):
			vbar.value_changed.connect(_on_scroll_changed)

	_do_refresh_visible_rows()
	_refresh_filter_counts()


# ======== 节点池管理（show/hide 复用，避免反复实例化/销毁） ========

## 将当前可见节点全部移到隐藏池
func _move_visible_to_hidden_pool():
	for e in _entry_pool:
		e.visible = false
		_hidden_pool.append(e)
	# 隐藏池超限时清理旧节点
	while _hidden_pool.size() > MAX_HIDDEN_POOL:
		var e: PoEntry = _hidden_pool.pop_front()
		if e.entry_saved.is_connected(_on_entry_saved):
			e.entry_saved.disconnect(_on_entry_saved)
		e.queue_free()

## 从隐藏池获取一个节点（优先复用），池空则实例化新节点
func _get_pooled_entry() -> PoEntry:
	if not _hidden_pool.is_empty():
		var e: PoEntry = _hidden_pool.pop_back()
		e.visible = true
		return e
	var e: PoEntry = PoEntryScene.instantiate()
	po_list_container.add_child(e)
	return e

## 将节点归还到隐藏池
func _return_to_hidden_pool(e: PoEntry):
	e.visible = false
	if e.entry_hovered.is_connected(_on_entry_hovered):
		e.entry_hovered.disconnect(_on_entry_hovered)
	if e.entry_unhovered.is_connected(_on_entry_unhovered):
		e.entry_unhovered.disconnect(_on_entry_unhovered)
	if e.entry_checked.is_connected(_on_entry_checked):
		e.entry_checked.disconnect(_on_entry_checked)
	if e.entry_translate.is_connected(_on_entry_translate):
		e.entry_translate.disconnect(_on_entry_translate)
	if e.entry_translate_stop.is_connected(_on_entry_translate_stop):
		e.entry_translate_stop.disconnect(_on_entry_translate_stop)
	_hidden_pool.append(e)
	while _hidden_pool.size() > MAX_HIDDEN_POOL:
		var x: PoEntry = _hidden_pool.pop_front()
		if x.entry_saved.is_connected(_on_entry_saved):
			x.entry_saved.disconnect(_on_entry_saved)
		x.queue_free()


# ======== 滚动与可见行刷新 ========

func _on_scroll_changed(_val: float = 0.0):
	_pending_refresh = true

func _do_refresh_visible_rows():
	var elem_count := _entry_y.size()
	if elem_count == 0:
		return

	var view_h := content_scroll.size.y
	var scroll_y := content_scroll.scroll_vertical
	var first := maxi(0, _find_row_by_y(scroll_y) - 1)
	var last := mini(elem_count - 1, _find_row_by_y(scroll_y + view_h - 1) + 1)

	if first == _first_drawn and last == _last_drawn:
		return
	_first_drawn = first
	_last_drawn = last

	var needed := last - first + 1
	# 多余的节点归还隐藏池
	while _entry_pool.size() > needed:
		var e: PoEntry = _entry_pool.pop_back()
		_return_to_hidden_pool(e)
	# 不足的节点从隐藏池获取或新建
	while _entry_pool.size() < needed:
		var e := _get_pooled_entry()
		_entry_pool.append(e)

	for i in needed:
		var row_i := first + i
		var idx: int = row_i
		if _filter_active:
			idx = _filtered_indices[row_i]
		var e: PoEntry = _entry_pool[i]
		if not e.entry_saved.is_connected(_on_entry_saved):
			e.entry_saved.connect(_on_entry_saved)
		if not e.entry_hovered.is_connected(_on_entry_hovered):
			e.entry_hovered.connect(_on_entry_hovered)
		if not e.entry_unhovered.is_connected(_on_entry_unhovered):
			e.entry_unhovered.connect(_on_entry_unhovered)
		if not e.entry_checked.is_connected(_on_entry_checked):
			e.entry_checked.connect(_on_entry_checked)
		if not e.entry_translate.is_connected(_on_entry_translate):
			e.entry_translate.connect(_on_entry_translate)
		if not e.entry_translate_stop.is_connected(_on_entry_translate_stop):
			e.entry_translate_stop.connect(_on_entry_translate_stop)
		_fill_entry(e, _current_file_name, idx)
		e.set_entry(
			_get_entry_msgid(_current_file_name, idx),
			_get_entry_msgstr(_current_file_name, idx),
			_translation_source.get(idx, ""),
			_entry_heights[row_i],
			idx
		)
		# 设置复选框状态
		e.set_checked(_checked_entries.get(idx, false))
		# 应用搜索高亮
		e.apply_search_highlight(_search_text)
		# 设置翻译状态（翻译中/翻译失败覆盖显示，正常状态仅恢复按钮）
		if _translating_entries.has(idx):
			e.set_translating(true)
		elif _failed_entries.has(idx):
			e.set_translate_failed()
		else:
			e.set_translating(false)
		e.position.y = _entry_y[row_i]
		e.size.x = po_list_container.size.x

func _find_row_by_y(y: float) -> int:
	var lo := 0
	var hi := _entry_y.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _entry_y[mid] <= y:
			lo = mid
		else:
			hi = mid - 1
	return lo


# ======== 数据访问（内联取值，避免每帧创建 Dictionary） ========

func _get_entry_msgid(file_name: String, idx: int) -> String:
	var data: Dictionary = _po_data[file_name]
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
	return msgids[idx] if idx < msgids.size() else ""

func _get_entry_msgstr(file_name: String, idx: int) -> String:
	var data: Dictionary = _po_data[file_name]
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	return msgstrs[idx] if idx < msgstrs.size() else ""

## 仅重建高度时用，填充 entry 的额外字段（但不再依赖 Dict）
func _fill_entry(_e: PoEntry, _file_name: String, _idx: int):
	pass  # 占位，后续如需 context 等字段可在此扩展


# ======== 保存流程 ========

func _on_entry_saved(entry_index: int, field: String, new_text: String):
	if _current_file_name.is_empty():
		return

	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	var n: int = msgids.size()
	if entry_index < 0 or entry_index >= n:
		return

	if field == "msgstr":
		var old_text: String = msgstrs[entry_index] if entry_index < msgstrs.size() else ""
		if old_text == new_text:
			return
		msgstrs[entry_index] = new_text
		_translation_source[entry_index] = "manual"
		if _translation_memory != null and entry_index < msgids.size():
			_translation_memory.record(msgids[entry_index], new_text)
			_memory_dirty = true
		_mark_dirty(entry_index, "msgstr")
	else:
		var old_text: String = msgids[entry_index] if entry_index < msgids.size() else ""
		if old_text == new_text:
			return
		msgids[entry_index] = new_text
		_mark_dirty(entry_index, "msgid")

	_dirty_files[_current_file_name] = true
	_flush_save()
	_do_refresh_visible_rows()
	_refresh_filter_counts()
	if _detail_hover_idx == entry_index:
		_update_detail_panel(entry_index)

func _on_entry_hovered(entry_index: int):
	_detail_hover_idx = entry_index
	_update_detail_panel(entry_index)

func _on_entry_unhovered(entry_index: int):
	if _detail_hover_idx == entry_index:
		_detail_hover_idx = -1

func _update_detail_panel(idx: int):
	if _current_file_name.is_empty() or idx < 0:
		return
	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	var contexts: PackedStringArray = data.get("contexts", PackedStringArray())
	var src_locs: PackedStringArray = data.get("source_locations", PackedStringArray())
	if idx >= msgids.size():
		return

	var mid: String = msgids[idx] if idx < msgids.size() else ""
	var mstr: String = msgstrs[idx] if idx < msgstrs.size() else ""
	var ctx: String = contexts[idx] if idx < contexts.size() else ""
	var srcloc: String = src_locs[idx] if idx < src_locs.size() else ""
	var src: String = _translation_source.get(idx, "")

	detail_index_label.text = "索引: %d / %d" % [idx, msgids.size()]

	var src_text: String
	var src_color: Color
	match src:
		"ai":
			src_text = "AI 翻译"
			src_color = Color(0.35, 0.6, 1, 1)
		"manual":
			src_text = "手动翻译"
			src_color = Color(0.3, 1, 0.5, 1)
		"rule":
			src_text = "规则翻译"
			src_color = Color(1, 0.85, 0.3, 1)
		"memory":
			src_text = "翻译记忆"
			src_color = Color(0.7, 0.35, 1, 1)
		_:
			if mstr == "":
				src_text = "未翻译"
				src_color = Color(0.85, 0.35, 0.35, 1)
			elif mstr == mid:
				src_text = "未翻译（同原文）"
				src_color = Color(0.85, 0.35, 0.35, 1)
			else:
				src_text = "已翻译"
				src_color = Color(0.3, 1, 0.5, 1)
	detail_source_label.text = "来源: " + src_text
	detail_source_label.add_theme_color_override("font_color", src_color)

	if ctx != "":
		detail_context_label.text = "上下文: " + ctx
		detail_context_label.visible = true
	else:
		detail_context_label.text = "上下文: —"
		detail_context_label.visible = false

	if srcloc != "":
		detail_srcloc_content.text = srcloc
		detail_srcloc_title.visible = true
		detail_srcloc_content.visible = true
	else:
		detail_srcloc_content.text = "—"
		detail_srcloc_title.visible = false
		detail_srcloc_content.visible = false

	var ctx_show := detail_context_label.visible
	var srcloc_show := detail_srcloc_title.visible
	detail_sep2.visible = true
	detail_sep3.visible = ctx_show and srcloc_show
	detail_sep4.visible = true
	detail_sep5.visible = true

	detail_msgid_content.text = mid if mid != "" else "(空)"
	detail_msgstr_content.text = mstr if mstr != "" else "(空)"

	if idx in _dirty_entries:
		var dirty_val = _dirty_entries[idx]
		var dirty_text: String
		if typeof(dirty_val) == TYPE_BOOL and dirty_val:
			dirty_text = "● 已修改（msgid + msgstr）"
		elif typeof(dirty_val) == TYPE_STRING:
			if dirty_val == "both":
				dirty_text = "● 已修改（msgid + msgstr）"
			elif dirty_val == "msgid":
				dirty_text = "● 已修改（msgid）"
			else:
				dirty_text = "● 已修改（msgstr）"
		else:
			dirty_text = "● 已修改"
		detail_dirty_label.text = dirty_text
		detail_dirty_label.visible = true
	else:
		detail_dirty_label.visible = false

	detail_sep6.visible = detail_dirty_label.visible

func _mark_dirty(entry_index: int, field: String):
	if entry_index in _dirty_entries:
		var existing = _dirty_entries[entry_index]
		var existing_is_both := false
		var existing_field := ""
		if typeof(existing) == TYPE_BOOL and existing:
			existing_is_both = true
		elif typeof(existing) == TYPE_STRING:
			if existing == "both":
				existing_is_both = true
			else:
				existing_field = existing
		if existing_is_both:
			return
		if existing_field != "" and existing_field != field:
			_dirty_entries[entry_index] = "both"
	else:
		_dirty_entries[entry_index] = field

func _save_current_po_file():
	if _current_file_name.is_empty():
		return
	var data: Dictionary = _po_data.get(_current_file_name, {})
	PoParser.write_file_packed(
		data["file_path"],
		data["contexts"],
		data["msgids"],
		data["msgstrs"],
		_dirty_entries
	)
	_dirty_files.erase(_current_file_name)
	_dirty_entries.clear()

func _flush_save():
	if _translating:
		return
	if _dirty_files.is_empty():
		return

	for file_name in _dirty_files.keys():
		var data: Dictionary = _po_data.get(file_name, {})
		var file_path: String = data.get("file_path", "")
		if file_path.is_empty():
			_dirty_files.erase(file_name)
			continue

		if file_name == _current_file_name:
			PoParser.write_file_packed(file_path, data["contexts"], data["msgids"], data["msgstrs"], _dirty_entries)
		else:
			PoParser.write_file_packed(file_path, data["contexts"], data["msgids"], data["msgstrs"], {})

	_dirty_files.clear()
	_dirty_entries.clear()

	# 翻译记忆有变更且不在翻译中时才写回
	if _memory_dirty and not _translating:
		if _translation_memory != null:
			_translation_memory.save()
		_memory_dirty = false


# ======== 高度重建 ========

func _rebuild_heights_core():
	_entry_heights.clear()
	_entry_y.clear()
	var y_acc := 0.0

	# 固定行高，避免逐条 measure_height 卡死
	var count: int
	if _filter_active:
		count = _filtered_indices.size()
	else:
		var data: Dictionary = _po_data.get(_current_file_name, {})
		count = data.get("msgids", PackedStringArray()).size()
	_entry_heights.resize(count)
	_entry_y.resize(count)
	for idx in count:
		_entry_heights[idx] = ROW_HEIGHT
		_entry_y[idx] = y_acc
		y_acc += ROW_HEIGHT

	po_list_container.custom_minimum_size.y = y_acc


# ======== API / 语言配置 ========

func _setup_api_options():
	api_option.clear()
	api_option.add_item("SimplyTranslate", 0)
	api_option.add_item("LingvaTranslate", 1)
	api_option.add_item("LibreTranslate（已停用）", 2)
	# LibreTranslate 保留但不再更新，禁止选择
	api_option.set_item_disabled(2, true)
	api_option.selected = 0

func _setup_lang_options():
	_lang_list = [
		{"code": "auto", "name": "自动检测"},
		{"code": "en", "name": "English"},
		{"code": "zh-CN", "name": "简体中文"},
		{"code": "zh-TW", "name": "繁體中文"},
		{"code": "ja", "name": "日本語"},
		{"code": "ko", "name": "한국어"},
		{"code": "fr", "name": "Français"},
		{"code": "de", "name": "Deutsch"},
		{"code": "es", "name": "Español"},
		{"code": "pt", "name": "Português"},
		{"code": "ru", "name": "Русский"},
		{"code": "ar", "name": "العربية"},
		{"code": "th", "name": "ไทย"},
		{"code": "vi", "name": "Tiếng Việt"},
		{"code": "id", "name": "Bahasa Indonesia"},
		{"code": "it", "name": "Italiano"},
		{"code": "nl", "name": "Nederlands"},
		{"code": "pl", "name": "Polski"},
		{"code": "tr", "name": "Türkçe"},
		{"code": "uk", "name": "Українська"},
		{"code": "he", "name": "עברית"},
	]

	src_lang_option.clear()
	target_lang_option.clear()
	var target_default_idx := 1
	for i in _lang_list.size():
		var d: Dictionary = _lang_list[i]
		src_lang_option.add_item(d["name"], i)
		target_lang_option.add_item(d["name"], i)
	src_lang_option.selected = 0
	target_lang_option.selected = target_default_idx


# ======== 一键翻译（全流程由 Python 后台完成：解析PO→逐条翻译→写回PO） ========

func _on_translate_btn_pressed():
	if _translating:
		_cancel_requested = true
		PythonBridge.cancel_translate()
		translate_btn.disabled = true
		return

	if _api_checking:
		_show_toast("检测中，请检测完成后再试")
		return

	if not _api_available:
		_show_toast("翻译API暂不可用")
		return

	if _current_file_name.is_empty():
		_show_toast("请先选择 PO 文件")
		return

	# 收集空 msgstr 统计
	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	var empty_count := 0
	for ms in msgstrs:
		if ms == "":
			empty_count += 1

	if empty_count == 0:
		_show_toast("没有空的 msgstr 需要翻译")
		return

	var file_path: String = _po_file_list.get(_current_file_name, "")
	_show_toast("将翻译 %d 条空条目，由 Python 后台执行" % empty_count)
	await get_tree().process_frame

	# 先保存未写入的脏数据，避免 Python 重读 PO 时丢失手动编辑
	_flush_save()

	_translating = true
	_cancel_requested = false
	_translate_total = empty_count
	_translate_done = 0
	_last_reloaded_done = 0

	translate_btn.text = "取消翻译"
	_set_translate_btn_cancel_style(true)
	translate_progress_box.visible = true
	_update_progress_ui()

	var src_lang: String = _lang_list[src_lang_option.selected]["code"]
	var target_lang: String = _lang_list[target_lang_option.selected]["code"]
	var progress_path := OS.get_user_data_dir().path_join("_po_translate_progress.json")

	var api_type := _selected_api_type()
	var api_url := _current_api_url()

	# 在主线程复制 Python 脚本到临时路径（FileAccess 在 WorkerThread 中不可靠）
	var script_temp := PythonBridge.copy_script_to_temp()
	if script_temp.is_empty():
		_show_toast("无法读取翻译脚本")
		_finish_translation()
		return

	# 主线程先重置取消标志，再提交任务（避免与后台线程竞态）
	PythonBridge.reset_cancel()
	var task_id := WorkerThreadPool.add_task(
		PythonBridge.run_full_translate.bind(file_path, src_lang, target_lang, TRANSLATE_BATCH_SIZE, progress_path, script_temp, _project_path, api_type, api_url)
	)
	_translate_task_id = task_id

	# 启动进度轮询
	_progress_poll_timer = Timer.new()
	_progress_poll_timer.one_shot = false
	_progress_poll_timer.wait_time = PROGRESS_POLL_MS * 0.001
	_progress_poll_timer.timeout.connect(_poll_progress.bind(task_id, progress_path, file_path))
	add_child(_progress_poll_timer)
	_progress_poll_timer.start()


func _poll_progress(task_id: int, progress_path: String, po_file_path: String):
	if _cancel_requested:
		PythonBridge.cancel_translate()
		# _kill_translate_task 内部会等待 worker 线程退出并释放任务槽（最多约 200ms）
		_kill_translate_task(progress_path)
		# 重新加载 PO 数据（Python 可能已写入部分结果到磁盘）
		_po_data.erase(_current_file_name)
		await _load_po_file(_current_file_name)
		_show_entries(_current_file_name)
		return

	if not WorkerThreadPool.is_task_completed(task_id):
		if FileAccess.file_exists(progress_path):
			var pf := FileAccess.open(progress_path, FileAccess.READ)
			if pf:
				var txt := pf.get_as_text()
				pf.close()
				var p = JSON.parse_string(txt)
				if p is Dictionary:
					var new_done: int = p.get("done", _translate_done)
					_translate_total = p.get("total", _translate_total)
					if new_done != _translate_done:
						_translate_done = new_done
						_update_progress_ui()
						# 每完成一个 batch，从磁盘重新读取 PO 并刷新可见行
						if _translate_done > _last_reloaded_done:
							_reload_current_po_data()
							_rebuild_heights_core()
							_first_drawn = -1
							_last_drawn = -1
							_move_visible_to_hidden_pool()
							_entry_pool.clear()
							_do_refresh_visible_rows()
							_scroll_to_msgid(p.get("current", ""))
							_last_reloaded_done = _translate_done
		return

	# 任务完成，直接验证 PO 文件内容（Python 已原地写回）
	_release_task(task_id)
	_translate_task_id = -1
	_kill_progress_timer()

	# 从 result 文件读取翻译来源信息
	var result_path := progress_path.replace("_progress.json", "_result.json")
	var sources: Dictionary = {}
	if FileAccess.file_exists(result_path):
		var rf := FileAccess.open(result_path, FileAccess.READ)
		if rf:
			var rtxt := rf.get_as_text()
			rf.close()
			var rp = JSON.parse_string(rtxt)
			if rp is Dictionary:
				sources = rp.get("sources", {})

	DirAccess.remove_absolute(progress_path)
	DirAccess.remove_absolute(result_path)

	var translated: int = 0
	if FileAccess.file_exists(po_file_path):
		var pf := FileAccess.open(po_file_path, FileAccess.READ)
		if pf:
			var raw := pf.get_as_text()
			pf.close()
			var re := RegEx.new()
			re.compile("msgstr\\s+\"(.+)\"")
			for m in re.search_all(raw):
				if m.get_string(1) != "":
					translated += 1

	if translated > 0:
		_translate_done = _translate_total
		_update_progress_ui()
		_show_toast("翻译完成，共翻译 %d 条" % translated)

		_dirty_entries.clear()
		_dirty_files.clear()
		_translation_source.clear()
		# 将 Python 报告的来源数据填入 _translation_source
		for idx_str in sources:
			_translation_source[idx_str.to_int()] = sources[idx_str]
		_po_data.erase(_current_file_name)
		translate_progress_box.visible = false
		await _load_po_file(_current_file_name)
		_show_entries(_current_file_name)

	else:
		_dirty_entries.clear()
		_dirty_files.clear()
		_show_toast("翻译未能写入 PO 文件，请检查日志: %s" % progress_path.replace("_progress.json", "_debug.log"))

	_finish_translation()


func _kill_translate_task(progress_path: String):
	_kill_progress_timer()
	# 子进程已被 kill（cancel_translate），等待 worker 线程退出并释放任务槽
	if _translate_task_id >= 0:
		_release_task(_translate_task_id)
		_translate_task_id = -1
	if not progress_path.is_empty() and FileAccess.file_exists(progress_path):
		DirAccess.remove_absolute(progress_path)
	_finish_translation()


func _kill_progress_timer():
	if _progress_poll_timer:
		_progress_poll_timer.stop()
		_progress_poll_timer.queue_free()
		_progress_poll_timer = null


func _finish_translation():
	_kill_progress_timer()
	_flush_save()
	if _translation_memory != null and _memory_dirty:
		_translation_memory.save()
		_memory_dirty = false

	translate_btn.disabled = not _api_available or _current_file_name.is_empty()
	translate_btn.text = "一键翻译"
	_set_translate_btn_cancel_style(false)
	translate_progress_box.visible = false
	_translating = false
	_cancel_requested = false


func _set_translate_btn_cancel_style(is_cancel: bool):
	if is_cancel:
		translate_btn.add_theme_color_override("font_color", Color(0.9, 0.35, 0.35, 0.9))
		translate_btn.add_theme_color_override("font_hover_color", Color(1, 0.45, 0.45, 1))
	else:
		translate_btn.add_theme_color_override("font_color", Color(0.3, 1, 0.5, 0.75))
		translate_btn.add_theme_color_override("font_hover_color", Color(0.5, 1, 0.7, 1))

func _update_progress_ui():
	if _translate_total > 0:
		translate_progress_bar.value = float(_translate_done) / float(_translate_total)
		translate_progress_label.text = "翻译中 %d / %d" % [_translate_done, _translate_total]
	else:
		translate_progress_bar.value = 0.0
		translate_progress_label.text = "就绪"


# ======== API 可用性检测（Python 后台线程执行，不阻塞 UI） ========

func _auto_check_api() -> void:
	await get_tree().process_frame
	_check_current_api()

func _on_check_api_pressed() -> void:
	_check_current_api()

func _on_api_option_selected(index: int) -> void:
	# 防止选中已停用的 LibreTranslate
	if api_option.is_item_disabled(index):
		api_option.selected = _api_selected_index_backup
		return
	_api_selected_index_backup = index
	# 切换前保存当前 API 的 URL 输入
	_api_url_edits[_api_url_key] = api_url_edit.text
	_api_available = false
	translate_btn.disabled = true
	# 清空单条翻译状态，恢复条目翻译按钮可用
	_single_translate_queue.clear()
	_single_translate_current = -1
	_translating_entries.clear()
	_failed_entries.clear()
	_kill_single_translate_timer()
	_abandon_task(_single_translate_task_id)
	_single_translate_task_id = -1
	_first_drawn = -1
	_last_drawn = -1
	_move_visible_to_hidden_pool()
	_entry_pool.clear()
	_do_refresh_visible_rows()
	_update_api_url_visibility()
	_check_current_api()

func _selected_api_type() -> String:
	match api_option.selected:
		1:
			return "lingva"
		_:
			return "simplytranslate"

func _current_api_url() -> String:
	var api_type := _selected_api_type()
	var url: String = api_url_edit.text.strip_edges()
	if url.is_empty():
		url = str(API_DEFAULT_URLS.get(api_type, ""))
	return url

func _update_api_url_visibility() -> void:
	# SimplyTranslate / LingvaTranslate 均为自部署服务，URL 可配置
	var api_type := _selected_api_type()
	_api_url_key = api_type
	if _api_url_edits.has(api_type):
		api_url_edit.text = str(_api_url_edits[api_type])
	else:
		api_url_edit.text = str(API_DEFAULT_URLS.get(api_type, ""))
	api_url_edit.placeholder_text = str(API_DEFAULT_URLS.get(api_type, ""))
	api_url_edit.visible = true
	api_url_label.visible = true

func _check_current_api() -> void:
	if _api_checking:
		# 上一次检测仍在进行：放弃旧任务（登记回收线程槽），改用新检测，
		# 否则切换 API 后新检测永远不发起、旧结果还会张冠李戴
		_kill_api_check_timer()
		_abandon_task(_api_check_task_id)
		_api_check_task_id = -1
		_api_checking = false
	api_check_btn.disabled = true
	api_check_btn.text = "检测中..."
	translate_btn.disabled = true
	_api_checking = true
	_show_toast("正在检测 API...")

	var api_type := _selected_api_type()
	var url := _current_api_url()
	_api_check_result_holder = {}
	_api_check_task_id = WorkerThreadPool.add_task(PythonBridge.check_api.bind(url, api_type, _api_check_result_holder))

	_api_check_timer = Timer.new()
	_api_check_timer.one_shot = false
	_api_check_timer.wait_time = 0.3
	_api_check_timer.timeout.connect(_poll_api_check)
	add_child(_api_check_timer)
	_api_check_timer.start()

func _poll_api_check():
	if not WorkerThreadPool.is_task_completed(_api_check_task_id):
		return

	# 必须收集已完成任务，否则 WorkerThreadPool 线程槽永不释放，
	# 反复检测/翻译会耗尽线程池并导致 add_task 阻塞主线程（系统卡死根因）
	_release_task(_api_check_task_id)
	_api_check_task_id = -1
	_kill_api_check_timer()
	var result: Dictionary = _api_check_result_holder

	api_check_btn.disabled = false
	api_check_btn.text = "检测API"
	_api_checking = false

	var ok: bool = result.get("available", false)
	var msg: String
	var api_name := "SimplyTranslate" if _selected_api_type() == "simplytranslate" else "LingvaTranslate"
	if ok:
		msg = "%s 检测成功：API 可用，翻译成功" % api_name
	else:
		msg = "%s 检测失败：请检查服务是否已启动、URL 配置是否正确" % api_name
	_api_available = ok

	translate_btn.disabled = not ok or _current_file_name.is_empty()

	var color: Color = Color(0.3, 1, 0.5, 1) if ok else Color(1, 0.4, 0.4, 1)
	_toast_label.add_theme_color_override("font_color", color)
	_show_toast(msg, false)

func _kill_api_check_timer():
	if _api_check_timer:
		_api_check_timer.stop()
		_api_check_timer.queue_free()
		_api_check_timer = null

## 收集并释放 WorkerThreadPool 任务槽。
## Godot 的 WorkerThreadPool 要求每个 add_task 返回的 id 最终必须调用一次
## wait_for_task_completion，否则该线程槽永久占用。反复检测/翻译会耗尽线程池，
## 后续 add_task 将阻塞调用线程（主线程），表现为整个软件乃至系统卡死。
## 调用前任务应已完成（轮询确认）或子进程已被 kill，避免长时间阻塞主线程。
func _release_task(task_id: int):
	if task_id < 0:
		return
	WorkerThreadPool.wait_for_task_completion(task_id)

## 放弃一个仍在执行的任务：登记到孤儿列表，由 _process 非阻塞回收，
## 保证线程槽最终释放（不能在主线程 wait，否则会卡住 UI 数秒）
func _abandon_task(task_id: int):
	if task_id >= 0 and not (task_id in _orphan_tasks):
		_orphan_tasks.append(task_id)

## 非阻塞回收已完成的孤儿任务
func _reap_orphan_tasks():
	if _orphan_tasks.is_empty():
		return
	var i := _orphan_tasks.size() - 1
	while i >= 0:
		var tid: int = _orphan_tasks[i]
		if WorkerThreadPool.is_task_completed(tid):
			_release_task(tid)
			_orphan_tasks.remove_at(i)
		i -= 1


# ======== Toast ========

func _show_toast(msg: String, auto_close: bool = true):
	_toast_label.text = msg
	_toast_label.visible = true
	_toast_label.position = Vector2(0, size.y - 60)
	_toast_label.size.x = size.x
	_toast_click_to_close = not auto_close
	if auto_close:
		await get_tree().create_timer(2.0).timeout
		if _toast_label and _toast_label.visible:
			_toast_label.visible = false
			_toast_click_to_close = false

func _hide_toast():
	_toast_label.visible = false
	_toast_click_to_close = false


# ======== 复选框 & 一键替换 ========

func _on_entry_checked(entry_index: int, checked: bool):
	if checked:
		_checked_entries[entry_index] = true
	else:
		_checked_entries.erase(entry_index)

func _on_replace_pressed():
	if _search_text.is_empty() or _checked_entries.is_empty():
		return

	var data: Dictionary = _po_data.get(_current_file_name, {})
	var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
	var msgids: PackedStringArray = data.get("msgids", PackedStringArray())

	# 使用 ReplaceEdit 中的文本作为替换目标
	var replace_with: String = replace_edit.text.strip_edges()
	if replace_with.is_empty():
		_show_toast("请先输入替换文本")
		return

	var lower_search := _search_text.to_lower()
	var count := 0

	for entry_idx in _checked_entries.keys():
		var idx: int = entry_idx as int
		if idx < 0 or idx >= msgstrs.size():
			continue
		var mstr: String = msgstrs[idx]
		if mstr.is_empty():
			continue

		# 查找所有不区分大小写的匹配并替换
		var lower_mstr := mstr.to_lower()
		var new_mstr := ""
		var pos := 0
		var found_any := false
		while pos < mstr.length():
			var found := lower_mstr.find(lower_search, pos)
			if found == -1:
				new_mstr += mstr.substr(pos)
				break
			if found > pos:
				new_mstr += mstr.substr(pos, found - pos)
			new_mstr += replace_with
			pos = found + _search_text.length()
			found_any = true

		if found_any:
			msgstrs[idx] = new_mstr
			_translation_source[idx] = "manual"
			_mark_dirty(idx, "msgstr")
			count += 1

	if count > 0:
		_dirty_files[_current_file_name] = true
		_flush_save()
		# 清除对钩
		_checked_entries.clear()
		# 刷新显示
		_first_drawn = -1
		_last_drawn = -1
		_move_visible_to_hidden_pool()
		_entry_pool.clear()
		_do_refresh_visible_rows()
		_show_toast("已替换 %d 条" % count)
		_refresh_filter_counts()
	else:
		_show_toast("选中条目中未找到匹配文本")


# --------------------- 单条翻译 ---------------------

## 用户点击某条目的“翻译”按钮
func _on_entry_translate(entry_index: int):
	if entry_index < 0 or _translating:
		return
	if _translating_entries.has(entry_index):
		return
	# 入队即标记“翻译中”，按钮显示“停止”
	_translating_entries[entry_index] = true
	_failed_entries.erase(entry_index)
	_single_translate_queue.append(entry_index)
	_first_drawn = -1
	_last_drawn = -1
	_move_visible_to_hidden_pool()
	_entry_pool.clear()
	_do_refresh_visible_rows()
	_start_next_single_translate()

## 用户点击翻译中条目的“停止”按钮
func _on_entry_translate_stop(entry_index: int):
	# 仅停止被点击的条目，不影响其他排队/在途条目
	_single_translate_queue.erase(entry_index)
	_translating_entries.erase(entry_index)
	if _single_translate_current == entry_index:
		_single_translate_current = -1
		_kill_single_translate_timer()
		# 在途任务无法取消，登记回收以免泄漏线程槽
		_abandon_task(_single_translate_task_id)
		_single_translate_task_id = -1
		_show_toast("已停止翻译")
	# 刷新显示
	_first_drawn = -1
	_last_drawn = -1
	_move_visible_to_hidden_pool()
	_entry_pool.clear()
	_do_refresh_visible_rows()
	# 若停止的是在途条目，继续处理队列中的下一条
	_start_next_single_translate()

## 从队列中取下一个待翻译条目并发起后台翻译
func _start_next_single_translate():
	if _single_translate_current != -1:
		return  # 当前已有翻译在途
	if _single_translate_queue.is_empty():
		return
	var idx: int = _single_translate_queue.pop_front()
	_single_translate_current = idx

	var mid: String = _get_entry_msgid(_current_file_name, idx)
	if mid.is_empty():
		_finish_single_translate(idx, "")
		return

	var src_lang: String = _lang_list[src_lang_option.selected]["code"]
	var target_lang: String = _lang_list[target_lang_option.selected]["code"]

	var api_type := _selected_api_type()
	var api_url := _current_api_url()

	_single_translate_result_holder = {}
	_single_translate_task_id = WorkerThreadPool.add_task(
		PythonBridge.translate_single.bind(mid, src_lang, target_lang, api_type, api_url, _single_translate_result_holder)
	)

	_single_translate_timer = Timer.new()
	_single_translate_timer.one_shot = false
	_single_translate_timer.wait_time = 0.3
	_single_translate_timer.timeout.connect(_poll_single_translate)
	add_child(_single_translate_timer)
	_single_translate_timer.start()

## 轮询单条翻译结果
func _poll_single_translate():
	if not WorkerThreadPool.is_task_completed(_single_translate_task_id):
		return
	_release_task(_single_translate_task_id)
	_single_translate_task_id = -1
	_kill_single_translate_timer()
	var idx: int = _single_translate_current
	if idx < 0:
		return
	var translated := ""
	if _single_translate_result_holder.get("ok", false):
		translated = str(_single_translate_result_holder.get("text", ""))
	_finish_single_translate(idx, translated)

func _kill_single_translate_timer():
	if _single_translate_timer:
		_single_translate_timer.stop()
		_single_translate_timer.queue_free()
		_single_translate_timer = null

## 结束单条翻译：写入结果、保存、继续处理队列
func _finish_single_translate(idx: int, translated_text: String):
	_translating_entries.erase(idx)
	if _single_translate_current == idx:
		_single_translate_current = -1

	if translated_text != "" and _current_file_name != "":
		_failed_entries.erase(idx)
		var data: Dictionary = _po_data.get(_current_file_name, {})
		var msgstrs: PackedStringArray = data.get("msgstrs", PackedStringArray())
		var msgids: PackedStringArray = data.get("msgids", PackedStringArray())
		if idx < msgstrs.size():
			msgstrs[idx] = translated_text
			_translation_source[idx] = "ai"
			if _translation_memory != null and idx < msgids.size():
				_translation_memory.record(msgids[idx], translated_text)
				_memory_dirty = true
			_mark_dirty(idx, "msgstr")
			_dirty_files[_current_file_name] = true
			_flush_save()
		_show_toast("已翻译: %s" % (translated_text.left(30)))
	else:
		_failed_entries[idx] = true
		_show_toast("翻译失败，请检查网络或 API 设置")

	# 刷新显示
	_first_drawn = -1
	_last_drawn = -1
	_move_visible_to_hidden_pool()
	_entry_pool.clear()
	_do_refresh_visible_rows()
	_refresh_filter_counts()

	# 处理队列中的下一条
	_start_next_single_translate()
