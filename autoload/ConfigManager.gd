extends Node
## 数据驱动配置层（GDD 7.2）
##
## 启动时把 data/ 下全部 JSON 配置加载为内存字典缓存，运行期只读。
## 改动数值只需编辑 data/*.json，无需改动任何代码。

const DATA_DIR := "res://data"

## 配置节清单（对应 data/ 下文件名）。
const CONFIG_FILES: Array[String] = [
	"heroes", "skills", "monsters", "dungeons",
	"buildings", "loot_tables", "quirks", "items",
	"trinkets", "injuries",
]

## 各配置节必填字段（启动校验用；缺失时打印告警，不阻断加载）。
const REQUIRED_FIELDS := {
	"heroes": ["id", "name", "role", "base_stats", "positions", "skill_ids"],
	"skills": ["id", "name", "type", "source_pos", "target_pos", "base_acc"],
	"monsters": ["id", "name", "region", "role", "base_stats", "skills"],
	"dungeons": ["id", "name", "theme", "difficulty_min", "difficulty_max", "rooms"],
	"buildings": ["id", "name", "levels"],
	"loot_tables": ["star", "gold_min", "gold_max", "heirloom_min", "heirloom_max"],
	"quirks": ["id", "name", "type", "effects"],
	"items": ["id", "name", "price", "effect"],
	"trinkets": ["id", "name", "rarity", "effects"],
	"injuries": ["id", "name", "type", "cure_cost", "effects"],
}

## 只读缓存：key = 配置节名，value = 该节字典（key = 实体 id）。
var _cache: Dictionary = {}
var _validated := false
var _entry_total := 0

func _ready() -> void:
	load_all()

## 运行期只读接口：取整个配置节（约定只读，调用方不得修改）。
func get_section(section: String) -> Dictionary:
	return _cache.get(section, {})

## 运行期只读接口：取单个实体配置，不存在时返回空字典。
func get_entry(section: String, id: String) -> Dictionary:
	var dict: Dictionary = _cache.get(section, {})
	return dict.get(id, {})

func has_entry(section: String, id: String) -> bool:
	return _cache.has(section) and _cache[section].has(id)

func is_loaded() -> bool:
	return _validated

func get_entry_total() -> int:
	return _entry_total

## 启动加载：逐个读取 JSON 为字典并做必填字段校验，打印校验日志。
func load_all() -> void:
	_entry_total = 0
	var issues: Array[String] = []
	for file in CONFIG_FILES:
		var issue := _load_file(file)
		if issue != "":
			issues.append(issue)

	if issues.is_empty():
		_validated = true
		print("[ConfigManager] OK 全部 %d 个配置节加载并校验通过，共 %d 条记录" % [CONFIG_FILES.size(), _entry_total])
	else:
		_validated = false
		for msg in issues:
			push_warning("[ConfigManager] " + msg)
		print("[ConfigManager] 配置加载完成，但有 %d 个问题（见上方告警），共 %d 条记录" % [issues.size(), _entry_total])

## 加载单个 JSON 文件；成功返回空串，失败返回错误信息。
func _load_file(section: String) -> String:
	var path := "%s/%s.json" % [DATA_DIR, section]
	if not FileAccess.file_exists(path):
		return "缺少配置文件 %s" % path

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "无法打开 %s：%s" % [path, error_string(FileAccess.get_open_error())]
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return "%s 解析失败：顶层必须是 JSON 对象" % path

	var data: Dictionary = parsed
	var missing: Array[String] = []
	var validated := 0
	for id: String in data.keys():
		# 以下划线开头的键为节级元数据（_meta），不参与实体校验。
		if id.begins_with("_"):
			continue
		var entry: Variant = data[id]
		if typeof(entry) != TYPE_DICTIONARY:
			missing.append("[%s] 记录 %s 不是对象" % [section, id])
			continue
		var entry_dict: Dictionary = entry
		for field in REQUIRED_FIELDS.get(section, []):
			if not entry_dict.has(field):
				missing.append("[%s]%s 缺少必填字段 %s" % [section, id, field])
				continue
		validated += 1

	_cache[section] = data
	_entry_total += data.size()
	if missing.is_empty():
		print("[ConfigManager] loaded %s.json：%d 条，校验通过" % [section, data.size()])
	else:
		for msg in missing:
			push_warning("[ConfigManager] " + msg)
		print("[ConfigManager] loaded %s.json：%d 条，%d 个字段问题（见上方告警）" % [section, data.size(), missing.size()])
	return ""
