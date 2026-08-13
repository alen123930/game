extends Node
## 剧情章节与旁白文案（WS-15，GDD 第五章）
## 启动时加载 data/narrative.json 为字典缓存，运行期只读。
## 语气规则（GDD 5.5）：第二人称、短句压抑、悲剧底色。

const DATA_PATH := "res://data/narrative.json"

var _data: Dictionary = {}

func _ready() -> void:
	reload()

## 重新加载全部文案（游戏内调试用，启动时自动调用一次）。
func reload() -> void:
	_data.clear()
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("[Narrative] 缺少配置文件: %s" % DATA_PATH)
		return
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		push_warning("[Narrative] 无法打开: %s" % DATA_PATH)
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Narrative] 解析失败: %s" % DATA_PATH)
		return
	_data = parsed
	print("[Narrative] 剧情与旁白文案已加载")

## 语气规则（GDD 5.5）。
func get_tone_rules() -> Array:
	return _data.get("_meta", {}).get("tone_rules", [])

func get_world() -> Dictionary:
	return _data.get("world", {})

func get_act(act_id: String) -> Dictionary:
	return _data.get("acts", {}).get(act_id, {})

func get_faction(faction_name: String) -> Dictionary:
	return _data.get("factions", {}).get(faction_name, {})

## 职业背景文案（heroes.json 的 id → 叙事背景）。
func get_class_background(class_id: String) -> String:
	return String(_data.get("classes", {}).get(class_id, ""))

## 区域进入开场白（随机一行）。
func region_intro(region_id: String) -> String:
	var lines: Array = _data.get("regions", {}).get(region_id, [])
	return _pick(lines)

## 事件文案（随机一行）。
func event_line(event_key: String) -> String:
	var lines: Array = _data.get("events", {}).get(event_key, [])
	return _pick(lines)

## 结算文案（随机一行）。
func settlement_line(outcome: String) -> String:
	var lines: Array = _data.get("settlements", {}).get(outcome, [])
	return _pick(lines)

func _pick(lines: Array) -> String:
	if lines.is_empty():
		return ""
	return String(lines[randi() % lines.size()])
