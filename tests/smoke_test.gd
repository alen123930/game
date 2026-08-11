extends Node
## 冒烟测试（本地/CI 用，不参与正式游戏流程）：
## 1) 校验 ConfigManager 8 个配置节加载与关键条目
## 2) 驱动 Main 状态机走通 城镇→探索→战斗→结算→城镇 闭环
## 3) 验证 SaveManager JSON 存档 + ConfigFile 读写
##
## 运行：godot --headless --path . res://tests/smoke_test.tscn

var _failures := 0

func _ready() -> void:
	await get_tree().process_frame
	_test_config()
	await _test_state_machine()
	await _test_save()
	print("[SmokeTest] %s（失败 %d 项）" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[SmokeTest]   ok   " + msg)
	else:
		_failures += 1
		print("[SmokeTest]   FAIL " + msg)

func _test_config() -> void:
	_check(ConfigManager.is_loaded(), "ConfigManager 完成加载")
	# get_section 返回整节字典（含 _meta 元数据），实体数 = 总键数 - 1。
	var expected := {
		"heroes": 8, "skills": 32, "monsters": 24, "dungeons": 4,
		"buildings": 8, "loot_tables": 5, "quirks": 12, "items": 9,
	}
	for section: String in expected:
		var dict: Dictionary = ConfigManager.get_section(section)
		var entity_count := dict.size() - (1 if dict.has("_meta") else 0)
		_check(entity_count == expected[section], "%s 实体数 = %d（期望 %d）" % [section, entity_count, expected[section]])
	_check(ConfigManager.get_entry_total() == 110, "全部配置实体总数 = 110")
	_check(ConfigManager.get_section("loot_tables").has("_meta"), "loot_tables 含 _meta（exp_formula 等）")
	_check(ConfigManager.get_entry("heroes", "knight").get("name", "") == "圣骑士", "heroes.knight.name = 圣骑士")
	_check(ConfigManager.get_entry("monsters", "boss_stone_skull").get("phases", 0) == 2, "boss_stone_skull.phases = 2")
	_check(ConfigManager.get_entry("loot_tables", "1").get("gold_min", 0) == 600, "loot_tables.1.gold_min = 600")
	_check(ConfigManager.has_entry("items", "torch"), "items 包含 torch")
	_check(ConfigManager.get_entry("skills", "pierce_shot").get("base_acc", 0) == 90, "skills.pierce_shot.base_acc = 90")

func _test_state_machine() -> void:
	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().current_scene.add_child(main)
	_check(main.get_current_state() == GameMain.GameState.MAIN_MENU, "初始状态 = 主菜单")
	main.change_state(GameMain.GameState.TOWN)
	main.change_state(GameMain.GameState.EXPLORATION)
	main.change_state(GameMain.GameState.BATTLE)
	main.change_state(GameMain.GameState.SETTLEMENT)
	main.change_state(GameMain.GameState.TOWN)
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.TOWN, "闭环 城镇→探索→战斗→结算→城镇 正常")
	main.queue_free()
	await get_tree().process_frame

func _test_save() -> void:
	var payload := { "gold": 1234, "roster": ["knight", "hunter"] }
	_check(SaveManager.save_game(1, payload), "写入槽位 1")
	var loaded: Dictionary = SaveManager.load_game(1)
	_check(loaded.get("gold", -1) == 1234, "读回 gold = 1234")
	_check(SaveManager.has_save(1), "has_save(1) = true")
	_check(SaveManager.list_saves().has(1), "list_saves 含槽位 1")
	_check(SaveManager.delete_save(1), "删除槽位 1")
	_check(not SaveManager.has_save(1), "删除后 has_save(1) = false")

	var bad := FileAccess.open("user://saves/slot_2.json", FileAccess.WRITE)
	bad.store_string("not-json")
	bad.close()
	_check(SaveManager.load_game(2).is_empty(), "损坏存档降级为空字典")
	SaveManager.delete_save(2)

	SaveManager.set_setting("master_volume", 0.5)
	_check(is_equal_approx(float(SaveManager.get_setting("master_volume", -1)), 0.5), "ConfigFile 写入/读回 master_volume")
