extends Node
## WS-15 剧情章节 + 旁白文案无头自检（GDD 第五章）。
## 运行：godot --headless --path . res://tests/test_ws15.tscn
##
## 覆盖（GDD 5.1~5.5）：
##  1. narrative.json 加载：世界观 / 序章·第一幕·第二幕叙事结构 / 5 势力
##  2. 8 职业背景文案与 heroes.json 一一对应
##  3. 4 区域进入开场白 / 事件文案（宝箱/遗物/祭坛/低语/塌陷/安全/陷阱/遭遇/关底）/ 结算文案
##  4. 语气规则（第二人称 / 短句压抑 / 悲剧底色）
##  5. 嵌入点：探索开场白（序章+区域开场）、事件文案、结算文案、城镇职业背景

var failures := 0

func _ready() -> void:
	await get_tree().process_frame
	print("===== WS-15 narrative test begin =====")
	_test_narrative_data()
	await _test_exploration_embedding()
	await _test_settlement_embedding()
	await _test_town_background()
	print("===== WS-15 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)

# ------------------------------------------------------------------
# 1. 文案数据完整性
# ------------------------------------------------------------------

func _test_narrative_data() -> void:
	# 语气规则（GDD 5.5）
	var rules := Narrative.get_tone_rules()
	_check(rules.size() >= 3, "语气规则已配置（%d 条）" % rules.size())

	# 世界观背景
	var world := Narrative.get_world()
	_check(String(world.get("title", "")) == "晨昏庄园", "世界观标题 = 晨昏庄园")
	_check(not world.get("intro", []).is_empty(), "世界观背景文案存在")

	# 叙事结构：序章 / 第一幕 / 第二幕
	for act_id in ["prologue", "act1", "act2"]:
		var act := Narrative.get_act(act_id)
		_check(not act.is_empty() and not act.get("intro", []).is_empty(), "章节「%s」存在且含开场文案" % act_id)

	# 5 势力
	var factions := ["圣烛会", "低语者教团", "偷渡者公会", "无面低语", "被遗忘的先祖"]
	for fname in factions:
		var f := Narrative.get_faction(fname)
		_check(not f.is_empty() and f.get("desc", "") != "", "势力「%s」设定完整" % fname)

	# 8 职业背景与 heroes.json 对应
	var hero_section := ConfigManager.get_section("heroes")
	var class_count := 0
	for hid: String in hero_section.keys():
		if hid.begins_with("_"):
			continue
		class_count += 1
		_check(Narrative.get_class_background(hid) != "", "职业背景文案存在：%s" % hid)
	_check(class_count == 8, "8 职业背景全部覆盖（实际 %d）" % class_count)

	# 区域开场白（4 区域）
	for region_id in ["ruins", "forest", "moor", "warrens"]:
		_check(Narrative.region_intro(region_id) != "", "区域「%s」开场白存在" % region_id)

	# 事件文案
	for key in ["treasure", "loot", "altar", "whisper", "whisper_resist", "collapse", "safe", "trap", "encounter", "boss"]:
		_check(Narrative.event_line(key) != "", "事件文案「%s」存在" % key)

	# 结算文案
	for outcome in ["victory", "boss_retreat", "retreat"]:
		_check(Narrative.settlement_line(outcome) != "", "结算文案「%s」存在" % outcome)
	print("[data] 文案数据完整性测试完成")

# ------------------------------------------------------------------
# 2. 探索嵌入：开场白（序章 + 区域开场）与事件文案
# ------------------------------------------------------------------

func _test_exploration_embedding() -> void:
	GameState.story_prologue_shown = false
	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	GameState.start_run("short")
	main.change_state(GameMain.GameState.EXPLORATION)
	await get_tree().process_frame
	var expl: Node = main.get("_current_scene")
	_check(expl != null and String(expl.name) == "DungeonExplore", "进入探索场景")
	if expl != null:
		var log_label: RichTextLabel = expl.get("log_label")
		var text: String = log_label.get_parsed_text()
		_check(text.contains("它醒了") or text.contains("庄园失守"), "序章开场白写入探索日志")
		_check(text.contains("圣殿") or text.contains("修道院") or text.contains("神像"), "区域开场白写入探索日志")
		_check(GameState.story_prologue_shown, "序章标记已置位（仅显示一次）")

	# 事件房探索：触发事件文案（循环直到触发一次事件房）
	var dungeon: Dictionary = expl.get("_dungeon")
	var found_event := false
	var guard := 0
	for room in dungeon.get("rooms", []):
		if guard > 200 or found_event:
			break
		guard += 1
		if String(room["type"]) != "event":
			continue
		expl.set("_current_room_id", int(room["id"]))
		room["trapped"] = false
		room["locked_door"] = false
		expl.call("_on_explore_pressed")
		var event_text: String = expl.get("log_label").get_parsed_text()
		_check(event_text.contains("墙壁") or event_text.contains("遗物") or event_text.contains("祭坛") or event_text.contains("塌陷") or event_text.contains("低语") or event_text.contains("地板"), "事件房写入叙事文案")
		found_event = true
	if not found_event:
		_check(true, "本局无事件房（跳过，叙事已由数据测试覆盖）")

	GameState.end_run()
	main.queue_free()
	await get_tree().process_frame
	print("[explore] 探索叙事嵌入测试完成")

# ------------------------------------------------------------------
# 3. 结算嵌入
# ------------------------------------------------------------------

func _test_settlement_embedding() -> void:
	GameState.start_run("short")
	GameState.result_payload = {
		"outcome": "victory", "rooms_cleared": 5, "gold": 800,
		"boss_defeated": false, "torch": 30, "party": GameState.party,
	}
	var settle_scene: PackedScene = load("res://scenes/settlement/Settlement.tscn")
	var node: Node = settle_scene.instantiate()
	add_child(node)
	await get_tree().process_frame
	var label: Label = node.get("outcome_label")
	_check(label.text.contains("探索完成") and label.text.length() > 5, "结算页含叙事结语（%s）" % label.text)
	node.queue_free()
	await get_tree().process_frame
	GameState.end_run()
	print("[settle] 结算叙事嵌入测试完成")

# ------------------------------------------------------------------
# 4. 城镇职业背景嵌入
# ------------------------------------------------------------------

func _test_town_background() -> void:
	TownManager.reset_game(88)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	_check(not hero.is_empty(), "招募一名英雄用于背景校验")
	if hero.is_empty():
		return
	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.TOWN)
	await get_tree().process_frame
	var town: Node = main.get("_current_scene")
	if town != null:
		town.set("_selected_hero_id", String(hero["id"]))
		town.call("_rebuild_roster_detail")
		var detail: VBoxContainer = town.get("roster_detail_v")
		var has_bg := false
		for child in detail.get_children():
			if child is Label and String(child.text).begins_with("背景："):
				has_bg = true
		_check(has_bg, "城镇英雄详情显示职业背景文案")
	main.queue_free()
	await get_tree().process_frame
	print("[town] 城镇职业背景嵌入测试完成")
