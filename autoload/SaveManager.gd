extends Node
## 存档系统（GDD 7.1 / 7.2，WS-11 完整实现）
##
## 1) JSON 存档：user://saves/slot_<n>.json（手动槽 1~3），带版本号与损坏降级。
## 2) 自动存档：user://saves/autosave.json（每节点/每战斗后，独立于手动槽）。
## 3) ConfigFile 封装：user://settings.cfg，存音量/语言等设置。
## 4) 读档与完整性校验：校验失败/损坏/版本不符 → 降级（空档），绝不崩溃。
##
## 全量存档覆盖（capture_state/restore_state）：
##   - 城镇状态：金币/传承物/补给/饰品、建筑等级、名册（属性/装备/压力/怪癖/伤病）、
##               候选、刷新次数、已选队伍、英雄序号、墓地计数、RNG 状态
##   - 任务进度：地图数据/当前位置/火把/房间进度/Boss/任务长度/队伍/补给/战斗衔接/结算载荷

const SAVE_DIR := "user://saves"
const SETTINGS_PATH := "user://settings.cfg"
const AUTOSAVE_PATH := "user://saves/autosave.json"
const SAVE_VERSION := 2
const MAX_SLOTS := 3

var _settings := ConfigFile.new()

func _ready() -> void:
	_load_settings()

# ------------------------------------------------------------------
# 低层：JSON 写入 / 读取（含版本与损坏降级）
# ------------------------------------------------------------------

## 写入任意 data 到指定槽位（低层原语，供 save_slot / 测试复用）。
func save_game(slot: int, data: Dictionary) -> bool:
	if not _valid_slot(slot):
		push_error("SaveManager: 无效存档槽 %d（有效 1~%d）" % [slot, MAX_SLOTS])
		return false
	return _write_payload(_slot_path(slot), data)

## 读取指定槽位的 data 字典；缺失/损坏/版本不符返回空字典（降级）。
func load_game(slot: int) -> Dictionary:
	if not _valid_slot(slot):
		return {}
	var payload := _read_payload(_slot_path(slot))
	if payload.is_empty():
		return {}
	return payload.get("data", {})

## 读取指定槽位的完整存档载荷（含 version/saved_at），供校验/恢复用。
func read_payload(slot: int) -> Dictionary:
	if not _valid_slot(slot):
		return {}
	return _read_payload(_slot_path(slot))

## 槽位是否存在（仅文件存在，不校验内容）。
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

## 自动存档摘要（UI 用）。
func autosave_info() -> Dictionary:
	var info := {
		"exists": has_autosave(),
		"saved_at": "",
		"gold": -1,
		"roster_count": 0,
		"run_active": false,
	}
	if not info["exists"]:
		return info
	var payload := _read_payload(AUTOSAVE_PATH)
	if payload.is_empty():
		info["exists"] = false
		return info
	info["saved_at"] = String(payload.get("saved_at", ""))
	var data: Dictionary = payload.get("data", {})
	var town: Dictionary = data.get("town", {})
	info["gold"] = int(town.get("gold", -1))
	var roster: Array = town.get("roster", [])
	info["roster_count"] = roster.size()
	var run: Dictionary = data.get("run", {})
	info["run_active"] = bool(run.get("run_active", false))
	return info

## 槽位摘要（UI 用）：{exists, saved_at, gold, roster_count, run_active}。
func slot_info(slot: int) -> Dictionary:
	var info := {
		"exists": has_save(slot),
		"saved_at": "",
		"gold": -1,
		"roster_count": 0,
		"run_active": false,
	}
	if not info["exists"]:
		return info
	var payload := _read_payload(_slot_path(slot))
	if payload.is_empty():
		info["exists"] = false
		return info
	info["saved_at"] = String(payload.get("saved_at", ""))
	var data: Dictionary = payload.get("data", {})
	var town: Dictionary = data.get("town", {})
	info["gold"] = int(town.get("gold", -1))
	var roster: Array = town.get("roster", [])
	info["roster_count"] = roster.size()
	var run: Dictionary = data.get("run", {})
	info["run_active"] = bool(run.get("run_active", false))
	return info

func _slot_path(slot: int) -> String:
	return "%s/slot_%d.json" % [SAVE_DIR, slot]

func _valid_slot(slot: int) -> bool:
	return slot >= 1 and slot <= MAX_SLOTS

func _write_payload(path: String, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var payload := {
		"version": SAVE_VERSION,
		"saved_at": Time.get_datetime_string_from_system(),
		"data": data,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: 写入失败 %s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	print("[SaveManager] 已保存存档到 %s" % path)
	return true

## 读取完整载荷；缺失返回空，损坏或版本不符返回空并告警（降级处理）。
func _read_payload(path: String) -> Dictionary:
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
	return parsed

# ------------------------------------------------------------------
# 全量存档：捕获 / 校验 / 恢复
# ------------------------------------------------------------------

## 捕获当前完整游戏状态（城镇 + 任务进度），供手动/自动存档使用。
func capture_state() -> Dictionary:
	return {
		"town": _capture_town(),
		"run": _capture_run(),
		"quest_progress": {
			"active": GameState.run_active,
			"quest_length": GameState.quest_length,
			"rooms_cleared": GameState.rooms_cleared,
			"boss_defeated": GameState.boss_defeated,
		},
	}

func _capture_town() -> Dictionary:
	return {
		"gold": TownManager.gold,
		"heirlooms": TownManager.heirlooms.duplicate(true),
		"supplies": TownManager.supplies.duplicate(true),
		"trinkets": TownManager.trinkets.duplicate(true),
		"building_levels": TownManager.building_levels.duplicate(true),
		"roster": TownManager.roster.duplicate(true),
		"candidates": TownManager.candidates.duplicate(true),
		"refresh_left": TownManager.refresh_left,
		"selected_party_ids": TownManager._selected_party_ids.duplicate(),
		"hero_uid": TownManager._hero_uid,
		"buried_count": TownManager._buried_count,
		"rng_state": TownManager.rng.state,
	}

func _capture_run() -> Dictionary:
	return {
		"current_dungeon": _to_jsonable(GameState.current_dungeon),
		"current_pos": GameState.current_pos,
		"torch": GameState.torch,
		"run_active": GameState.run_active,
		"rooms_cleared": GameState.rooms_cleared,
		"boss_defeated": GameState.boss_defeated,
		"quest_length": GameState.quest_length,
		"run_gold": GameState.run_gold,
		"party": GameState.party.duplicate(true),
		"supplies": GameState.supplies.duplicate(true),
		"pending_battle": GameState.pending_battle.duplicate(true),
		"battle_result": GameState.battle_result.duplicate(true),
		"result_payload": GameState.result_payload.duplicate(true),
	}

## 完整性校验：检查必需节与字段是否存在、类型是否基本合法。
## 返回 {ok, missing: Array[String], reason: String}；ok=false 时调用方不得恢复。
func validate_save(data: Dictionary) -> Dictionary:
	var missing: Array[String] = []
	if typeof(data) != TYPE_DICTIONARY or data.is_empty():
		return {"ok": false, "missing": ["data"], "reason": "存档数据为空"}

	if not data.has("town"):
		missing.append("town")
	else:
		var town: Variant = data["town"]
		if typeof(town) != TYPE_DICTIONARY:
			missing.append("town 类型")
		else:
			var t: Dictionary = town
			for key in ["gold", "heirlooms", "building_levels", "roster"]:
				if not t.has(key):
					missing.append("town.%s" % key)
			var gold_t := typeof(t.get("gold", -1))
			if gold_t != TYPE_INT and gold_t != TYPE_FLOAT:
				missing.append("town.gold 类型")
			if typeof(t.get("roster", [])) != TYPE_ARRAY:
				missing.append("town.roster 类型")
			if typeof(t.get("heirlooms", {})) != TYPE_DICTIONARY:
				missing.append("town.heirlooms 类型")

	if not data.has("run"):
		missing.append("run")
	else:
		var run: Variant = data["run"]
		if typeof(run) != TYPE_DICTIONARY:
			missing.append("run 类型")

	if not data.has("quest_progress"):
		missing.append("quest_progress")

	return {
		"ok": missing.is_empty(),
		"missing": missing,
		"reason": "，".join(missing) if not missing.is_empty() else "",
	}

## 把捕获的存档恢复进 TownManager / GameState。校验失败返回 false（保持现状态，不崩溃）。
func restore_state(data: Dictionary) -> bool:
	var check := validate_save(data)
	if not check["ok"]:
		push_warning("SaveManager: 存档完整性校验失败，放弃恢复（%s）" % check["reason"])
		return false

	# JSON 数字一律解析为 float，这里把「整数值」归一化回 int，保证恢复后类型与运行期一致。
	_restore_town(_normalize_int(data["town"]))
	_restore_run(_normalize_int(data.get("run", {})))
	return true

func _restore_town(town: Dictionary) -> void:
	TownManager.gold = int(town.get("gold", 0))
	TownManager.heirlooms = (town.get("heirlooms", {}) as Dictionary).duplicate(true)
	TownManager.supplies = (town.get("supplies", {}) as Dictionary).duplicate(true)
	TownManager.trinkets = (town.get("trinkets", []) as Array).duplicate(true)
	TownManager.building_levels = (town.get("building_levels", {}) as Dictionary).duplicate(true)
	TownManager.roster = (town.get("roster", []) as Array).duplicate(true)
	TownManager.candidates = (town.get("candidates", []) as Array).duplicate(true)
	TownManager.refresh_left = int(town.get("refresh_left", 0))
	TownManager._selected_party_ids = (town.get("selected_party_ids", []) as Array).duplicate()
	TownManager._hero_uid = int(town.get("hero_uid", 1))
	TownManager._buried_count = int(town.get("buried_count", 0))
	if town.has("rng_state"):
		TownManager.rng.state = int(town["rng_state"])

func _restore_run(run: Dictionary) -> void:
	GameState.current_dungeon = _from_jsonable(run.get("current_dungeon", {}))
	GameState.current_pos = int(run.get("current_pos", 0))
	GameState.torch = clampi(int(run.get("torch", 75)), 0, 100)
	GameState.run_active = bool(run.get("run_active", false))
	GameState.rooms_cleared = int(run.get("rooms_cleared", 0))
	GameState.boss_defeated = bool(run.get("boss_defeated", false))
	GameState.quest_length = String(run.get("quest_length", "short"))
	GameState.run_gold = int(run.get("run_gold", 0))
	GameState.party = (run.get("party", []) as Array).duplicate(true)
	GameState.supplies = (run.get("supplies", {}) as Dictionary).duplicate(true)
	GameState.pending_battle = (run.get("pending_battle", {}) as Dictionary).duplicate(true)
	GameState.battle_result = (run.get("battle_result", {}) as Dictionary).duplicate(true)
	GameState.result_payload = (run.get("result_payload", {}) as Dictionary).duplicate(true)

# ------------------------------------------------------------------
# 手动存档槽（save_slot / load_slot）
# ------------------------------------------------------------------

## 全量手动存档到槽位 1~3。
func save_slot(slot: int) -> bool:
	return save_game(slot, capture_state())

## 全量读档并恢复；返回是否成功（文件缺失/损坏/校验失败均为 false）。
func load_slot(slot: int) -> bool:
	var payload := _read_payload(_slot_path(slot))
	if payload.is_empty():
		return false
	return restore_state(payload.get("data", {}))

# ------------------------------------------------------------------
# 自动存档（每节点/每战斗后）
# ------------------------------------------------------------------

## 自动存档：写入当前完整状态到 autosave.json。
func autosave() -> bool:
	return _write_payload(AUTOSAVE_PATH, capture_state())

## 读取并恢复自动存档。
func load_autosave() -> bool:
	var payload := _read_payload(AUTOSAVE_PATH)
	if payload.is_empty():
		return false
	return restore_state(payload.get("data", {}))

func has_autosave() -> bool:
	return FileAccess.file_exists(AUTOSAVE_PATH)

func delete_autosave() -> bool:
	if not has_autosave():
		return false
	return DirAccess.remove_absolute(AUTOSAVE_PATH) == OK

## 递归把「值为整数的 float」归一化为 int（JSON 读回后数值型字段类型对齐）。
## 保留真正的浮点（如 crit/prot 小数），只转换 x == int(x) 的整数值。
func _normalize_int(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			var f: float = value
			if f == floor(f) and not is_nan(f) and abs(f) < 1.0e12:
				return int(f)
			return value
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[key] = _normalize_int(value[key])
			return out
		TYPE_ARRAY:
			var out := []
			for item in value:
				out.append(_normalize_int(item))
			return out
		_:
			return value

# ------------------------------------------------------------------
# 序列化辅助（Vector2i 等引擎类型 → 纯 JSON 类型）
# ------------------------------------------------------------------

## 递归把引擎类型转成可 JSON 序列化的纯类型（Vector2i → {"__v2i":[x,y]}）。
func _to_jsonable(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[key] = _to_jsonable(value[key])
			return out
		TYPE_ARRAY:
			var out := []
			for item in value:
				out.append(_to_jsonable(item))
			return out
		TYPE_VECTOR2I:
			var v: Vector2i = value
			return {"__v2i": [v.x, v.y]}
		_:
			return value

## _to_jsonable 的逆变换。
func _from_jsonable(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var d: Dictionary = value
		if d.has("__v2i") and typeof(d["__v2i"]) == TYPE_ARRAY:
			return Vector2i(int(d["__v2i"][0]), int(d["__v2i"][1]))
		var out := {}
		for key in d:
			out[key] = _from_jsonable(d[key])
		return out
	if typeof(value) == TYPE_ARRAY:
		var out := []
		for item in value:
			out.append(_from_jsonable(item))
		return out
	return value

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
