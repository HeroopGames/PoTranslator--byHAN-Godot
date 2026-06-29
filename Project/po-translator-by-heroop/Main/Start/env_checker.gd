# === PoTranslatorByHAN · 环境检测器 ===
# 通过 OS.execute 检测系统是否安装 Python 和 openpyxl
# API: run_check() 执行检测, is_ready() 返回是否就绪, has_python/has_openpyxl 布尔结果
# 容错: 先试 python, 失败则试 python3; openpyxl 检测同理
extends Node

## 环境检测结果
var has_python: bool = false
var python_version: String = ""
var has_openpyxl: bool = false

## 检查 Python 和 openpyxl 是否存在
func run_check():
	has_python = false
	python_version = ""
	has_openpyxl = false

	var output = []
	var exit_code = OS.execute("python", ["--version"], output, true)
	# output[0] 是 stdout 文本
	match exit_code:
		0:
			if output.size() > 0 and output[0].length() > 0:
				has_python = true
				python_version = output[0].strip_edges()
			else:
				# 有时 python 版本输出到 stderr
				var err_output = []
				OS.execute("python", ["--version"], err_output, false)
				if err_output.size() > 0 and err_output[0].length() > 0:
					has_python = true
					python_version = err_output[0].strip_edges()
		_:
			# 试试 python3
			var output3 = []
			var exit_code3 = OS.execute("python3", ["--version"], output3, true)
			if exit_code3 == 0 and output3.size() > 0 and output3[0].length() > 0:
				has_python = true
				python_version = output3[0].strip_edges()

	# 检查 openpyxl
	if has_python:
		var oxl_output = []
		var oxl_code = OS.execute("python", ["-c", "import openpyxl; print('OK')"], oxl_output, true)
		if oxl_code != 0:
			var oxl_output3 = []
			oxl_code = OS.execute("python3", ["-c", "import openpyxl; print('OK')"], oxl_output3, true)
		has_openpyxl = (oxl_code == 0)

## 获取状态描述
func is_ready() -> bool:
	return has_python and has_openpyxl
