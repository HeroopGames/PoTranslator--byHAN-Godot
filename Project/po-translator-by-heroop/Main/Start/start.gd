# === PoTranslatorByHAN · 启动场景控制器 ===
# 动画流程: 标题居中淡入 → 平滑上移至顶部 → 扫描线扫过全屏 → 逐项检测 → 结果面板
# 结果分支: 环境就绪 → 显示「新建/打开项目」按钮  |  环境缺失 → 显示安装指引 + 重试
# 关键节点: TitleLabel(居中锚点，用 offset_top/bottom 控制垂直位移), ScanningPanel, InstallPanel, ProjectPanel
# 材质依赖: ScanOverlay 使用 scan_line.gdshader
# 按钮信号: RetryBtn→_on_retry_pressed, ExitBtn→_on_exit_pressed, NewProjectBtn/OpenProjectBtn（待实现）
extends Control

# ====== 引用节点 ======
@onready var title_label: Label = $TitleLabel
@onready var scanning_panel: Control = $ScanningPanel
@onready var scan_overlay: ColorRect = $ScanningPanel/ScanOverlay
@onready var status_label: Label = $ScanningPanel/ScanInfo/StatusLabel
@onready var python_status: Label = $ScanningPanel/ScanInfo/PythonRow/StatusIcon
@onready var openpyxl_status: Label = $ScanningPanel/ScanInfo/OpenpyxlRow/StatusIcon
@onready var install_panel: Control = $InstallPanel
@onready var install_desc: Label = $InstallPanel/InstallBox/DescLabel
@onready var command_label: Label = $InstallPanel/InstallBox/CommandBg/CommandLabel
@onready var project_panel: Control = $ProjectPanel
@onready var editor_skip_label: Label = $EditorSkipLabel
@onready var info_popup: Control = $InfoPopup
@onready var popup_title: Label = $InfoPopup/PopupBox/PopupTitle
@onready var popup_content: Label = $InfoPopup/PopupBox/PopupScroll/PopupContent

# ====== 材质引用 ======
var scan_material: ShaderMaterial

# ====== 状态 ======
enum State { INTRO, SCANNING, CHECK_ITEMS, SUCCESS, ENV_FAIL }
var current_state: State = State.INTRO
var env: Node
var _new_project: Node
var _open_project: Node
var _skipped: bool = false

# 标题目标 Y 位移（负值 = 向上，单位 px）
const TITLE_TOP_Y: float = -173.0

# 标题原始偏移（从 tscn 读取，用于还原）
var _title_base_top: float
var _title_base_bottom: float


# ====== 生命周期 ======
func _ready():
	# 获取扫描 shader 材质
	if scan_overlay and scan_overlay.material:
		scan_material = scan_overlay.material

	# 记录标题原始 offset（居中锚点下，移动标题需同时改 offset_top 和 offset_bottom）
	_title_base_top = title_label.offset_top
	_title_base_bottom = title_label.offset_bottom

	# 初始状态：标题透明，其他面板隐藏
	title_label.modulate.a = 0.0
	scanning_panel.modulate.a = 0.0
	scanning_panel.visible = true
	install_panel.visible = false
	project_panel.visible = false

	# 编辑器跳过检测：仅编辑器内显示提示标签
	if OS.has_feature("editor"):
		editor_skip_label.visible = true
	else:
		editor_skip_label.visible = false

	# 创建环境检测器
	env = load("res://Main/Start/env_checker.gd").new()
	add_child(env)

	# 创建新建/打开项目模块
	_new_project = load("res://Main/Start/Function/new_project.gd").new()
	add_child(_new_project)
	_new_project.project_created.connect(_on_project_created)
	_new_project.creation_failed.connect(_on_creation_failed)

	_open_project = load("res://Main/Start/Function/open_project.gd").new()
	add_child(_open_project)
	_open_project.project_opened.connect(_on_project_opened)
	_open_project.open_failed.connect(_on_open_failed)

	# 开始动画序列
	_start_intro()


# ====== 1. 标题淡入 ======
func _start_intro():
	var t := create_tween()
	t.tween_property(title_label, "modulate:a", 1.0, 0.8).set_ease(Tween.EASE_OUT)
	t.tween_interval(0.6)
	t.tween_callback(_start_scanning)


# ====== 2. 标题先上移，停止后再启动扫描动画 ======
func _start_scanning():
	current_state = State.SCANNING

	var t := create_tween()
	# 第一步：标题平滑上移到目标 Y（0.8s）
	t.tween_method(_apply_title_y, 0.0, TITLE_TOP_Y, 0.8).set_ease(Tween.EASE_IN_OUT)
	# 停稳后等待 0.4s
	t.tween_interval(0.4)
	# 第二步：扫描面板淡入（0.4s）
	t.tween_property(scanning_panel, "modulate:a", 1.0, 0.4).set_ease(Tween.EASE_OUT)
	# 第三步：扫描动画
	t.tween_callback(_run_scan_line)


func _apply_title_y(dy: float):
	# 居中锚点：同时调整 offset_top 和 offset_bottom 来上下移动
	title_label.offset_top = _title_base_top + dy
	title_label.offset_bottom = _title_base_bottom + dy


# ====== 还原标题到初始居中位置 ======
func _reset_title_position():
	title_label.offset_top = _title_base_top
	title_label.offset_bottom = _title_base_bottom


# ====== 3. 扫描线从上到下扫过 ======
func _run_scan_line():
	status_label.text = "检测环境"
	if scan_material:
		scan_material.set_shader_parameter("scan_pos", 0.0)

		var t := create_tween()
		t.tween_method(_set_scan_pos, 0.0, 1.0, 1.5).set_ease(Tween.EASE_IN_OUT)
		t.tween_callback(_check_environment)
	else:
		await get_tree().create_timer(0.8).timeout
		_check_environment()


func _set_scan_pos(val: float):
	if scan_material:
		scan_material.set_shader_parameter("scan_pos", val)
	var dots := ""
	var d := int(val * 12.0) % 4
	for i in range(d):
		dots += "."
	status_label.text = "检测环境" + dots


# ====== 4. 执行检测 ======
func _check_environment():
	current_state = State.CHECK_ITEMS
	if scan_material:
		scan_material.set_shader_parameter("scan_pos", 0.5)

	python_status.text = "..."
	python_status.modulate = Color(0.5, 0.5, 0.5)
	openpyxl_status.text = ""
	openpyxl_status.modulate = Color(0.3, 0.3, 0.3)

	await get_tree().create_timer(0.6).timeout

	env.run_check()

	var t1 := create_tween()
	t1.tween_callback(func():
		if env.has_python:
			python_status.text = "\u2713"
			python_status.modulate = Color(0.2, 1.0, 0.4)
		else:
			python_status.text = "\u2717"
			python_status.modulate = Color(1.0, 0.25, 0.25)
	)
	t1.tween_interval(0.5)
	t1.tween_callback(func():
		openpyxl_status.text = "..."
		openpyxl_status.modulate = Color(0.5, 0.5, 0.5)
	)
	t1.tween_interval(0.5)
	t1.tween_callback(func():
		if env.has_openpyxl:
			openpyxl_status.text = "\u2713"
			openpyxl_status.modulate = Color(0.2, 1.0, 0.4)
		else:
			openpyxl_status.text = "\u2717"
			openpyxl_status.modulate = Color(1.0, 0.25, 0.25)
	)

	t1.tween_interval(0.6)
	t1.tween_callback(func():
		if env.is_ready():
			_show_success()
		else:
			_show_env_fail()
	)


# ====== 5a. 成功 → 过渡到项目面板 ======
func _show_success():
	if _skipped:
		return
	current_state = State.SUCCESS
	status_label.text = "环境就绪"

	if scan_material:
		scan_material.set_shader_parameter("glow_color", Color(0.2, 1.0, 0.4, 0.9))

	await get_tree().create_timer(0.8).timeout

	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(scanning_panel, "modulate:a", 0.0, 0.5)
	t.tween_property(title_label, "modulate:a", 0.0, 0.5)
	t.set_parallel(false)
	t.tween_callback(func():
		scanning_panel.visible = false
		title_label.visible = false
		_show_project_controls()
	)


# ====== 5b. 失败 → 显示安装面板 ======
func _show_env_fail():
	if _skipped:
		return
	current_state = State.ENV_FAIL
	status_label.text = "环境未就绪"

	if scan_material:
		scan_material.set_shader_parameter("glow_color", Color(1.0, 0.25, 0.25, 0.9))

	await get_tree().create_timer(0.8).timeout

	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(scanning_panel, "modulate:a", 0.0, 0.5)
	t.tween_property(title_label, "modulate:a", 0.0, 0.5)
	t.set_parallel(false)
	t.tween_callback(func():
		scanning_panel.visible = false
		title_label.visible = false
		_show_install_panel()
	)


# ====== 显示安装面板 ======
func _show_install_panel():
	install_panel.visible = true
	install_panel.modulate.a = 0.0

	var msg := ""
	if not env.has_python:
		msg = "未检测到 Python 环境\n\n请安装 Python 3.8+ 并确保已添加到系统 PATH，然后执行："
		command_label.text = "pip install openpyxl"
	elif not env.has_openpyxl:
		msg = "Python 已就绪，但缺少 openpyxl 模块\n\n请在终端执行以下命令安装："
		command_label.text = "pip install openpyxl"

	install_desc.text = msg

	var t := create_tween()
	t.tween_property(install_panel, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_OUT)


# ====== 显示项目控件 ======
func _show_project_controls():
	project_panel.visible = true
	project_panel.modulate.a = 0.0

	var t := create_tween()
	t.tween_property(project_panel, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_OUT)


# ====== 使用说明 / 版权内容 ======
const HELP_TEXT: String = """【PoTranslator by HAN · 使用说明】

本工具用于翻译 UE 导出的 .po 文件，支持多项目管理、xlsx 规则表驱动翻译与 Google 免费 API。

■ 启动界面按钮
· ？— 点击查看本使用说明
· ！— 点击查看版权条款声明
· 新建项目 — 选择目录并创建新项目文件夹（自动放入模板 PO 文件和规则表）
· 打开项目 — 选择已有的 .pohtran 项目文件继续工作

■ 翻译界面按钮
· 顶部 API 下拉框 — 选择翻译引擎（目前只有 Google 非官方翻译）
· 检测按钮 — 检测所选 API 是否可用
· 顶部语言下拉框 — 设置源语言（左）和目标语言（右）
· [×] 关闭按钮 — 关闭当前项目翻译界面，返回启动界面
· 文件名选项卡 — 切换不同 PO 文件（按需加载，点击时才解析）
· [模糊搜索] 输入框 — 回车后按关键词模糊匹配 msgid/msgstr
· [精确搜索] 输入框 — 回车后按关键词精确匹配 msgid/msgstr
· 筛选复选框 — 按翻译来源（AI/人工/规则/记忆/未翻译/空条目）过滤显示
· [刷新] — 重新加载当前 PO 文件
· [一键翻译] — 使用API自动翻译所有空 msgstr（25条/组写入）；翻译中再次点击可取消
· [清空译文] — 长按清空当前页面所有翻译的 msgstr
· [配置] 按钮（左下角）— 在文件管理器中打开项目目录，方便放入/取出 PO 文件和调整规则表

■ 翻译漏斗优先级
手动输入 → 规则表(xlsx) → 翻译记忆(Memory) → API翻译 → 未翻译(留空)

■ 项目文件说明
· .pohtran — 项目配置文件（JSON 格式）
· project.po   — 项目专属 PO 文件
· 翻译规则.xlsx — Excel 规则表（Python openpyxl 读取）
· .po — 待翻译的 PO 文件（可放入项目目录）

■ 环境要求
· Python 3.8+（需在系统 PATH 中）
· openpyxl 模块（pip install openpyxl）
· Godot 4.7 GL Compatibility"""

const COPYRIGHT_TEXT: String = """【版权条款声明】

PoTranslator by HAN

软件制作：Bilibili@海鸦Heroop 夏明含
制作软件：Godot 4.7 + Trae CN + Deepseek-v4-pro
本软件基于 Elastic License 2.0 授权，并附加以下补充条款。

■ 许可范围
在遵守本许可证的前提下，您被允许：
· 免费使用本软件的全部功能（本软件仅提供PO操作功能，翻译功能需要额外遵守翻译API的条款，默认的非官方谷歌翻译仅供学习交流使用，正式商用需要自己接入正版API，因类似问题导致的版权纠纷作者概不负责。）
· 将本软件用于个人用途或组织内部非商业用途
· 查看、学习和研究本软件源代码
· 对源代码进行修改、调试与本地运行
· 在非商业用途范围内创建 fork 或衍生版本

■ 严格禁止行为
在未获得版权所有者明确书面授权的情况下，您不得：
· 将本软件或其任何修改版本用于商业目的
· 将本软件或其衍生版本进行出售、租赁或收费提供
· 将本软件重新打包并作为产品发布或上架（包括但不限于：应用商店、插件市场、浏览器扩展商店、SaaS平台等）
· 以本软件或其衍生版本提供任何形式的付费服务
· 将本软件作为商业产品的一部分或嵌入商业服务中使用
· 删除或篡改本软件的版权声明或许可证信息
· 使用本软件进行商业竞争性产品开发或替代性服务构建

■ 衍生作品与 Fork 规则
· 您可以创建 fork 或修改版本，但仅限非商业用途
· 衍生版本不得用于任何形式的盈利或商业发布
· 衍生版本必须保留本许可证及版权声明
· 衍生版本不得使用本软件名称、品牌或任何容易混淆的标识进行发布或宣传
· 不得暗示您的版本为官方版本或与官方版本存在关联

■ 免责声明
本软件按"原样（AS IS）"提供，不附带任何形式的明示或暗示保证。
翻译结果仅供参考，不保证绝对准确性、语义完整性或语境适配性。用户应自行对翻译结果进行判断与验证。
在任何情况下，作者均不对因使用本软件而产生的任何直接或间接损失承担责任。
对于第三方服务的可用性、准确性、稳定性、安全性，作者不作任何保证。

■ 第三方组件
· Godot Engine (MIT License)
· openpyxl (MIT License)
· Python (PSF License)
各第三方组件版权归其各自所有者所有。"""

# ====== 按钮回调 ======
func _on_retry_pressed():
	install_panel.visible = false
	scanning_panel.visible = true
	scanning_panel.modulate.a = 0.0
	python_status.text = ""
	openpyxl_status.text = ""
	# 重置标题状态到顶部（重检从顶部开始，不再居中淡入）
	title_label.visible = true
	title_label.modulate.a = 1.0
	_reset_title_position()
	_start_scanning()


func _on_exit_pressed():
	get_tree().quit()


func _on_help_pressed():
	popup_title.text = "使用说明"
	popup_content.text = HELP_TEXT
	info_popup.visible = true
	info_popup.modulate.a = 0.0
	var t := create_tween()
	t.tween_property(info_popup, "modulate:a", 1.0, 0.3).set_ease(Tween.EASE_OUT)


func _on_copyright_pressed():
	popup_title.text = "版权声明"
	popup_content.text = COPYRIGHT_TEXT
	info_popup.visible = true
	info_popup.modulate.a = 0.0
	var t := create_tween()
	t.tween_property(info_popup, "modulate:a", 1.0, 0.3).set_ease(Tween.EASE_OUT)


func _on_popup_close_pressed():
	var t := create_tween()
	t.tween_property(info_popup, "modulate:a", 0.0, 0.25).set_ease(Tween.EASE_IN)
	t.tween_callback(func():
		info_popup.visible = false
	)


func _on_new_project_pressed():
	_new_project.start_new()


func _on_open_project_pressed():
	_open_project.start_open()


func _on_project_created(path: String):
	print("[Start] 项目已创建: " + path)
	_open_translate(path)


func _on_creation_failed(reason: String):
	print("[Start] 创建失败: " + reason)


func _on_project_opened(path: String):
	print("[Start] 打开项目: " + path)
	_open_translate(path)


func _on_open_failed(reason: String):
	print("[Start] 打开失败: " + reason)


func _open_translate(project_path: String):
	project_panel.visible = false
	var translate_script = load("res://Main/Translate/translate.gd")
	translate_script.open(project_path, _on_translate_return)


func _on_translate_return():
	# Translate 场景已自清理，直接回到项目面板跳过自检
	_show_project_controls()


# ====== 编辑器内点击跳过环境检测 ======
func _input(event: InputEvent):
	if not OS.has_feature("editor"):
		return
	if _skipped:
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_skipped = true
		editor_skip_label.visible = false
		_skip_to_project()


func _skip_to_project():
	# 停止所有 tween 动画，直接跳到项目面板
	var tweens = get_tree().get_processed_tweens()
	for t in tweens:
		if is_instance_valid(t):
			t.kill()

	title_label.visible = false
	scanning_panel.visible = false
	install_panel.visible = false
	_show_project_controls()
