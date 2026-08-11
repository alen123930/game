extends Node
## WS-5 场景流转测试：验证 Main 状态机加载城镇/地城/战斗/结算场景并互相切换。

var failures := 0
var current_scene_name := ""
var scene_seen := {}


func _ready() -> void:
	print("===== WS-5 scene-flow test begin =====")
	var main := preload("res://scenes/main/main.tscn").instantiate()
	main.name = "Main"
	add_child(main)

	# 等待 Main 进入城镇
	await _wait_frames(5)
	_check(_current_is(main, "Town"), "启动后进入城镇场景")

	# 模拟出发
	GameState.start_run("medium")
	GameState.request_scene(GameState.SCENE_DUNGEON)
	await _wait_frames(5)
	_check(_current_is(main, "DungeonExplore"), "出发后进入地城场景")
	var dungeon_node: Node = main.get("current_scene")
	var dungeon_data: Variant = dungeon_node.get("_dungeon")
	_check(dungeon_node != null and typeof(dungeon_data) == TYPE_DICTIONARY and not (dungeon_data as Dictionary).is_empty(), "地城场景生成了地图")

	# 模拟遇敌 → 切到战斗占位
	var dbg := dungeon_node as Control
	if dbg != null:
		var dungeon: Dictionary = dbg.get("_dungeon")
		var rooms: Array = dungeon["rooms"]
		var battle_id := -1
		for room in rooms:
			if String(room["type"]) == "battle":
				battle_id = int(room["id"])
				break
		if battle_id == -1:
			_check(false, "地图中应存在战斗房")
		else:
			dbg.set("_current_room_id", battle_id)
			var battle_room: Dictionary = rooms[battle_id]
			battle_room["trapped"] = false
			battle_room["locked_door"] = false
			dbg.call("_on_explore_pressed")
	await _wait_frames(5)
	_check(_current_is(main, "BattlePlaceholder"), "遇敌后进入战斗场景")

	# 战斗胜利 → 回地城
	var battle_node: Node = main.get("current_scene")
	if battle_node != null and battle_node.has_method("_on_win_pressed"):
		battle_node.call("_on_win_pressed")
	await _wait_frames(5)
	_check(_current_is(main, "DungeonExplore"), "战斗胜利后回到地城场景")

	# 撤退 → 结算
	var dungeon2: Node = main.get("current_scene")
	if dungeon2 != null and dungeon2.has_method("_on_retreat_pressed"):
		dungeon2.call("_on_retreat_pressed")
	await _wait_frames(5)
	_check(_current_is(main, "Result"), "撤退后进入结算场景")

	# 返回城镇
	var result_node: Node = main.get("current_scene")
	if result_node != null and result_node.has_method("_on_back_pressed"):
		result_node.call("_on_back_pressed")
	await _wait_frames(5)
	_check(_current_is(main, "Town"), "结算后返回城镇场景")

	print("===== WS-5 scene-flow test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _current_is(main: Node, node_name: String) -> bool:
	var cs: Node = main.get("current_scene")
	return cs != null and str(cs.name) == node_name


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)
