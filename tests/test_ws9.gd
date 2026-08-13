extends Node
## WS-9 城镇经营系统无头自检（GDD 第三章）。
## 运行：godot --headless --path . res://tests/test_ws9.tscn
##
## 覆盖（GDD 3.1~3.7）：
##  1. 资源管理：金币 / 传承物（4 种）/ 补给品商店 / 饰品
##  2. 8 栋建筑各 3 级：升级消耗传承物，等级门控功能上限
##  3. 英雄招募：每日候选 4~8 名、稀有度与费用、2~4 怪癖
##  4. 养成：经验升级、技能装备与训练场升级、武器/护甲 5 级、饰品 2 槽
##  5. 伤病/疾病/怪癖处理与压力处理（教堂/酒馆/派遣休息）
##  6. 完整闭环：招募→培养→出发→返回→结算→治疗/减压

var failures := 0

func _ready() -> void:
	await get_tree().process_frame
	print("===== WS-9 town management test begin =====")
	_test_resources_and_shop()
	_test_buildings()
	_test_recruitment()
	_test_progression()
	_test_treatment()
	_test_full_loop()
	await _test_town_scene_flow()
	print("===== WS-9 headless test end: %d failures =====" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(cond: bool, label: String) -> void:
	if cond:
		print("[PASS] " + label)
	else:
		failures += 1
		print("[FAIL] " + label)

# ------------------------------------------------------------------
# 1. 资源管理 + 补给商店
# ------------------------------------------------------------------

func _test_resources_and_shop() -> void:
	TownManager.reset_game(11)
	_check(TownManager.gold >= 0, "新档有起始金币（%d）" % TownManager.gold)
	_check(TownManager.heirlooms.size() == 4, "传承物 4 种（statue/scroll/badge/tablet）")
	_check(not TownManager.spend_gold(9999999), "金币不足时消费失败")
	TownManager.add_gold(500)
	_check(TownManager.spend_gold(300), "金币充足时消费成功")
	TownManager.add_heirloom("statue", 5)
	_check(TownManager.spend_heirlooms({"statue": 99, "scroll": 2}) == false, "传承物不足无法消费")
	TownManager.add_heirloom("scroll", 2)
	_check(TownManager.spend_heirlooms({"statue": 3, "scroll": 2}), "传承物足够时消费成功")

	var shop := TownManager.shop_items()
	_check(shop.size() == 9, "补给品商店 9 种物品（实际 %d）" % shop.size())
	var res := TownManager.buy_supply("torch", 2)
	_check(res.get("ok", false), "购买火把成功")
	_check(int(TownManager.supplies.get("torch", 0)) == 2, "购买后补给库存 +2")
	var gold_before := TownManager.gold
	res = TownManager.buy_supply("charm", 999)
	_check(not res.get("ok", false), "金币不足时购买失败")
	_check(TownManager.gold == gold_before, "购买失败不扣金币")

	TownManager.add_trinket("t_ring")
	_check(TownManager.trinkets.has("t_ring"), "饰品入库存")
	print("[res] 资源管理 + 补给商店测试完成")

# ------------------------------------------------------------------
# 2. 建筑三级升级
# ------------------------------------------------------------------

func _test_buildings() -> void:
	var ids := TownManager.BUILDING_IDS
	_check(ids.size() == 8, "8 栋建筑（实际 %d）" % ids.size())
	for bid in ids:
		_check(TownManager.get_building_level(bid) == 1, "%s 初始 1 级" % bid)

	# 发放足够传承物（8 建筑 × 2 次升级总量约 {88,136,208,120}）
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 500)

	for bid in ids:
		var max_ok := true
		for step in 2:
			var res := TownManager.upgrade_building(bid)
			if not res.get("ok", false):
				max_ok = false
				break
		_check(max_ok, "%s 可升到 3 级（实际 %d）" % [bid, TownManager.get_building_level(bid)])
		_check(TownManager.get_building_level(bid) == 3, "%s 升到 3 级后生效" % bid)
		_check(not TownManager.can_upgrade(bid), "%s 3 级为最高级" % bid)

	_check(TownManager.get_building_level("training_ground") == 3, "训练场 3 级")
	_check(TownManager.get_max_skill_level() == 5, "训练场 3 级 → 技能可升 5 级")
	_check(TownManager.get_max_weapon_level() == 5, "铁匠铺 3 级 → 武器可升 5 级")
	_check(TownManager.get_max_armor_level() == 5, "护甲坊 3 级 → 护甲可升 5 级")
	_check(is_equal_approx(TownManager.get_clinic_fee_mult(), 0.5), "诊疗室 3 级 → 治疗费用 -50%")
	_check(TownManager.get_recruit_count() == 8, "雇佣厅 3 级 → 候选 8 人/天")
	_check(TownManager.get_church_actions().size() >= 2, "教堂 3 级 → 解锁安魂曲")
	_check(TownManager.get_tavern_actions().size() >= 2, "酒馆 3 级 → 解锁赌局")
	_check(TownManager.get_graveyard_bonus_per_burial() > 0.0, "墓地 3 级 → 每个安葬 +3% 属性")

	# 升级后扣除传承物应生效（清零后无法升级）
	TownManager.reset_game(11)
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, -1000)
	for h in TownManager.HEIRLOOM_TYPES:
		_check(int(TownManager.heirlooms[h]) <= 0, "%s 清零后为 %d" % [h, TownManager.heirlooms[h]])
	_check(not TownManager.can_upgrade("church"), "无传承物时无法升级")
	print("[build] 8 建筑三级升级测试完成")

# ------------------------------------------------------------------
# 3. 英雄招募
# ------------------------------------------------------------------

func _test_recruitment() -> void:
	TownManager.reset_game(22)
	TownManager.refresh_candidates()
	var count := TownManager.candidates.size()
	_check(count >= 4 and count <= 8, "每日候选 4~8 名（实际 %d）" % count)
	for cand in TownManager.candidates:
		_check(ConfigManager.has_entry("heroes", cand.class_id), "候选职业合法：%s" % cand.class_id)
		_check(cand.rarity in ["white", "blue", "purple", "gold"], "稀有度合法：%s" % cand.rarity)
		_check(int(cand.cost) > 0, "候选有招募费用：%d" % cand.cost)
		_check(int(cand.quirks.size()) >= 2 and int(cand.quirks.size()) <= 4, "候选 2~4 怪癖（实际 %d）" % cand.quirks.size())

	# 选一个便宜的招募
	var cheap := -1
	for i in TownManager.candidates.size():
		if int(TownManager.candidates[i].cost) <= TownManager.gold:
			cheap = i
			break
	_check(cheap >= 0, "存在可负担的候选")
	if cheap >= 0:
		var hero := TownManager.recruit(cheap)
		_check(not hero.is_empty() and hero.has("id"), "招募成功生成英雄")
		_check(TownManager.roster.size() == 1, "英雄入名册")
		_check(hero.rarity in ["white", "blue", "purple", "gold"], "招募英雄稀有度保留")
		_check(int(hero.quirks.size()) >= 2 and int(hero.quirks.size()) <= 4, "招募英雄带 2~4 怪癖（实际 %d）" % hero.quirks.size())
		_check(int(hero.weapon_level) == 1 and int(hero.armor_level) == 1, "新英雄武器/护甲 1 级")

	# 刷新次数（雇佣厅 1 级 = 0 次）
	_check(TownManager.refresh_left >= 0, "刷新次数非负：%d" % TownManager.refresh_left)
	print("[recruit] 英雄招募测试完成")

# ------------------------------------------------------------------
# 4. 养成
# ------------------------------------------------------------------

func _test_progression() -> void:
	TownManager.reset_game(33)
	TownManager.add_gold(100000)
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 100)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)

	# 经验升级（1→2：1500 EXP，之后 ×1.6）
	var lvl_before := int(hero.level)
	var r := TownManager.add_exp(hero, TownManager.get_exp_needed(hero.level))
	_check(r.get("leveled", false), "经验满后升级")
	_check(int(hero.level) == lvl_before + 1, "等级 +1（%d）" % hero.level)
	_check(TownManager.get_exp_needed(hero.level) > TownManager.get_exp_needed(hero.level - 1), "升级所需经验递增")

	# 训练场门控技能等级
	_check(TownManager.get_max_skill_level() == 2, "训练场 1 级 → 技能最多 2 级")
	var up := TownManager.upgrade_skill(hero, hero.skills.keys()[0])
	_check(up.get("ok", false), "技能升到 2 级成功")
	_check(int(hero.skills.get(hero.skills.keys()[0], 0)) == 2, "技能等级记录为 2")

	# 武器/护甲升级（铁匠铺/护甲坊 1 级 → 上限 2）
	_check(TownManager.get_max_weapon_level() == 2, "铁匠铺 1 级 → 武器最多 2 级")
	up = TownManager.upgrade_weapon(hero)
	_check(up.get("ok", false), "武器升到 2 级成功")
	_check(int(hero.weapon_level) == 2, "武器等级 = 2")
	up = TownManager.upgrade_armor(hero)
	_check(up.get("ok", false), "护甲升到 2 级成功")
	_check(int(hero.armor_level) == 2, "护甲等级 = 2")

	# 饰品 2 槽
	var t1: String = TownManager.trinkets[0] if TownManager.trinkets.size() > 0 else "t_ring"
	TownManager.add_trinket(t1)
	_check(TownManager.equip_trinket(hero, 0, t1).get("ok", false), "饰品装入槽 1")
	_check(TownManager.equip_trinket(hero, 1, t1).get("ok", false), "饰品装入槽 2（同款可再装）")
	_check(not TownManager.equip_trinket(hero, 2, t1).get("ok", false), "槽位只有 2 个，越界失败")
	_check(TownManager.unequip_trinket(hero, 0).get("ok", false), "取下饰品成功")

	# 技能装备：最多 4 个
	var hero_cfg: Dictionary = ConfigManager.get_entry("heroes", hero.class_id)
	_check(int(hero_cfg.get("skill_ids", []).size()) >= 4, "职业技能池 >= 4")
	_check(TownManager.equip_skill(hero, String(hero_cfg["skill_ids"][0])).get("ok", false), "装备技能成功")
	_check(int(hero.skills.size()) <= 4, "已装备技能 <= 4（实际 %d）" % hero.skills.size())
	print("[train] 养成测试完成")

# ------------------------------------------------------------------
# 5. 伤病/疾病/怪癖 + 压力处理
# ------------------------------------------------------------------

func _test_treatment() -> void:
	TownManager.reset_game(44)
	TownManager.add_gold(100000)
	TownManager.refresh_candidates()
	var hero := TownManager.recruit(0)
	hero["stress"] = 80
	hero["hp"] = 10

	# 派遣休息（免费，-10 压力，下任务不可参战）
	var r := TownManager.dispatch_rest(hero)
	_check(r.get("ok", false), "派遣休息成功")
	_check(int(hero.stress) == 70, "派遣休息 -10 压力（%d）" % hero.stress)
	_check(hero.get("resting", false), "休息英雄标记为不可参战")

	# 教堂减压（1 级只有烛光冥想 -15）
	var church := TownManager.get_church_actions()
	_check(church.size() == 1, "教堂 1 级 → 仅烛光冥想（实际 %d）" % church.size())
	var before := int(hero.stress)
	var act := TownManager.church_relieve(hero, "meditate")
	_check(act.get("ok", false), "烛光冥想成功")
	_check(int(hero.stress) == before - 15, "烛光冥想 -15 压力（%d→%d）" % [before, hero.stress])

	# 酒馆痛饮（-20，小概率新怪癖）
	before = int(hero.stress)
	act = TownManager.tavern_activity(hero, "drink")
	_check(act.get("ok", false), "酒馆痛饮成功")
	_check(int(hero.stress) == before - 20, "痛饮 -20 压力（%d→%d）" % [before, hero.stress])

	# 诊所治疗伤病（诊疗室 1 级可治伤病）
	TownManager.add_heirloom("statue", 5)
	var inj := TownManager.apply_random_injury(hero)
	if not inj.is_empty():
		_check(int(hero.injuries.size()) >= 1, "英雄已受 1 处伤病")
		var cure := TownManager.cure_injury(hero, String(hero.injuries[0]))
		_check(cure.get("ok", false), "诊疗室治愈伤病成功")
		_check(int(hero.injuries.size()) == 0, "伤病已清除")

	# 疾病需要诊疗室 2 级
	hero["diseases"] = ["plague"]
	var disease_cure := TownManager.cure_disease(hero, "plague")
	_check(not disease_cure.get("ok", false), "诊疗室 1 级无法治疗疾病")
	TownManager.add_heirloom("scroll", 100)
	TownManager.add_heirloom("badge", 100)
	TownManager.add_heirloom("tablet", 100)
	TownManager.upgrade_building("clinic")
	_check(TownManager.get_building_level("clinic") >= 2, "诊疗室升到 2 级")
	disease_cure = TownManager.cure_disease(hero, "plague")
	_check(disease_cure.get("ok", false), "诊疗室 2 级可治疗疾病")

	# 怪癖净化（教堂）
	var quirk_hero := TownManager.recruit(0)
	quirk_hero["quirks"] = [{"id": "greedy", "type": "negative"}]
	var purge := TownManager.purge_quirk(quirk_hero, "greedy")
	_check(purge.get("ok", false), "教堂净化负面怪癖成功")
	_check(int(quirk_hero.quirks.size()) == 0, "怪癖已清除")
	print("[treat] 治疗/减压测试完成")

# ------------------------------------------------------------------
# 6. 完整闭环
# ------------------------------------------------------------------

func _test_full_loop() -> void:
	TownManager.reset_game(55)
	TownManager.add_gold(100000)
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 100)
	TownManager.refresh_candidates()

	# 招募 4 人组成队伍（每次取下标 0，避免数组收缩越界）
	var party_ids: Array[String] = []
	for i in 4:
		var hero := TownManager.recruit(0)
		if hero.is_empty():
			break
		party_ids.append(hero["id"])
	_check(party_ids.size() == 4, "招募 4 名英雄（实际 %d）" % party_ids.size())
	var select := TownManager.select_party(party_ids)
	_check(select.get("ok", false), "选择队伍成功")

	# 出发：构建 GameState.party（可继续走 WS-5 探索闭环）
	var run := TownManager.prepare_run("medium")
	_check(run.get("ok", false), "准备出发成功")
	_check(GameState.party.size() == 4, "GameState.party = 4 名英雄")

	# 模拟返回（沿用结算载荷结构）
	GameState.result_payload = {
		"outcome": "victory", "rooms_cleared": 5, "gold": 800,
		"boss_defeated": false, "torch": 30, "party": GameState.party,
	}
	var settle := TownManager.settle_run(GameState.result_payload)
	_check(settle.get("ok", false), "结算成功")
	_check(int(settle.get("exp_awarded", 0)) > 0, "结算发放经验（%d）" % settle.get("exp_awarded", 0))
	_check(settle.get("gold_awarded", 0) >= 800, "结算发放金币 >= 任务金币")

	# 结算后英雄可被治疗/减压（回城闭环）
	for hero in GameState.party:
		if int(hero.stress) > 0:
			var rel := TownManager.church_relieve(hero, "meditate")
			_check(rel.get("ok", false), "回城后教堂减压成功")
			break
	# 治疗伤病
	for hero in GameState.party:
		if int(hero.injuries.size()) > 0:
			var cure := TownManager.cure_injury(hero, String(hero.injuries[0]))
			_check(cure.get("ok", false), "回城后诊所治疗成功")
			break
	_check(not TownManager.roster.is_empty(), "名册保留英雄（跨局养成）")
	print("[loop] 完整闭环测试完成")

	# 结尾：清理（避免影响同进程其他测试）
	GameState.end_run()


# ------------------------------------------------------------------
# 7. 城镇场景 UI 集成（状态机 + 招募按钮 + 出发 + 结算回城）
# ------------------------------------------------------------------

func _test_town_scene_flow() -> void:
	TownManager.reset_game(66)
	TownManager.add_gold(100000)
	for h in TownManager.HEIRLOOM_TYPES:
		TownManager.add_heirloom(h, 500)
	TownManager.refresh_candidates()

	var main: GameMain = load("res://scenes/main/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.change_state(GameMain.GameState.TOWN)
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.TOWN, "进入城镇场景")

	# 城镇场景调用招募按钮（直接驱动 UI 方法），检查英雄入名册
	var town: Node = main.get("_current_scene")
	_check(town != null and town.name == "Town", "城镇场景实例化")
	if town != null:
		town.call("_rebuild_all")
		var before := TownManager.roster.size()
		# 通过 UI 招募 4 名英雄（每次取当前候选第 0 个）
		for i in 4:
			if TownManager.candidates.is_empty():
				break
			town.call("_on_recruit", TownManager.candidates[0])
			town.call("_rebuild_all")
		_check(TownManager.roster.size() == before + 4, "通过 UI 招募 4 名英雄（名册 %d→%d）" % [before, TownManager.roster.size()])
		# 把 4 名英雄加入队伍
		var ids: Array = []
		for hero in TownManager.roster:
			if ids.size() >= 4:
				break
			town.call("_on_add_to_party", hero)
			ids.append(hero["id"])
		_check(TownManager.get_selected_party().size() == 4, "通过 UI 组成 4 人队伍")

	# 从城镇出发 → 探索
	town.call("_on_start_pressed")
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.EXPLORATION, "出发后进入探索场景")
	_check(GameState.party.size() == 4, "探索场景队伍为招募的 4 名英雄")

	# 模拟探索撤退 → 结算场景
	var expl: Node = main.get("_current_scene")
	if expl != null and expl.has_method("_on_retreat_pressed"):
		expl.call("_on_retreat_pressed")
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.SETTLEMENT, "撤退后进入结算场景")

	# 结算回城
	var settle_node: Node = main.get("_current_scene")
	if settle_node != null and settle_node.has_method("_on_back_pressed"):
		settle_node.call("_on_back_pressed")
	await get_tree().process_frame
	_check(main.get_current_state() == GameMain.GameState.TOWN, "结算后返回城镇场景")
	_check(TownManager.roster.size() >= 4, "回城后名册保留英雄")
	_check(not TownManager._selected_party_ids.is_empty() or TownManager.gold > 0, "城镇状态延续（金币/队伍）")

	print("[ui] 城镇场景 UI 集成测试完成")
	GameState.end_run()
