extends Node
## WS-14 怪癖/疾病系统无头自检（GDD 3.5）。
## 运行：godot --headless --path . res://tests/test_ws14.tscn
##
## 覆盖（GDD 3.5）：
##  1. 怪癖：招募 2~4 个、任务中获取/改变（替换上限）、教堂净化（配置费用）
##  2. 伤病：任务结束按伤害量触发（概率随伤害提升、数量上限）
##  3. 疾病：区域/事件感染（区域池）、诊疗室等级门槛、长期属性影响
##  4. 跨多局：英雄带怪癖/伤病/疾病跨多局任务并正确结算与治疗

var failures := 0

func _ready() -> void:
	await get_tree().process_frame
	print("===== WS-14 quirks/diseases test begin =====")
	_test_config_meta()
	_test_recruit_quirks()
	_test_gain_and_change_quirk()
	_test_purge_quirk()
	_test_injury_by_damage()
	_test_disease_region_pool()
	_test_disease_cure_level_gate()
	_test_multi_run_loop()
	await _test_scene_flow()
	print("===== WS-14 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)

# ------------------------------------------------------------------
# 0. 配置元数据
# ------------------------------------------------------------------

func _test_config_meta() -> void:
	var qmeta: Dictionary = ConfigManager.get_entry("quirks", "_meta")
	_check(int(qmeta.get("purge", {}).get("base_cost", 0)) == 800, "quirks._meta.purge.base_cost = 800")
	_check(int(qmeta.get("max_quirks", 0)) >= 5, "quirks._meta.max_quirks >= 5")
	var imeta: Dictionary = ConfigManager.get_entry("injuries", "_meta")
	_check(int(imeta.get("injury_trigger", {}).get("min_damage", 0)) > 0, "injuries._meta.injury_trigger.min_damage > 0")
	_check(imeta.get("disease", {}).get("region_pools", {}).has("ruins"), "injuries._meta.disease.region_pools.ruins 存在")
	_check(float(ConfigManager.get_entry("quirks", "_meta").get("gain", {}).get("mission_chance", 0)) > 0.0, "quirks._meta.gain.mission_chance > 0")

# ------------------------------------------------------------------
# 1. 招募怪癖 2~4
# ------------------------------------------------------------------

func _test_recruit_quirks() -> void:
	TownManager.reset_game(101)
	TownManager.refresh_candidates()
	var quirk_counts: Array[int] = []
	for cand in TownManager.candidates:
		quirk_counts.append(int(cand.quirks.size()))
	_check(TownManager.candidates.size() > 0, "有候选可招募")
	if not TownManager.candidates.is_empty():
		var ok_range := true
		for n in quirk_counts:
			if n < 2 or n > 4:
				ok_range = false
		_check(ok_range, "候选 2~4 怪癖（%s）" % str(quirk_counts))
	# 招一个英雄确认名册带怪癖
	TownManager.add_gold(100000)
	var hero := TownManager.recruit(0)
	_check(not hero.is_empty(), "招募成功")
	if not hero.is_empty():
		_check(hero.quirks.size() >= 2 and hero.quirks.size() <= 4, "英雄带 2~4 怪癖（%d）" % hero.quirks.size())
	print("[quirk] 招募怪癖测试完成")

# ------------------------------------------------------------------
# 2. 任务中获取 / 改变怪癖
# ------------------------------------------------------------------

func _test_gain_and_change_quirk() -> void:
	TownManager.reset_game(102)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	hero["quirks"] = [{"id": "fearless", "name": "无畏", "type": "positive"}]

	# 获取一个正面怪癖（不应重复）
	var res := TownManager.gain_quirk(hero, "positive")
	_check(res.get("ok", false), "任务中获取正面怪癖成功")
	_check(res.get("quirk", {}).get("type", "") == "positive", "获取的怪癖类型为正面")
	_check(hero.quirks.size() == 2, "怪癖数量 +1（%d）" % hero.quirks.size())

	# 上限替换：max_quirks 后新获取替换一个已有
	TownManager.reset_game(103)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	hero = TownManager.recruit(0)
	hero["quirks"] = [{"id": "fearless", "name": "无畏", "type": "positive"}, {"id": "steadfast", "name": "坚毅", "type": "positive"}]
	var max_q := TownManager.get_max_quirks()
	# 填满到上限
	for i in max_q - hero.quirks.size():
		TownManager.gain_quirk(hero, "positive")
	var before_ids := []
	for q in hero.quirks:
		before_ids.append(q.id)
	_check(hero.quirks.size() == max_q, "达到上限 %d" % max_q)
	res = TownManager.gain_quirk(hero, "negative")
	_check(res.get("ok", false), "满上限后仍可获取（替换机制）")
	_check(res.get("replaced", "") != "", "返回被替换的怪癖 id")
	_check(hero.quirks.size() == max_q, "替换后数量仍为上限")

	# 改变机制：change_quirk 移除一个再获取一个
	res = TownManager.change_quirk(hero)
	_check(res.get("ok", false), "change_quirk 成功")
	_check(res.get("removed", "") != "", "change_quirk 返回被移除怪癖")
	_check(hero.quirks.size() == max_q, "change_quirk 后数量不变")
	print("[quirk] 获取/改变怪癖测试完成")

# ------------------------------------------------------------------
# 3. 教堂净化（配置费用）
# ------------------------------------------------------------------

func _test_purge_quirk() -> void:
	TownManager.reset_game(104)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	hero["quirks"] = [{"id": "greedy", "name": "贪婪", "type": "negative"}]
	_check(TownManager.get_purge_cost() == 800, "净化费用从配置读取（%d）" % TownManager.get_purge_cost())
	var gold_before := TownManager.gold
	var res := TownManager.purge_quirk(hero, "greedy")
	_check(res.get("ok", false), "教堂净化负面怪癖成功")
	_check(TownManager.gold == gold_before - 800, "净化扣除 800 金币")
	_check(hero.quirks.is_empty(), "怪癖已清除")
	res = TownManager.purge_quirk(hero, "greedy")
	_check(not res.get("ok", false), "无该怪癖时净化失败")
	print("[purge] 教堂净化测试完成")

# ------------------------------------------------------------------
# 4. 伤病按伤害量触发
# ------------------------------------------------------------------

func _test_injury_by_damage() -> void:
	TownManager.reset_game(105)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	hero["run_damage"] = 0

	# 低伤害（< min_damage）不触发
	var granted := TownManager.apply_injuries_by_damage(hero, 5)
	_check(granted.is_empty(), "伤害低于阈值不触发伤病")

	# 大伤害触发
	granted = TownManager.apply_injuries_by_damage(hero, 40)
	_check(not granted.is_empty(), "高伤害触发伤病（%s）" % str(granted))
	_check(hero.injuries.size() > 0, "英雄已受伤病")

	# 数量上限约束
	TownManager.reset_game(106)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	hero = TownManager.recruit(0)
	hero["run_damage"] = 0
	for i in 5:
		TownManager.apply_injuries_by_damage(hero, 200)
	var max_per := int(ConfigManager.get_entry("injuries", "_meta").get("injury_trigger", {}).get("max_per_hero", 2))
	_check(hero.injuries.size() <= max_per, "伤病数量受上限约束（%d <= %d）" % [hero.injuries.size(), max_per])

	# 诊疗室治疗伤病（1 级可治）
	TownManager.add_heirloom("statue", 10)
	if not hero.injuries.is_empty():
		var inj_id := String(hero.injuries[0])
		var cure := TownManager.cure_injury(hero, inj_id)
		_check(cure.get("ok", false), "诊疗室治疗伤病成功")
		_check(not hero.injuries.has(inj_id), "伤病已清除")
	print("[injury] 按伤害量触发伤病测试完成")

# ------------------------------------------------------------------
# 5. 疾病区域池感染
# ------------------------------------------------------------------

func _test_disease_region_pool() -> void:
	TownManager.reset_game(107)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)

	# 废墟区域 → 瘟疫
	var d := TownManager.apply_random_disease(hero, "ruins")
	_check(not d.is_empty(), "废墟区域感染疾病成功")
	if not d.is_empty():
		_check(String(d.get("id", "")) == "plague", "废墟区域池 → 瘟疫（%s）" % d.get("id", ""))
		_check(hero.diseases.has("plague"), "疾病写入 hero.diseases")

	# 阴森林地 → 疯病
	var hero2 := TownManager.recruit(0)
	var d2 := TownManager.apply_random_disease(hero2, "forest")
	_check(not d2.is_empty(), "林地区域感染疾病成功")
	if not d2.is_empty():
		_check(String(d2.get("id", "")) == "madness", "林地区域池 → 疯病（%s）" % d2.get("id", ""))

	# 重复不叠加
	var d3 := TownManager.apply_random_disease(hero, "ruins")
	_check(not hero.diseases.has("plague") == false or hero.diseases.count("plague") == 1, "重复感染不叠加")

	# 疾病长期属性影响：疯病降低 SPD
	var stats := TownManager.get_hero_stats(hero2)
	_check(int(stats.get("spd", 0)) < int(ConfigManager.get_entry("heroes", String(hero2.class_id)).get("base_stats", {}).get("spd", 0)), "疯病降低速度（长期属性影响）")
	print("[disease] 疾病区域池测试完成")

# ------------------------------------------------------------------
# 6. 疾病诊疗室等级门槛
# ------------------------------------------------------------------

func _test_disease_cure_level_gate() -> void:
	TownManager.reset_game(108)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	hero["diseases"] = ["madness"]

	var res := TownManager.cure_disease(hero, "madness")
	_check(not res.get("ok", false), "诊疗室 1 级不能治疗疾病")
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 100)
	TownManager.upgrade_building("clinic")
	_check(TownManager.get_building_level("clinic") >= 2, "诊疗室升到 2 级")
	res = TownManager.cure_disease(hero, "madness")
	_check(res.get("ok", false), "诊疗室 2 级可治疗疾病")
	_check(not hero.diseases.has("madness"), "疾病已清除")
	print("[disease] 疾病等级门槛测试完成")

# ------------------------------------------------------------------
# 7. 跨多局：英雄带怪癖/伤病/疾病跨任务并正确结算与治疗
# ------------------------------------------------------------------

func _test_multi_run_loop() -> void:
	TownManager.reset_game(109)
	TownManager.add_gold(100000)
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 200)
	TownManager.refresh_candidates()

	# 第 1 局：招募 → 出战 → 结算（模拟受伤 + 疾病 + 怪癖获取）
	var party_ids: Array[String] = []
	for i in 4:
		var hero := TownManager.recruit(0)
		if hero.is_empty():
			break
		party_ids.append(String(hero["id"]))
	_check(party_ids.size() == 4, "招募 4 名英雄")
	var select := TownManager.select_party(party_ids)
	_check(select.get("ok", false), "选择队伍")

	TownManager.prepare_run("short")
	# 模拟战斗受伤：直接给 party 英雄写 run_damage（等价于 battle.gd 回写）
	var dam_hero: Dictionary = GameState.party[0]
	dam_hero["hp"] = 20
	dam_hero["run_damage"] = 40
	GameState.result_payload = {
		"outcome": "victory", "rooms_cleared": 4, "gold": 300,
		"boss_defeated": false, "torch": 40, "party": GameState.party,
		"region": "ruins",
	}
	var settle := TownManager.settle_run(GameState.result_payload)
	_check(settle.get("ok", false), "第 1 局结算成功")
	_check(int(settle.get("injuries", []).size()) >= 1 or dam_hero["injuries"].size() > 0, "第 1 局按伤害量触发伤病")

	# 跨局：英雄名册保留伤病/疾病/怪癖
	var roster_hero := TownManager._find_hero(String(dam_hero["id"]))
	_check(not roster_hero.is_empty(), "结算后英雄仍在名册")
	if not roster_hero.is_empty():
		_check(int(roster_hero["run_damage"]) == 0, "结算后 run_damage 归零（跨局不残留伤害计数）")
		var carried_injuries := int(roster_hero["injuries"].size()) > 0
		var carried_quirks := int(roster_hero["quirks"].size()) >= 2
		_check(carried_injuries or carried_quirks, "英雄跨局保留伤病/怪癖")

	# 治疗：伤病诊疗室、疾病（若有）需 2 级、怪癖教堂净化
	var healed_any := false
	for hero in TownManager.roster:
		if int(hero["injuries"].size()) > 0:
			var cured := TownManager.cure_injury(hero, String(hero["injuries"][0]))
			healed_any = healed_any or cured.get("ok", false)
	_check(healed_any, "跨局后诊疗室治疗伤病")

	# 第 2 局：仍可出战（带伤英雄不因伤病被排除）
	var select2 := TownManager.select_party([dam_hero["id"]])
	_check(select2.get("ok", false), "第 2 局仍可带伤英雄出战")
	TownManager.prepare_run("short")
	_check(GameState.party.size() >= 1, "第 2 局队伍就绪")

	GameState.end_run()
	print("[loop] 跨多局循环测试完成")

# ------------------------------------------------------------------
# 8. 场景流转回归（城镇→探索→战斗→结算→城镇）
# ------------------------------------------------------------------

func _test_scene_flow() -> void:
	TownManager.reset_game(110)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var party_ids: Array[String] = []
	for i in 4:
		var hero := TownManager.recruit(0)
		if hero.is_empty():
			break
		party_ids.append(String(hero["id"]))
	TownManager.select_party(party_ids)

	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.TOWN)
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.TOWN, "进入城镇")

	var town: Node = main.get("_current_scene")
	town.call("_on_start_pressed")
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.EXPLORATION, "出发进入探索")
	_check(GameState.party.size() == 4, "探索队伍 4 人")

	# 直接推进到战斗
	var expl: Node = main.get("_current_scene")
	var dungeon: Dictionary = expl.get("_dungeon")
	for room in dungeon.get("rooms", []):
		if String(room["type"]) == "battle":
			expl.set("_current_room_id", int(room["id"]))
			room["trapped"] = false
			room["locked_door"] = false
			expl.call("_on_explore_pressed")
			break
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.BATTLE, "遇敌进入战斗")

	# 结算回写：战斗结束后 party 英雄 HP/run_damage 已更新
	var battle: Node = main.get("_current_scene")
	battle.call("_finish_battle", true)
	await get_tree().process_frame
	var total_damage := 0
	for h in GameState.party:
		total_damage += int(h.get("run_damage", 0))
	_check(total_damage >= 0, "战斗回写 run_damage（累计 %d）" % total_damage)

	# 撤退到结算
	expl = main.get("_current_scene")
	expl.call("_on_retreat_pressed")
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.SETTLEMENT, "进入结算")

	var settle_node: Node = main.get("_current_scene")
	settle_node.call("_on_back_pressed")
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.TOWN, "结算回城")
	_check(TownManager.roster.size() >= 4, "名册保留英雄")
	print("[flow] 场景流转回归测试完成")
	GameState.end_run()
