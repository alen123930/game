extends Node
## WS-5 无头自检：以测试场景为主场景运行，自动加载会正常生效。
## 运行：godot --headless --path <project> res://tests/test_main.tscn

var failures := 0


func _ready() -> void:
	print("===== WS-5 headless test begin =====")
	_test_generator()
	_test_torch()
	_test_full_loop()
	print("===== WS-5 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)


# ---------- 测试 1：生成器 ----------

func _test_generator() -> void:
	var config: Dictionary = DataLoader.get_config("dungeons.json")
	for length in ["short", "medium", "long"]:
		for seed in range(50):
			var rng := RandomNumberGenerator.new()
			rng.seed = seed + 1
			var dungeon := DungeonGenerator.generate(config, length, rng)
			_check(_dungeon_valid(dungeon, length), "生成器 %s seed=%d" % [length, seed])
	print("[gen] 生成器测试完成（150 次）")


func _dungeon_valid(dungeon: Dictionary, length: String) -> bool:
	var map_cfg: Dictionary = DataLoader.get_config("dungeons.json").get("map", {})
	var cols: int = dungeon.get("cols", 0)
	var rows: int = dungeon.get("rows", 0)
	var rooms: Array = dungeon.get("rooms", [])

	if cols < int(map_cfg.get("min_cols", 4)) or cols > int(map_cfg.get("max_cols", 6)):
		return false
	if rows < int(map_cfg.get("min_rows", 4)) or rows > int(map_cfg.get("max_rows", 5)):
		return false

	var ratios: Dictionary = map_cfg.get("room_ratios", {}).get(length, {})
	var expected := 1
	for key in ["battle", "treasure", "event", "safe", "boss"]:
		expected += int(ratios.get(key, 0))
	if rooms.size() < expected:
		return false

	if int(dungeon.get("start_room", -1)) != 0:
		return false

	var type_count := {}
	for room in rooms:
		type_count[room["type"]] = int(type_count.get(room["type"], 0)) + 1
	if int(type_count.get("start", 0)) != 1:
		return false
	if length == "long":
		if int(type_count.get("boss", 0)) != 1:
			return false
		var boss_room: Dictionary = rooms[int(dungeon.get("boss_room", -1))]
		if String(boss_room["type"]) != "boss":
			return false
	else:
		if int(type_count.get("boss", 0)) != 0:
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


# ---------- 测试 3：全流程 ----------

func _test_full_loop() -> void:
	GameState.start_run("medium")
	GameState.current_dungeon = DungeonGenerator.generate(DataLoader.get_config("dungeons.json"), "medium")
	var dungeon: Dictionary = GameState.current_dungeon
	var rooms: Array = dungeon["rooms"]
	GameState.current_pos = int(dungeon["start_room"])

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
				"treasure", "event", "safe":
					room["explored"] = true
					GameState.rooms_cleared += 1
					GameState.add_torch(-int(GameState.get_torch_config().get("decay_per_room", 5)))
					acted_this_pass = true
				"start":
					room["explored"] = true
					acted_this_pass = true
		if not acted_this_pass:
			for nb in room.get("connections", []):
				if not rooms[nb].get("explored", false):
					if rooms[nb].get("locked_door", false):
						rooms[nb]["locked_door"] = false
						GameState.consume_supply("key", 1)
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
