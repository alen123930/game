extends Node
## WS-19 探索对齐无头自检：走廊/障碍/陷阱/侦查掷骰/任务类型/撤退在场景层面验证。
## 运行：godot --headless --path . res://tests/test_ws19.tscn

var failures := 0


func _ready() -> void:
	await get_tree().process_frame
	print("===== WS-19 exploration alignment test begin =====")
	await _test_corridor_obstacle()
	await _test_corridor_trap()
	await _test_quest_completion()
	_test_data_consistency()
	print("===== WS-19 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)


# 构造一个确定性小地图：3 间房（0 起始 / 1 战斗 / 2 目标），走廊可控。
func _make_dungeon(corridor_type: String, obstacle_kind: String = "debris") -> Dictionary:
	var config: Dictionary = DataLoader.get_config("exploration.json")
	var rooms := [
		{"id": 0, "pos": Vector2i(0, 0), "type": "start", "connections": [1], "revealed": true, "explored": false, "trapped": false, "trap_visible": false, "locked_door": false, "looted": false},
		{"id": 1, "pos": Vector2i(1, 0), "type": "battle", "connections": [0, 2], "revealed": true, "explored": false, "trapped": false, "trap_visible": false, "locked_door": false, "looted": false},
		{"id": 2, "pos": Vector2i(2, 0), "type": "goal", "connections": [1], "revealed": true, "explored": false, "trapped": false, "trap_visible": false, "locked_door": false, "looted": false},
	]
	var corridors := [
		{"id": 0, "from": 0, "to": 1, "pos": Vector2(0.5, 0), "type": "normal", "obstacle_kind": "", "cleared": false, "revealed": true, "disarmed": false},
		{"id": 1, "from": 1, "to": 2, "pos": Vector2(1.5, 0), "type": corridor_type, "obstacle_kind": obstacle_kind, "cleared": false, "revealed": true, "disarmed": false},
	]
	return {
		"cols": 3, "rows": 1, "rooms": rooms, "corridors": corridors,
		"start_room": 0, "goal_room": 2, "boss_room": 2, "length": "short", "quest_type": "explore",
		"map_type": "ruins",
		"exploration": config.get("exploration", {}),
		"torch": config.get("torch", {}),
		"traps": config.get("traps", {}),
		"obstacles": config.get("obstacles", {}),
		"corridors_cfg": config.get("corridors", {}),
		"quests": config.get("quests", {}),
		"doors": config.get("doors", {}),
		"loot": config.get("loot", {}),
		"encounters": config.get("encounters", {}),
	}


func _test_corridor_obstacle() -> void:
	GameState.start_run("short", "explore")
	GameState.current_dungeon = _make_dungeon("obstacle", "debris")
	GameState.current_pos = 0
	GameState.supplies["shovel"] = 0

	var expl: Node = load("res://scenes/exploration/Exploration.tscn").instantiate()
	add_child(expl)
	await get_tree().process_frame

	# 先通过正常走廊进入房间 1，再点击目标房 2 触发障碍走廊处理
	expl.call("_on_room_pressed", _dungeon_room(1))
	await get_tree().process_frame
	_check(GameState.current_pos == 1, "正常走廊可通行（进入房间 1）")
	GameState.supplies["shovel"] = 0
	expl.call("_on_room_pressed", _dungeon_room(2))
	await get_tree().process_frame
	var choice: Variant = expl.get("_pending_corridor_id")
	_check(int(choice) == 1, "障碍走廊：点击目标房后进入走廊处理（走廊 id=1）")
	_check(GameState.current_pos == 1, "障碍未清除前不能移动")
	# 徒手尝试分支不崩溃（不校验成败）
	expl.call("_on_clear_obstacle_hand")
	await get_tree().process_frame
	# 再点击一次重新进入走廊处理，用铲子清除
	expl.call("_on_room_pressed", _dungeon_room(2))
	await get_tree().process_frame
	GameState.supplies["shovel"] = 1
	expl.call("_on_clear_obstacle_shovel")
	await get_tree().process_frame
	var corridor: Dictionary = GameState.current_dungeon["corridors"][1]
	_check(corridor.get("cleared", false), "铲子清除障碍后走廊已清")
	_check(GameState.current_pos == 2, "障碍清除后成功进入目标房")

	expl.queue_free()
	await get_tree().process_frame
	print("[corridor] 走廊障碍（碎石/藤蔓需铲子）测试完成")


func _test_corridor_trap() -> void:
	GameState.start_run("short", "explore")
	GameState.current_dungeon = _make_dungeon("trap")
	GameState.current_pos = 0

	var expl: Node = load("res://scenes/exploration/Exploration.tscn").instantiate()
	add_child(expl)
	await get_tree().process_frame

	# 先通过正常走廊进入房间 1，再点击目标房 2 触发陷阱走廊处理
	var hp_before: int = 0
	for h in GameState.party:
		hp_before += int(h["hp"])
	expl.call("_on_room_pressed", _dungeon_room(1))
	await get_tree().process_frame
	expl.call("_on_room_pressed", _dungeon_room(2))
	await get_tree().process_frame
	var choice2: Variant = expl.get("_pending_corridor_id")
	_check(int(choice2) == 1, "陷阱走廊：点击目标房后进入走廊处理")
	expl.call("_on_force_trigger_trap")
	await get_tree().process_frame
	var hp_after: int = 0
	for h in GameState.party:
		hp_after += int(h["hp"])
	var corridor: Dictionary = GameState.current_dungeon["corridors"][1]
	_check(corridor.get("disarmed", false), "陷阱触发后被标记为已处理")
	_check(hp_after < hp_before, "陷阱触发造成伤害（%d → %d）" % [hp_before, hp_after])
	_check(GameState.current_pos == 2, "陷阱触发后进入目标房")

	expl.queue_free()
	await get_tree().process_frame
	print("[corridor] 走廊陷阱（可拆除或触发）测试完成")


func _test_quest_completion() -> void:
	# 探索任务：进入目标房并探索 → 结算 victory
	GameState.start_run("short", "explore")
	GameState.current_dungeon = _make_dungeon("normal")
	GameState.current_pos = 0
	var expl: Node = load("res://scenes/exploration/Exploration.tscn").instantiate()
	add_child(expl)
	await get_tree().process_frame
	expl.call("_on_room_pressed", _dungeon_room(1))
	await get_tree().process_frame
	expl.call("_on_room_pressed", _dungeon_room(2))
	await get_tree().process_frame
	expl.call("_on_explore_pressed")
	await get_tree().process_frame
	var payload: Dictionary = GameState.result_payload
	_check(String(payload.get("outcome", "")) == "victory", "探索任务抵达目标房 → 结算 victory（实际 %s）" % payload.get("outcome", ""))
	expl.queue_free()
	await get_tree().process_frame

	# 收集任务：收集物不足则不能完成
	GameState.start_run("short", "collect")
	GameState.current_dungeon = _make_dungeon("normal")
	GameState.current_pos = 0
	GameState.collect_count = 0
	var expl2: Node = load("res://scenes/exploration/Exploration.tscn").instantiate()
	add_child(expl2)
	await get_tree().process_frame
	expl2.call("_on_room_pressed", _dungeon_room(1))
	await get_tree().process_frame
	expl2.call("_on_room_pressed", _dungeon_room(2))
	await get_tree().process_frame
	expl2.call("_on_explore_pressed")
	await get_tree().process_frame
	_check(GameState.run_active, "收集任务收集物不足时目标房不结算（继续探索）")
	expl2.queue_free()
	await get_tree().process_frame

	GameState.end_run()
	print("[quest] 任务完成结算测试完成")


func _test_data_consistency() -> void:
	# 侦查掷骰入口：进入新房间自动掷骰（exploration.gd _move_to 调用）
	var gd: String = FileAccess.get_file_as_string("res://scenes/exploration/exploration.gd")
	_check(gd.contains("_roll_scout_on_entry"), "exploration.gd 进入新房间自动侦查掷骰")
	_check(gd.contains("_move_to"), "exploration.gd 移动逻辑存在")
	_check(not gd.contains("btn_scout"), "「侦查」按钮已移除")
	_check(not gd.contains("btn_inspect"), "「检查」按钮已移除")
	var tscn: String = FileAccess.get_file_as_string("res://scenes/exploration/Exploration.tscn")
	_check(not tscn.contains("侦查 → 探索 → 检查"), "场景欢迎语不再提示三步流程")
	var gen: String = FileAccess.get_file_as_string("res://scenes/exploration/dungeon_generator.gd")
	_check(gen.contains("\"curio\"") and gen.contains("\"goal\""), "生成器含奇物/目标房节点")
	_check(gen.contains("_build_corridors"), "生成器含走廊生成")
	print("[data] 数据与残留清理一致性测试完成")


func _dungeon_room(id: int) -> Dictionary:
	return GameState.current_dungeon["rooms"][id]