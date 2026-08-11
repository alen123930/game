extends Node
## 存档骨架（GDD 7.1 / 7.2）
##
## 1) JSON 存档：user://saves/slot_<n>.json，槽位 1~3，带版本号与损坏降级。
## 2) ConfigFile 封装：user://settings.cfg，存音量/语言等设置。
## 后续存档系统（WS-11）在此基础上扩展自动存档与完整性校验。

const SAVE_DIR := "user://saves"
const SETTINGS_PATH := "user://settings.cfg"
const SAVE_VERSION := 1
const MAX_SLOTS := 3

var _settings := ConfigFile.new()

func _ready() -> void:
	_load_settings()

# ------------------------------------------------------------------
# JSON 存档
# ------------------------------------------------------------------

## 保存到指定槽位，data 为任意可 JSON 序列化的字典。
func save_game(slot: int, data: Dictionary) -> bool:
	if not _valid_slot(slot):
		push_error("SaveManager: 无效存档槽 %d（有效 1~%d）" % [slot, MAX_SLOTS])
		return false

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var payload := {
		"version": SAVE_VERSION,
		"saved_at": Time.get_datetime_string_from_system(),
		"data": data,
	}
	var path := _slot_path(slot)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: 写入失败 %s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	print("[SaveManager] 已保存存档（槽位 %d）到 %s" % [slot, path])
	return true

## 读取指定槽位；文件缺失返回空字典，损坏或版本不符返回空字典并打印告警（降级处理）。
func load_game(slot: int) -> Dictionary:
	var path := _slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("SaveManager: 读取失败 %s" % path)
		return {}
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("SaveManager: 存档损坏（无法解析）%s，按空档处理" % path)
		return {}
	if int(parsed.get("version", -1)) != SAVE_VERSION:
		push_warning("SaveManager: 存档版本不兼容 %s（v%s，当前 v%d），按空档处理" % [path, parsed.get("version"), SAVE_VERSION])
		return {}
	return parsed.get("data", {})

func has_save(slot: int) -> bool:
	return _valid_slot(slot) and FileAccess.file_exists(_slot_path(slot))

func delete_save(slot: int) -> bool:
	if not _valid_slot(slot):
		return false
	var path := _slot_path(slot)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK

## 返回已存在的槽位列表（升序）。
func list_saves() -> Array[int]:
	var result: Array[int] = []
	for slot in range(1, MAX_SLOTS + 1):
		if has_save(slot):
			result.append(slot)
	return result

func _slot_path(slot: int) -> String:
	return "%s/slot_%d.json" % [SAVE_DIR, slot]

func _valid_slot(slot: int) -> bool:
	return slot >= 1 and slot <= MAX_SLOTS

# ------------------------------------------------------------------
# ConfigFile 设置封装
# ------------------------------------------------------------------

func get_setting(key: String, default: Variant = null) -> Variant:
	return _settings.get_value("settings", key, default)

func set_setting(key: String, value: Variant) -> void:
	_settings.set_value("settings", key, value)
	var err := _settings.save(SETTINGS_PATH)
	if err != OK:
		push_warning("SaveManager: 设置保存失败（%s）" % error_string(err))

func _load_settings() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if _settings.load(SETTINGS_PATH) != OK:
		_settings = ConfigFile.new()
