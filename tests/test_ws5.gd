extends Node
## WS-5 + WS-19 无头自检：以测试场景为主场景运行，自动加载会正常生效。
## 覆盖：生成器（含走廊/障碍/目标房）、火把、侦查掷骰、4 类任务、撤退无惩罚、陷阱/障碍走廊。
## 运行：godot --headless --path <project> res://tests/test_main.tscn

var failures := 0


func _ready() -> void:
	print("===== WS-5/WS-19 headless test begin =====")
	_test_generator()
	_test_torch()
	_test_scout()
	_test_quest_types()
	_test_retreat_no_penalty()
	_test_full_loop()
	print("===== WS-5/WS-19 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)


# ---------- 测试 1：生成器 ----------

func _test_generator() -> void:
	var config: Dictionary = DataLoader.get_config("exploration.json")
	for length in ["short", "medium", "long"]:
		for qtype in ["explore", "collect", "hunt", "boss"]:
			for seed in range(20):
				var rng := RandomNumberGenerator.new()
				rng.seed = seed + 1
				var dungeon := DungeonGenerator.generate(config, length, qtype, rng)
				_check(_dungeon_valid(dungeon, length, qtype), "生成器 %s/%s seed=%d" % [length, qtype, seed])
				_check(not dungeon.get("corridors", []).is_empty(), "走廊已生成 %s/%s seed=%d" % [length, qtype, seed])
	print("[gen] 生成器测试完成（4 任务类型 × 3 长度 × 20 种子）")


func _dungeon_valid(dungeon: Dictionary, length: String, qtype: String) -> bool:
	var map_cfg: Dictionary = DataLoader.get_config("exploration.json").get("map", {})
	var cols: int = dungeon.get("cols", 0)
	var rows: int = dungeon.get("rows", 0)
	var rooms: Array = dungeon.get("rooms", [])

	if cols < int(map_cfg.get("min_cols", 4)) or cols > int(map_cfg.get("max_cols", 6)):
		return false
	if rows < int(map_cfg.get("min_rows", 4)) or rows > int(map_cfg.get("max_rows", 5)):
		return false

	var ratios: Dictionary = map_cfg.get("room_ratios", {}).get(length, {})
	var expected := 1
	for key in ["battle", "curio", "treasure", "safe"]:
		expected += int(ratios.get(key, 0))
	expected = maxi(expected, int(map_cfg.get("min_rooms", 8)))
	if rooms.size() < expected:
		return false

	if int(dungeon.get("start_room", -1)) != 0:
		return false

	var type_count := {}
	for room in rooms:
		type_count[room["type"]] = int(type_count.get(room["type"], 0)) + 1
	if int(type_count.get("start", 0)) != 1:
		return false
	# 目标房：探索/收集 → goal；狩猎/Boss → boss
	var goal_room: Dictionary = rooms[int(dungeon.get("goal_room", -1))]
	if qtype in ["explore", "collect"]:
		if String(goal_room["type"]) != "goal":
			return false
	elif String(goal_room["type"]) != "boss":
		return false

	# 走廊：每条走廊 from/to 必须存在且端点相邻，类型合法
	var corr_cfg: Dictionary = DataLoader.get_config("exploration.json").get("corridors", {})
	var kinds: Array = corr_cfg.get("obstacle_kinds", ["debris", "vines"])
	for corridor in dungeon.get("corridors", []):
		if not corridor.has("from") or not corridor.has("to"):
			return false
		if not corridor.has("type") or String(corridor["type"]) not in ["normal", "trap", "obstacle"]:
			return false
		if String(corridor["type"]) == "obstacle":
			if not kinds.has(corridor.get("obstacle_kind", "")):
				return false

	var visited := {}
	var frontier := [0]
	visited[0] = true
	while not frontier.is_empty():
		var cur: int = frontier.pop_front()
		for nb in rooms[cur]["connections"]:
			if not visited.has(nb):
				visited[nb] = true
				frontier.append(nb)
	if visited.size() != rooms.size():
		return false
	return true


# ---------- 测试 2：火把三档 ----------

func _test_torch() -> void:
	GameState.start_run("medium")
	GameState.torch = 75
	_check(GameState.get_torch_tier().get("name", "") == "明亮", "火把 75 应为明亮档")
	GameState.torch = 50
	_check(GameState.get_torch_tier().get("name", "") == "昏暗", "火把 50 应为昏暗档")
	GameState.torch = 10
	_check(GameState.get_torch_tier().get("name", "") == "黑暗", "火把 10 应为黑暗档")
	GameState.add_torch(-5)
	_check(GameState.torch == 5, "火把衰减后为 5")
	print("[torch] 火把三档与衰减测试完成")


# ---------- 测试 3：侦查掷骰（WS-19）----------

func _test_scout() -> void:
	GameState.start_run("medium")
	# 火把修正：明亮 +25、昏暗 0、黑暗 -30
	GameState.torch = 75
	var bright_chance := GameState.get_scout_chance()
	GameState.torch = 10
	var dark_chance := GameState.get_scout_chance()
	_check(bright_chance > dark_chance, "明亮档侦查率 > 黑暗档（%.2f vs %.2f）" % [bright_chance, dark_chance])
	# 队伍修正：技能/怪癖/饰品 scout 效果累加
	GameState.party = [
		{"skills": {"evade": 1}, "quirks": [], "trinkets": [null, null]},
	]
	_check(GameState.get_party_scout_bonus() == 10, "技能 evade 提供侦查 +10（实际 %d）" % GameState.get_party_scout_bonus())
	GameState.party = [
		{"skills": {}, "quirks": [{"id": "night_vision"}], "trinkets": [null, null]},
	]
	_check(GameState.get_party_scout_bonus() == 15, "怪癖夜视提供侦查 +15（实际 %d）" % GameState.get_party_scout_bonus())
	GameState.party = [
		{"skills": {}, "quirks": [], "trinkets": ["t_raven_feather", null]},
	]
	_check(GameState.get_party_scout_bonus() == 10, "饰品渡鸦之羽提供侦查 +10（实际 %d）" % GameState.get_party_scout_bonus())
	# 露营接口：中=1、长=2、短=0
	GameState.quest_length = "short"
	_check(GameState.get_camp_count() == 0, "短任务露营次数 = 0")
	GameState.quest_length = "medium"
	_check(GameState.get_camp_count() == 1, "中任务露营次数 = 1")
	GameState.quest_length = "long"
	_check(GameState.get_camp_count() == 2, "长任务露营次数 = 2")
	print("[scout] 侦查掷骰与露营接口测试完成")


# ---------- 测试 4：4 类任务（WS-19）----------

func _test_quest_types() -> void:
	var config: Dictionary = DataLoader.get_config("exploration.json")
	# 收集目标：按长度读取
	GameState.quest_length = "short"
	_check(GameState.get_collect_target() == 2, "短收集任务目标 = 2")
	GameState.quest_length = "medium"
	_check(GameState.get_collect_target() == 3, "中收集任务目标 = 3")
	GameState.quest_length = "long"
	_check(GameState.get_collect_target() == 4, "长收集任务目标 = 4")
	# 任务类型命名（移除旧命名 清剿/远征/救援）
	var qnames := {}
	for q in config.get("quests", {}):
		qnames[q] = String(config["quests"][q].get("name", ""))
	_check(qnames.has("explore") and qnames.has("collect") and qnames.has("hunt") and qnames.has("boss"), "exploration.json 定义 4 类任务")
	# dungeons.json task_types 对齐
	var ruins: Dictionary = ConfigManager.get_entry("dungeons", "ruins")
	var tids: Array = []
	for t in ruins.get("task_types", []):
		tids.append(String(t.get("id", "")))
	_check(tids == ["explore", "collect", "hunt", "boss"], "dungeons.json task_types 对齐 4 类（实际 %s）" % str(tids))
	_check(not tids.has("hunt_old") and not tids.has("purge") and not tids.has("expedition") and not tids.has("rescue"), "旧任务命名（清剿/远征/救援）已移除")
	# 撤退无惩罚：70% 折扣配置已移除
	var loot_meta: Dictionary = ConfigManager.get_entry("loot_tables", "_meta")
	_check(not loot_meta.has("retreat_settle_mult"), "撤退 70% 折扣配置已移除")
	print("[quest] 4 类任务对齐测试完成")


# ---------- 测试 5：撤退无惩罚（WS-19）----------

func _test_retreat_no_penalty() -> void:
	GameState.start_run("medium")
	GameState.run_gold = 500
	GameState.result_payload = {
		"outcome": "retreat", "rooms_cleared": 3, "gold": GameState.run_gold,
		"boss_defeated": false, "torch": 40, "party": GameState.party,
	}
	var gold_before: int = TownManager.gold
	var settle := TownManager.settle_run(GameState.result_payload)
	_check(int(settle.get("gold_awarded", 0)) == 500, "撤退保留全部战利品（%d）" % settle.get("gold_awarded", 0))
	_check(TownManager.gold - gold_before == 500, "城镇金币全额入账（撤退无折扣）")
	print("[retreat] 撤退无惩罚测试完成")


# ---------- 测试 6：全流程 ----------

func _test_full_loop() -> void:
	GameState.start_run("medium", "explore")
	GameState.current_dungeon = DungeonGenerator.generate(DataLoader.get_config("exploration.json"), "medium", "explore")
	var dungeon: Dictionary = GameState.current_dungeon
	var rooms: Array = dungeon["rooms"]
	var corridors: Array = dungeon["corridors"]
	GameState.current_pos = int(dungeon["start_room"])

	# 走廊障碍/陷阱：直接清除/拆除（机制在场景中交互，这里验证数据结构可用）
	var guard := 0
	var acted_this_pass := true
	while acted_this_pass and GameState.run_active and guard < 500:
		acted_this_pass = false
		guard += 1
		var room: Dictionary = rooms[GameState.current_pos]
		if not room.get("explored", false):
			room["revealed"] = true
			room["scouted"] = true
			if room.get("trapped", false) and not room.get("trap_disarmed", false):
				room["trap_disarmed"] = true
				GameState.damage_party(1, 2)
				acted_this_pass = true
			match String(room["type"]):
				"battle", "boss":
					var is_boss := String(room["type"]) == "boss"
					GameState.pending_battle = {"room_id": int(room["id"]), "is_boss": is_boss, "monsters": ["骷髅士兵"], "torch_tier": "昏暗"}
					GameState.battle_result = {"victory": true, "room_id": int(room["id"]), "is_boss": is_boss}
					GameState.pending_battle = {}
					room["explored"] = true
					GameState.rooms_cleared += 1
					if is_boss:
						GameState.boss_defeated = true
					acted_this_pass = true
				"treasure", "curio", "goal", "safe":
					if String(room["type"]) == "goal" and GameState.quest_type == "explore":
						room["explored"] = true
						GameState.rooms_cleared += 1
						GameState.run_active = false
					else:
						room["explored"] = true
						GameState.rooms_cleared += 1
						GameState.add_torch(-int(GameState.get_torch_config().get("decay_per_room", 5)))
					acted_this_pass = true
				"start":
					room["explored"] = true
					acted_this_pass = true
		if not acted_this_pass and GameState.run_active:
			for nb in room.get("connections", []):
				if not rooms[nb].get("explored", false):
					if rooms[nb].get("locked_door", false):
						rooms[nb]["locked_door"] = false
						GameState.consume_supply("key", 1)
					# 走廊障碍/陷阱模拟处理
					for corridor in corridors:
						var from_id: int = corridor["from"]
						var to_id: int = corridor["to"]
						if (from_id == GameState.current_pos and to_id == nb) or (from_id == nb and to_id == GameState.current_pos):
							if String(corridor.get("type", "")) == "obstacle" and not corridor.get("cleared", false):
								corridor["cleared"] = true
							elif String(corridor.get("type", "")) == "trap" and not corridor.get("disarmed", false):
								corridor["disarmed"] = true
					GameState.current_pos = nb
					GameState.add_torch(-int(GameState.get_torch_config().get("decay_per_room", 5)))
					acted_this_pass = true
					break

	_check(GameState.rooms_cleared >= 1, "探索了至少 1 个房间（实际 %d）" % GameState.rooms_cleared)
	GameState.result_payload = {"outcome": "victory" if GameState.boss_defeated else "retreat", "rooms_cleared": GameState.rooms_cleared, "gold": GameState.run_gold, "boss_defeated": GameState.boss_defeated, "torch": GameState.torch}
	GameState.end_run()
	_check(not GameState.run_active, "结算后 run_active 应为 false")
	print("[loop] 全流程冒烟完成，探索房间数=%d，获得金币=%d" % [GameState.rooms_cleared, GameState.run_gold])


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)