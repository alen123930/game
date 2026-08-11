extends Node
## 数据配置层加载器（GDD 7.2）
## 启动时将 data/*.json 全部加载为字典，运行期只读缓存。

const DATA_DIR := "res://data"
const CONFIG_FILES := [
	"dungeons.json",
]

var _cache := {}
var loaded := false


func _ready() -> void:
	reload_all()


## 重新加载全部配置（游戏内调试用，启动时自动调用一次）。
func reload_all() -> void:
	_cache.clear()
	for file_name in CONFIG_FILES:
		var path := "%s/%s" % [DATA_DIR, file_name]
		if not FileAccess.file_exists(path):
			push_warning("[DataLoader] 缺少配置文件: %s" % path)
			continue
		var parsed: Variant = _parse_json(path)
		if parsed == null:
			push_warning("[DataLoader] 配置文件解析失败: %s" % path)
			continue
		_cache[file_name] = parsed
	loaded = true
	_print_summary()


func _parse_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_warning("[DataLoader] JSON 语法错误(%s): %s" % [path, json.get_error_message()])
		return null
	return json.data


## 取整份配置文件（字典）。
func get_config(file_name: String) -> Dictionary:
	if _cache.has(file_name):
		return _cache[file_name]
	push_warning("[DataLoader] 未加载的配置: %s" % file_name)
	return {}


## 取配置中某个节点。
func get_node_data(file_name: String, node_path: String) -> Variant:
	var cfg: Dictionary = get_config(file_name)
	if cfg.is_empty():
		return null
	var current: Variant = cfg
	for part in node_path.split("/"):
		if typeof(current) == TYPE_DICTIONARY and (current as Dictionary).has(part):
			current = (current as Dictionary)[part]
		else:
			return null
	return current


func _print_summary() -> void:
	var names := PackedStringArray()
	for key in _cache.keys():
		names.append(key)
	print("[DataLoader] 已加载配置 %d 份: %s" % [_cache.size(), ", ".join(names)])
