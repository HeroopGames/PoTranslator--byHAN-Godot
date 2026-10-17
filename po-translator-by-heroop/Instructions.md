# PoTranslator by HAN — 开发使用说明

---

## 工程概述

基于 **Godot 4.7 (GL Compatibility)** 的 PO 文件翻译工具，用于翻译 UE 导出的 `.po` 文件。核心特性：多项目管理、xlsx 规则表驱动翻译、优先级翻译漏斗、Google 免费 API。

**开发引擎**：Godot 4.7  
**渲染模式**：GL Compatibility（兼容桌面 + Web 导出）  
**语言**：GDScript + Canvas Item Shader  
**外部依赖**：系统 Python 3.8+ + openpyxl（运行时检测，不内置）

---

## 文件结构

```
po-translator-by-heroop/
├── project.godot                    # 项目配置（主场景指向 Main/Start/start.tscn）
├── Instructions.md                  # 本文件
│
├── digital_rain/                    # 【模块：数字雨特效背景】可复用
│   ├── digital_rain.tscn            #    场景根节点（Control），含 RainLayer + DarkOverlay
│   ├── digital_rain.gdshader        #    canvas_item shader，6种伪ASCII字符，列间随机
│   └── digital_rain_bg.gd           #    纯壳脚本，无业务逻辑
│
└── Main/
    └── Start/                       # 【模块：启动场景】当前主场景
        ├── start.tscn               #    场景根节点，实例化 digital_rain 作为背景
        ├── start.gd                 #    核心控制器：动画状态机 + 环境检测流程
        ├── env_checker.gd           #    Python/openpyxl 环境检测（OS.execute）
        └── scan_line.gdshader       #    扫描线特效 shader（检测动画用）
```

### 资产组织规则

以功能模块为单位建文件夹，模块内包含该功能的所有 `.gd` / `.tscn` / `.gdshader`，不按文件类型分散目录。

---

## 场景架构

### Main/Start/start.tscn（当前主场景）

```
Start (Control)                        ← 根节点，脚本 start.gd
├── DigitalRainBg                      ← 实例化 digital_rain.tscn，全屏数字雨背景
│   ├── RainLayer (ColorRect)          ← ShaderMaterial = digital_rain.gdshader
│   └── DarkOverlay (ColorRect)        ← 0.7 透明度纯黑遮罩压低亮度
│
├── TitleLabel (Label)                 ← 居中 "PoTranslator by HAN"，动画后淡出
│
├── ScanningPanel (Control)            ← 环境检测动画层（初始隐藏，检测时显示）
│   ├── ScanOverlay (ColorRect)        ← ShaderMaterial = scan_line.gdshader
│   └── ScanInfo (VBoxContainer)       ← 居中信息区
│       ├── StatusLabel                ← "检测环境" / "环境就绪" / "环境未就绪"
│       ├── PythonRow (HBox)           ← ItemName: "Python 环境" + StatusIcon: "..." / "✓" / "✗"
│       └── OpenpyxlRow (HBox)         ← ItemName: "openpyxl 模块" + StatusIcon
│
├── InstallPanel (Control)             ← 环境缺失时显示（初始隐藏）
│   ├── DimBg                          ← 暗绿色半透明遮罩
│   └── InstallBox (VBox)             ← 内容：标题 + 描述 + 命令 + [重新检测] [退出]
│
└── ProjectPanel (Control)             ← 环境就绪时显示（初始隐藏）
    ├── DimBg                          ← 暗绿色半透明遮罩
    └── ProjectBox (VBox)             ← 内容：欢迎语 + [新建项目] [打开项目]
```

---

## 启动流程（start.gd 动画状态机）

```
[程序启动]
  │
  ▼
INTRO: 标题 "PoTranslator by HAN" 从透明淡入（0.8s）
  │
  ▼
SCANNING: 扫描面板淡入，标题变暗（0.5s）
  │        绿色扫描线从 top→bottom 扫过全屏（1.5s）
  │        "检测环境" 文字动画省略号
  ▼
CHECK_ITEMS: 扫描线停中间
  │         1. "Python 环境" 显示 "..." → 检测 → 显示 "✓"(绿) 或 "✗"(红)
  │         2. "openpyxl 模块" 显示 "..." → 检测 → 显示 "✓"(绿) 或 "✗"(红)
  │
  ├─── 两者都通过 ──→ SUCCESS: 扫描线变绿 → 面板淡出 → ProjectPanel 淡入
  │                           显示 "欢迎使用 PoTranslator" + [新建] [打开]
  │
  └─── 任一缺失 ──→ ENV_FAIL: 扫描线变红 → 面板淡出 → InstallPanel 淡入
                              显示具体缺失项 + pip install 命令 + [重新检测] [退出]
```

---

## 关键文件说明

### digital_rain.gdshader
- **类型**：canvas_item（GL Compatibility）
- **Uniform**：`speed`（0.1~3.0）、`density`（0.1~1.0）
- **原理**：全屏 GPU shader，按 14x17 像素网格划分格子，每列独立雨流
- **注意**：不能用 `return`（GL Compatibility 限制），用 if/else 分支代替

### scan_line.gdshader
- **类型**：canvas_item（GL Compatibility）
- **Uniform**：`scan_pos`（0~1，垂直位置）、`line_width`、`glow_color`
- **驱动方式**：`start.gd` 通过 `set_shader_parameter("scan_pos", val)` 用 Tween 动画 0→1

### env_checker.gd
- **API**：`run_check()` 执行检测 → `is_ready()` 获取结果
- **检测逻辑**：`OS.execute("python", ["--version"])` → 失败则试 `python3`
- **openpyxl 检测**：`python -c "import openpyxl; print('OK')"`

---

## 开发注意事项

1. **Shader 限制**：使用 GL Compatibility 渲染器，shader 中不能有 `return`、`switch`、部分 `vec4/vec2` 直接运算。用 `.xy` 取分量，用 if/else 代替 return。

2. **场景引用**：Godot 会为每个资源自动生成 `.uid` 文件。如果遇到 "invalid UID" 警告重启编辑器即可。如果场景加载失败，删除 `.godot/uid_cache.bin` 和 `.godot/shader_cache/` 后重启。

3. **颜色风格**：全局使用 Matrix 绿色系——亮绿 `Color(0.3, 1.0, 0.5)`，暗绿 `Color(0.08, 0.55, 0.18)`，背景黑 `Color(0, 0, 0, 0.7~0.75)`。

4. **按钮信号连接**：在 tscn 中通过 `[connection]` 段声明，无需脚本中 `connect()`。

5. **Web 导出考虑**：当前项目使用 GL Compatibility 渲染器，web 导出为 WebGL 2.0，Shader 和 `OS.execute()` 行为在 web 端可能不同（`OS.execute` 在 web 端不可用），届时需要调整环境检测方案。

---

## 下一步开发

按 [任务清单.md](../../../Godot计划/任务清单.md) 的阶段顺序推进：

- [ ] 阶段 1：项目总览界面（项目列表 + 新建/重命名/删除）
- [ ] 阶段 2：项目工作区界面（PO 文件表格 + 拖放导入）
- [ ] 阶段 3：PO 文件解析/写回（状态机解析器）
- [ ] 阶段 4：xlsx 规则加载（Python 桥接脚本）
- [ ] 阶段 5~8：翻译管线（缓存 → 规则漏斗 → Google API）
- [ ] 阶段 9：UI 完善（进度条、日志、设置面板）
- [ ] 阶段 10：打包 exe + 最终验收
