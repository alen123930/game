extends Node
## WS-11 存档系统无头自检（GDD 7.1）。
## 运行：godot --headless --path . res://tests/test_ws11.tscn
##
## 覆盖：
##  1. 全量存档捕获/恢复：城镇状态（金币/传承物/补给/饰品/建筑等级/名册/候选/刷新/队伍/英雄序号/墓地/RNG）
##     + 任务进度（地图/位置/火把/房间/Boss/任务长度/队伍/补给/战斗衔接/结算载荷）
##  2. 手动 3 槽存档：save_slot / load_slot / has_save / delete_save / list_saves / slot_info
##  3. 自动存档：autosave / load_autosave / has_autosave（每节点/每战斗后由场景触发）
##  4. 完整性校验与降级：损坏 JSON / 版本不符 / 缺字段 → 不崩溃、按空档处理
##  5. 场景集成：城镇手动存档 UI、探索节点自动存档、战斗后自动存档、主菜单继续读档

var failures := 0

func _ready() -> void:
	await get_tree().process_frame
	print("===== WS-11 save system test begin =====")
	_cleanup_all_saves()
	_test_capture_restore_full_state()
	_test_hero_state_roundtrip()
	_test_manual_slots()
	_test_validate_and_degrade()
	await _test_exploration_autosave_hook()
	await _test_battle_autosave_hook()
	await _test_main_menu_continue()
	await _test_town_save_ui()
	_cleanup_all_saves()
	print("===== WS-11 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)

func _cleanup_all_saves() -> void:
	for slot in range(1, SaveManager.MAX_SLOTS + 1):
		SaveManager.delete_save(slot)
	SaveManager.delete_autosave()

# ------------------------------------------------------------------
# 1. 全量捕获/恢复
# ------------------------------------------------------------------

func _test_capture_restore_full_state() -> void:
	TownManager.reset_game(11)
	TownManager.add_gold(5000)
	TownManager.add_heirloom("statue", 3)
	TownManager.add_heirloom("scroll", 2)
	TownManager.add_supply("torch", 4)
	TownManager.add_trinket("t_ring")
	TownManager.upgrade_building("clinic")
	TownManager.refresh_candidates()
	# 招募 2 名英雄并打磨细节
	var recruited := 0
	for i in 2:
		if TownManager.candidates.is_empty():
			break
		var hero := TownManager.recruit(0)
		if hero.is_empty():
			break
		recruited += 1
		hero["stress"] = 42
		hero["hp"] = hero["max_hp"] - 5
		hero["injuries"] = ["bruise"]
		hero["skills"][hero["skills"].keys()[0]] = 2
		hero["trinkets"][0] = "t_ring"
	_check(recruited == 2, "准备存档数据：招募 2 名英雄")
	var party_ids: Array = []
	for hero in TownManager.roster:
		party_ids.append(hero["id"])
	TownManager.select_party(party_ids)

	# 快照关键字段
	var gold_before := TownManager.gold
	var heirlooms_before: Dictionary = TownManager.heirlooms.duplicate(true)
	var buildings_before: Dictionary = TownManager.building_levels.duplicate(true)
	var supplies_before: Dictionary = TownManager.supplies.duplicate(true)
	var trinkets_before: Array = TownManager.trinkets.duplicate(true)
	var roster_before: Array = TownManager.roster.duplicate(true)
	var candidates_before: Array = TownManager.candidates.duplicate(true)
	var refresh_before := TownManager.refresh_left
	var hero_uid_before := TownManager._hero_uid
	var buried_before := TownManager._buried_count
	var selected_before: Array = TownManager._selected_party_ids.duplicate()

	# 捕获 + 存档
	var data := SaveManager.capture_state()
	_check(SaveManager.validate_save(data).get("ok", false), "capture_state 通过完整性校验")
	_check(SaveManager.save_slot(1), "手动存档到槽位 1")

	# 破坏性修改
	TownManager.gold = 0
	TownManager.add_heirloom("statue", -999)
	TownManager.building_levels["clinic"] = 1
	TownManager.supplies.clear()
	TownManager.trinkets.clear()
	TownManager.roster.clear()
	TownManager.candidates.clear()
	TownManager._selected_party_ids.clear()

	# 恢复
	_check(SaveManager.load_slot(1), "读档槽位 1 并恢复")

	_check(TownManager.gold == gold_before, "读档后金币恢复（%d）" % TownManager.gold)
	_check(TownManager.heirlooms == heirlooms_before, "读档后传承物恢复")
	_check(TownManager.building_levels == buildings_before, "读档后建筑等级恢复")
	_check(TownManager.supplies == supplies_before, "读档后城镇补给恢复")
	_check(TownManager.trinkets == trinkets_before, "读档后饰品仓库恢复")
	_check(TownManager.roster.size() == roster_before.size(), "读档后名册恢复（%d 人）" % TownManager.roster.size())
	_check(TownManager.candidates.size() == candidates_before.size(), "读档后候选恢复（%d 人）" % TownManager.candidates.size())
	_check(TownManager.refresh_left == refresh_before, "读档后刷新次数恢复（%d）" % TownManager.refresh_left)
	_check(TownManager._hero_uid == hero_uid_before, "读档后英雄序号恢复（%d）" % TownManager._hero_uid)
	_check(TownManager._buried_count == buried_before, "读档后墓地计数恢复（%d）" % TownManager._buried_count)
	_check(TownManager._selected_party_ids == selected_before, "读档后已选队伍恢复")
	_check(int(TownManager.rng.state) != 0, "RNG 状态随档恢复（非 0）")
	print("[state] 全量城镇状态捕获/恢复测试完成")

# ------------------------------------------------------------------
# 2. 英雄属性细节往返
# ------------------------------------------------------------------

func _test_hero_state_roundtrip() -> void:
	TownManager.reset_game(22)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	var hero_id := String(hero["id"])
	# 打磨：等级/经验/压力/HP/怪癖/伤病/技能等级/武器护甲/饰品
	hero["exp"] = 800
	hero["level"] = 2
	hero["stress"] = 123
	hero["hp"] = 20
	hero["quirks"] = [
		{"id": "brave", "name": "无畏", "type": "positive"},
		{"id": "greedy", "name": "贪婪", "type": "negative"},
	]
	hero["injuries"] = ["rib_fracture"]
	hero["weapon_level"] = 3
	hero["armor_level"] = 2
	hero["skills"] = {"knight_smite": 2, "knight_guard": 1}
	hero["trinkets"] = ["t_ring", "t_cape"]
	SaveManager.save_slot(2)

	# 破坏
	for h in TownManager.roster:
		h["quirks"] = []
		h["injuries"] = []
		h["skills"] = {}
		h["trinkets"] = [null, null]
		h["stress"] = 0
		h["level"] = 1

	_check(SaveManager.load_slot(2), "读档槽位 2")
	var restored := TownManager._find_hero(hero_id)
	_check(not restored.is_empty(), "读档后英雄存在")
	if restored.is_empty():
		return
	_check(int(restored["exp"]) == 800, "英雄经验往返（%d）" % restored["exp"])
	_check(int(restored["level"]) == 2, "英雄等级往返（%d）" % restored["level"])
	_check(int(restored["stress"]) == 123, "英雄压力往返（%d）" % restored["stress"])
	_check(int(restored["hp"]) == 20, "英雄 HP 往返（%d）" % restored["hp"])
	_check(int(restored["weapon_level"]) == 3, "武器等级往返（%d）" % restored["weapon_level"])
	_check(int(restored["armor_level"]) == 2, "护甲等级往返（%d）" % restored["armor_level"])
	_check(int(restored["quirks"].size()) == 2, "怪癖往返（%d 条）" % restored["quirks"].size())
	_check(String(restored["quirks"][0]["id"]) == "brave", "怪癖内容往返（%s）" % restored["quirks"][0]["id"])
	_check(String(restored["injuries"][0]) == "rib_fracture", "伤病往返（%s）" % restored["injuries"][0])
	_check(int(restored["skills"].get("knight_smite", 0)) == 2, "技能等级往返（%s=2）" % restored["skills"].keys())
	_check(String(restored["trinkets"][0]) == "t_ring", "饰品槽1往返（%s）" % restored["trinkets"][0])
	# 恢复后属性计算仍可用（怪癖/装备/伤病加成生效）
	var stats := TownManager.get_hero_stats(restored)
	_check(int(stats["max_hp"]) > 0, "读档后英雄属性可重算（max_hp=%d）" % stats["max_hp"])
	print("[hero] 英雄属性/装备/压力/怪癖/伤病往返测试完成")

# ------------------------------------------------------------------
# 3. 手动 3 槽
# ------------------------------------------------------------------

func _test_manual_slots() -> void:
	for slot in range(1, SaveManager.MAX_SLOTS + 1):
		TownManager.reset_game(33)
		_check(SaveManager.save_slot(slot), "手动存档槽 %d" % slot)
	_check(SaveManager.list_saves() == [1, 2, 3], "list_saves 返回 3 个槽位（%s）" % str(SaveManager.list_saves()))
	_check(SaveManager.has_save(1) and SaveManager.has_save(3), "has_save(1/3) 为 true")
	var info := SaveManager.slot_info(1)
	_check(bool(info["exists"]) and info["saved_at"] != "", "slot_info 返回存档时间")
	_check(int(info["gold"]) >= 0, "slot_info 返回金币摘要")
	_check(SaveManager.delete_save(2), "删除槽位 2")
	_check(SaveManager.list_saves() == [1, 3], "删除后 list_saves 为 [1,3]")
	_check(SaveManager.save_game(9, {}) == false, "非法槽位 9 拒绝写入")
	_check(SaveManager.load_game(0).is_empty(), "非法槽位 0 读取为空")
	print("[slots] 手动 3 槽测试完成")

# ------------------------------------------------------------------
# 4. 完整性校验与降级
# ------------------------------------------------------------------

func _test_validate_and_degrade() -> void:
	# 正常数据校验通过
	TownManager.reset_game(44)
	_check(SaveManager.validate_save(SaveManager.capture_state()).get("ok", false), "正常存档校验通过")

	# 空数据 / 缺节
	_check(not SaveManager.validate_save({}).get("ok", false), "空字典校验失败")
	var no_town := SaveManager.capture_state()
	no_town.erase("town")
	_check(not SaveManager.validate_save(no_town).get("ok", false), "缺 town 校验失败")
	var no_run := SaveManager.capture_state()
	no_run.erase("run")
	_check(not SaveManager.validate_save(no_run).get("ok", false), "缺 run 校验失败")
	var bad_type := SaveManager.capture_state()
	bad_type["town"] = "not-a-dict"
	_check(not SaveManager.validate_save(bad_type).get("ok", false), "town 类型错误校验失败")

	# 损坏 JSON：写入槽 3
	var bad := FileAccess.open("user://saves/slot_3.json", FileAccess.WRITE)
	bad.store_string("{not-valid-json!!!")
	bad.close()
	_check(SaveManager.load_game(3).is_empty(), "损坏 JSON 读回空（降级）")
	_check(not SaveManager.load_slot(3), "损坏 JSON load_slot 返回 false")
	_check(SaveManager.has_save(3), "损坏文件仍存在（has_save 只查文件）")

	# 版本不符：写入槽 3
	var wrong_ver := FileAccess.open("user://saves/slot_3.json", FileAccess.WRITE)
	wrong_ver.store_string(JSON.stringify({"version": 999, "saved_at": "x", "data": {}}))
	wrong_ver.close()
	_check(SaveManager.load_game(3).is_empty(), "版本不符读回空（降级）")

	# 结构完整但字段缺失：写入槽 3
	var missing_field := FileAccess.open("user://saves/slot_3.json", FileAccess.WRITE)
	missing_field.store_string(JSON.stringify({"version": SaveManager.SAVE_VERSION, "saved_at": "x", "data": {"town": {"gold": 1}}}))
	missing_field.close()
	_check(not SaveManager.load_slot(3), "字段缺失 load_slot 返回 false（不崩溃）")

	# 恢复失败不破坏当前状态
	TownManager.reset_game(45)
	TownManager.add_gold(777)
	var gold_before := TownManager.gold
	_check(not SaveManager.restore_state({}), "restore_state 空数据返回 false")
	_check(TownManager.gold == gold_before, "恢复失败时当前状态保持不变")
	SaveManager.delete_save(3)
	print("[degrade] 完整性校验与降级测试完成")

# ------------------------------------------------------------------
# 5. 探索节点自动存档（每节点）
# ------------------------------------------------------------------

func _test_exploration_autosave_hook() -> void:
	TownManager.reset_game(55)
	TownManager.add_gold(100000)
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 100)
	TownManager.refresh_candidates()
	var ids: Array = []
	for i in 4:
		var hero := TownManager.recruit(0)
		if hero.is_empty():
			break
		ids.append(hero["id"])
	TownManager.select_party(ids)
	TownManager.prepare_run("short")

	SaveManager.delete_autosave()
	_check(not SaveManager.has_autosave(), "开始时无自动存档")

	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.EXPLORATION)
	await get_tree().process_frame
	var expl: Node = main.get("_current_scene")
	_check(expl != null and expl.name == "DungeonExplore", "进入探索场景")

	# 走到一个相邻房间 → 触发 _move_to 自动存档
	var dungeon: Dictionary = GameState.current_dungeon
	var rooms: Array = dungeon.get("rooms", [])
	if not rooms.is_empty() and not (rooms[0] as Dictionary).get("connections", []).is_empty():
		var target: int = (rooms[0] as Dictionary)["connections"][0]
		expl.call("_move_to", target)
		await get_tree().process_frame
		_check(SaveManager.has_autosave(), "移动节点后触发自动存档")
		if SaveManager.has_autosave():
			var payload: Dictionary = SaveManager._read_payload(SaveManager.AUTOSAVE_PATH)
			var run: Dictionary = payload.get("data", {}).get("run", {})
			_check(int(run.get("current_pos", -1)) == target, "自动存档记录当前位置（%d）" % int(run.get("current_pos", -1)))
			_check(bool(run.get("run_active", false)), "自动存档标记任务进行中")
			_check(not (run.get("current_dungeon", {}) as Dictionary).is_empty(), "自动存档包含地图数据")

	# 模拟退出 → 恢复自动存档（状态一致）
	GameState.torch = 0
	GameState.rooms_cleared = 99
	_check(SaveManager.load_autosave(), "读回自动存档")
	_check(GameState.rooms_cleared < 99, "自动存档恢复房间进度（%d）" % GameState.rooms_cleared)
	_check(GameState.torch > 0, "自动存档恢复火把（%d）" % GameState.torch)
	_check(GameState.current_dungeon.size() > 0, "自动存档恢复地图")

	# 清理
	GameState.end_run()
	main.queue_free()
	await get_tree().process_frame
	SaveManager.delete_autosave()
	print("[auto] 探索节点自动存档测试完成")

# ------------------------------------------------------------------
# 6. 战斗后自动存档
# ------------------------------------------------------------------

func _test_battle_autosave_hook() -> void:
	TownManager.reset_game(66)
	TownManager.refresh_candidates()
	var ids: Array = []
	for i in 4:
		var hero := TownManager.recruit(0)
		if hero.is_empty():
			break
		ids.append(hero["id"])
	TownManager.select_party(ids)
	TownManager.prepare_run("short")
	GameState.pending_battle = {
		"room_id": 2, "is_boss": false,
		"monsters": ["ruins_skel_soldier"], "torch_tier": "昏暗", "torch_value": 40,
	}
	SaveManager.delete_autosave()

	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.BATTLE)
	await get_tree().process_frame
	var battle: Node = main.get("_current_scene")
	_check(battle != null and battle.name == "Battle", "进入战斗场景")

	# 战斗结束（返回探索）后触发自动存档
	await _wait_until(func(): return battle != null and bool(battle.get("_battle_over")), 120)
	# 直接驱动返回按钮
	if battle != null and battle.has_method("_on_return_pressed"):
		battle.call("_on_return_pressed")
	await get_tree().process_frame
	_check(SaveManager.has_autosave(), "战斗后触发自动存档")
	if SaveManager.has_autosave():
		var payload: Dictionary = SaveManager._read_payload(SaveManager.AUTOSAVE_PATH)
		var run: Dictionary = payload.get("data", {}).get("run", {})
		_check(bool(run.get("run_active", false)), "战斗后自动存档保留任务进度")

	GameState.end_run()
	main.queue_free()
	await get_tree().process_frame
	SaveManager.delete_autosave()
	print("[battle] 战斗后自动存档测试完成")

func _wait_until(cond: Callable, max_frames: int) -> void:
	for i in max_frames:
		if cond.call():
			break
		await get_tree().process_frame

# ------------------------------------------------------------------
# 7. 主菜单继续读档
# ------------------------------------------------------------------

func _test_main_menu_continue() -> void:
	TownManager.reset_game(77)
	TownManager.add_gold(9999)
	var gold_saved := TownManager.gold
	SaveManager.save_slot(1)
	_check(SaveManager.has_save(1), "主菜单新游戏已建槽位 1")

	# 模拟退出再进入 → 继续读档
	TownManager.gold = 0
	TownManager.roster.clear()
	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.MAIN_MENU)
	await get_tree().process_frame
	var menu: Node = main.get("_current_scene")
	_check(menu != null and menu.name == "MainMenu", "主菜单场景实例化")
	if menu != null and menu.has_method("_on_continue_pressed"):
		menu.call("_on_continue_pressed")
		await get_tree().process_frame
		_check(TownManager.gold == gold_saved, "继续读档后金币恢复（%d==%d）" % [TownManager.gold, gold_saved])
		_check(main.get_current_state() == GameMain.GameState.TOWN, "继续读档后进入城镇")
	main.queue_free()
	await get_tree().process_frame
	SaveManager.delete_save(1)
	print("[menu] 主菜单继续读档测试完成")

# ------------------------------------------------------------------
# 8. 城镇手动存档 UI
# ------------------------------------------------------------------

func _test_town_save_ui() -> void:
	TownManager.reset_game(88)
	TownManager.add_gold(3333)
	var gold_saved := TownManager.gold
	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.TOWN)
	await get_tree().process_frame
	var town: Node = main.get("_current_scene")
	_check(town != null and town.name == "Town", "城镇场景实例化")
	if town != null:
		town.call("_rebuild_all")
		var btns: Array = town.get("save_slot_btns")
		_check(btns.size() == 3, "城镇存档栏 3 个槽位按钮")
		_check(String(btns[0].text).contains("空"), "槽位 1 初始显示为空")
		# 点槽位 1 → 保存 → 显示已保存
		btns[0].pressed.emit()
		await get_tree().process_frame
		_check(SaveManager.has_save(1), "点击槽位按钮后生成存档")
		_check(String(btns[0].text).contains("金%d" % gold_saved), "槽位按钮显示金币摘要（%d）" % gold_saved)
	main.queue_free()
	await get_tree().process_frame
	SaveManager.delete_save(1)
	print("[ui] 城镇手动存档 UI 测试完成")
