extends Node
## 压力 + 火把系统可复现测试（WS-7 完成标准）
## 运行：godot --headless --path . res://tests/stress_test.tscn
##
## 覆盖（GDD 2.4 / 2.5）：
##  1. 压力 0~200 区间；100 触发精神判定（仅一次）
##  2. 精神判定随机分支：D100 ≤25 美德（强化/专注/坚定/暴怒），>25 受难崩溃
##  3. 美德效果：强化全属性+20%、专注暴击+30%、坚定每回合−3压力、暴怒伤害×1.5且不可治疗
##  4. 受难崩溃行为：偏执（50%攻随机队友）、鲁莽（强制攻击最前排）、怯懦（空放）、自虐（攻击自身）、
##     自弃（不可治疗 + 移动时承受压力）
##  5. 受难崩溃下压力 >200 立即死亡；美德不因压力死亡（封顶 200）
##  6. 火把：战斗每回合 −1、三档暴击修正（明亮+5/昏暗0/黑暗−10）、黑暗低压每回合 +1 压力、道具 +25
##
## 所有掷骰通过 debug_force_rolls 固定，完全确定。

var _failures := 0

func _ready() -> void:
	await get_tree().process_frame
	_test_stress_resolution_virtue()
	_test_stress_resolution_affliction()
	_test_virtue_strengthen()
	_test_virtue_focused()
	_test_virtue_steadfast()
	_test_virtue_enraged()
	_test_virtue_no_death_at_200()
	_test_affliction_paranoid_attack_ally()
	_test_affliction_paranoid_waste()
	_test_affliction_reckless()
	_test_affliction_coward()
	_test_affliction_self_harm()
	_test_affliction_self_abuse_no_heal()
	_test_affliction_self_abuse_move_stress()
	_test_affliction_stress_death()
	_test_stress_cap_200()
	_test_torch_battle_decay()
	_test_torch_crit_tiers()
	_test_torch_dark_stress()
	_test_torch_item_restore()
	print("[StressTest] %s（失败 %d 项）" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[StressTest]   ok   " + msg)
	else:
		_failures += 1
		print("[StressTest]   FAIL " + msg)

# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _uid(side: String, index: int) -> int:
	if side == "hero":
		return TurnManager.heroes[index].uid
	return TurnManager.monsters[index].uid

func _script_defend(round_num: int, uids: Array) -> void:
	for uid in uids:
		TurnManager.script_action(round_num, uid, "defend", -1)

## 开启 1 骑士 vs 1 骷髅兵的战斗，把骑士压力放到 98。
func _start_knight_stress_battle(hero_stress: int = 98) -> Dictionary:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_stress": {"knight": hero_stress}})
	return {"k": _uid("hero", 0), "s": _uid("monster", 0)}

## 回合 1 骑士用 knight_zeal（压力消耗 2）把压力推到 100 触发精神判定。
## 掷骰序：行动顺序(k,s) → 判定掷骰 → 分支掷骰 → 命中 → 暴击 → 伤害
## 返回 {knight, skel}
func _resolve_knight(roll_resolve: int, branch_index: int) -> Dictionary:
	var ids := _start_knight_stress_battle()
	var k: int = ids["k"]
	var s: int = ids["s"]
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, roll_resolve, branch_index, 50, 99, 7])
	TurnManager.run_round()
	return {"knight": TurnManager.find_unit(k), "skel": TurnManager.find_unit(s)}

# ------------------------------------------------------------------
# 1. 压力上限 / 精神判定触发（GDD 2.4）
# ------------------------------------------------------------------

func _test_stress_resolution_virtue() -> void:
	# 掷 10（≤25）→ 美德，分支掷 2 → 坚定
	var r := _resolve_knight(10, 2)
	var knight: CombatUnit = r["knight"]
	_check(knight.resolved, "压力 100 触发精神判定（resolved=true）")
	_check(knight.resolution == "virtue", "D100=10 → 美德")
	_check(knight.crisis == "坚定", "美德分支随机 → 坚定")
	_check(knight.stress == 100, "判定后压力保持 100")

func _test_stress_resolution_affliction() -> void:
	# 掷 30（>25）→ 受难，分支掷 0 → 偏执
	var r := _resolve_knight(30, 0)
	var knight: CombatUnit = r["knight"]
	_check(knight.resolved, "压力 100 触发精神判定（resolved=true）")
	_check(knight.resolution == "affliction", "D100=30 → 受难")
	_check(knight.crisis == "偏执", "受难分支随机 → 偏执")

func _test_stress_cap_200() -> void:
	# 未判定英雄压力不会超过 100（封顶即判定）
	var ids := _start_knight_stress_battle(99)
	var k: int = ids["k"]
	TurnManager.script_action(1, k, "knight_zeal", ids["s"])
	TurnManager.script_action(1, ids["s"], "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 90, 1, 50, 99, 7])  # 90 → 受难
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.stress == 100, "未判定英雄压力封顶 100（实际 %d）" % knight.stress)

# ------------------------------------------------------------------
# 2. 美德效果
# ------------------------------------------------------------------

func _test_virtue_strengthen() -> void:
	var r := _resolve_knight(10, 0)  # 强化
	var knight: CombatUnit = r["knight"]
	_check(knight.max_hp == roundi(48 * 1.2), "强化：max_hp ×1.2 = %d" % knight.max_hp)
	_check(knight.spd == roundi(3 * 1.2), "强化：spd ×1.2 = %d" % knight.spd)
	_check(knight.acc == roundi(85 * 1.2), "强化：acc ×1.2 = %d" % knight.acc)
	_check(knight.dmg_max == roundi(9 * 1.2), "强化：dmg_max ×1.2 = %d" % knight.dmg_max)
	_check(is_equal_approx(knight.crit, 0.06), "强化：crit ×1.2 = %.2f" % knight.crit)

func _test_virtue_focused() -> void:
	var r := _resolve_knight(10, 1)  # 专注
	var knight: CombatUnit = r["knight"]
	_check(is_equal_approx(knight.crit, 0.05 + 0.30), "专注：暴击 +30 个百分点 = %.2f" % knight.crit)

func _test_virtue_steadfast() -> void:
	var r := _resolve_knight(10, 2)  # 坚定
	var knight: CombatUnit = r["knight"]
	var k: int = knight.uid
	var s: int = r["skel"].uid
	_check(knight.stress == 100, "判定后压力 100")
	# 回合 2 开始：坚定每回合 −3 压力
	_script_defend(2, [k, s])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 97, "坚定：每回合 −3 压力 → %d" % knight.stress)

func _test_virtue_enraged() -> void:
	var r := _resolve_knight(10, 3)  # 暴怒
	var knight: CombatUnit = r["knight"]
	var k: int = knight.uid
	var s: int = r["skel"].uid
	# 骑士在回合 1 用 knight_zeal（×1.0）触发判定后即受暴怒加成 → 伤害 ×1.5
	# 回合 1 伤害 = round(7×(1−0.05)×1.0×1.5) = 10 → 骷髅兵 HP 12
	var skel: CombatUnit = r["skel"]
	_check(skel.hp == 22 - 10, "暴怒：回合1 伤害 ×1.5 → 骷髅兵 HP=%d" % skel.hp)
	# 回合 2：骑士 knight_smite（×1.2）继续 ×1.5 → round(7×0.95×1.2×1.5)=12 → 骷髅兵死亡
	TurnManager.script_action(2, k, "knight_smite", s)
	TurnManager.script_action(2, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 7])
	TurnManager.run_round()
	_check(not skel.alive, "暴怒：持续 ×1.5 → 骷髅兵被击杀")

func _test_virtue_no_death_at_200() -> void:
	# 美德英雄压力封顶 200，不因压力死亡
	TurnManager.start_battle(["knight"], ["ruins_skel_priest"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var p := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, p, "fear_bone", k)
	# 掷骰：行动顺序(k,p) → 命中 → 判定掷骰 → 分支掷骰（强化=0）
	TurnManager.debug_force_rolls([1, 100, 50, 10, 0])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.resolution == "virtue", "美德判定成功")
	knight.stress = 198
	# 回合 2 开始：恐惧 +2 压力 → 200（封顶，不死亡）
	_script_defend(2, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	var st := TurnManager.run_round()
	_check(knight.alive, "美德英雄压力 200 不死亡")
	_check(knight.stress == 200, "美德英雄压力封顶 200")
	_check(bool(st["active"]), "战斗仍在进行")

# ------------------------------------------------------------------
# 3. 受难崩溃行为
# ------------------------------------------------------------------

func _test_affliction_paranoid_attack_ally() -> void:
	# 偏执：掷 10（≤50）→ 攻击随机队友（骑士打医师）
	TurnManager.start_battle(["knight", "physician"], ["ruins_skel_soldier"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var phy := _uid("hero", 1)
	var s := _uid("monster", 0)
	# 回合 1：骑士压力 100 → 受难偏执（判定 30，分支 0）
	TurnManager.script_action(1, k, "knight_zeal", s)
	_script_defend(1, [phy, s])
	TurnManager.debug_force_rolls([100, 50, 1, 30, 0, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.resolution == "affliction" and knight.crisis == "偏执", "骑士受难偏执")
	var phy_hp_before: int = TurnManager.find_unit(phy).hp
	# 回合 2：骑士（无脚本）走受难行为 → 偏执
	_script_defend(2, [phy, s])
	TurnManager.debug_force_rolls([100, 50, 1, 10, 0, 50, 99, 7])
	TurnManager.run_round()
	var physician: CombatUnit = TurnManager.find_unit(phy)
	_check(physician.hp < phy_hp_before, "偏执：攻击随机队友（医师 HP %d→%d）" % [phy_hp_before, physician.hp])

func _test_affliction_paranoid_waste() -> void:
	# 偏执：掷 60（>50）→ 空放（无技能）
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 30, 0, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.crisis == "偏执", "骑士受难偏执")
	var skel_hp_before: int = TurnManager.find_unit(s).hp
	# 回合 2：偏执掷 60 → 空放
	TurnManager.script_action(2, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 60])
	TurnManager.run_round()
	var skel: CombatUnit = TurnManager.find_unit(s)
	_check(skel.hp == skel_hp_before, "偏执：空放（怪物 HP 不变）")

func _test_affliction_reckless() -> void:
	# 鲁莽：强制攻击最前排（1 号位骷髅兵）
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_archer"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	TurnManager.script_action(1, k, "knight_zeal", s1)
	_script_defend(1, [s1, s2])
	TurnManager.debug_force_rolls([100, 1, 1, 30, 2, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.crisis == "鲁莽", "骑士受难鲁莽")
	var front_hp_before: int = TurnManager.find_unit(s1).hp
	var back_hp_before: int = TurnManager.find_unit(s2).hp
	# 回合 2：鲁莽 → 攻击最前排（s1，1 号位）
	_script_defend(2, [s1, s2])
	TurnManager.debug_force_rolls([100, 1, 1, 50, 99, 7])
	TurnManager.run_round()
	var front: CombatUnit = TurnManager.find_unit(s1)
	var back: CombatUnit = TurnManager.find_unit(s2)
	_check(front.hp < front_hp_before, "鲁莽：攻击最前排（HP %d→%d）" % [front_hp_before, front.hp])
	_check(back.hp == back_hp_before, "鲁莽：后排未被攻击")

func _test_affliction_coward() -> void:
	# 怯懦：不攻击（空放）
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 30, 3, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.crisis == "怯懦", "骑士受难怯懦")
	var skel_hp_before: int = TurnManager.find_unit(s).hp
	TurnManager.script_action(2, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1])
	TurnManager.run_round()
	var skel: CombatUnit = TurnManager.find_unit(s)
	_check(skel.hp == skel_hp_before, "怯懦：不攻击（怪物 HP 不变）")

func _test_affliction_self_harm() -> void:
	# 自虐：攻击自身
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 30, 4, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.crisis == "自虐", "骑士受难自虐")
	var knight_hp_before: int = knight.hp
	# 回合 2：自虐 → 攻击自身（命中/暴击/伤害）
	TurnManager.script_action(2, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 7])
	TurnManager.run_round()
	_check(knight.hp < knight_hp_before, "自虐：攻击自身（HP %d→%d）" % [knight_hp_before, knight.hp])

func _test_affliction_self_abuse_no_heal() -> void:
	# 自弃：不可被治疗
	TurnManager.start_battle(["knight", "physician"], ["ruins_skel_soldier"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var phy := _uid("hero", 1)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", s)
	_script_defend(1, [phy, s])
	TurnManager.debug_force_rolls([100, 50, 1, 30, 1, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.crisis == "自弃", "骑士受难自弃")
	knight.hp = 30
	# 回合 2：医师对骑士使用治愈（cure）
	TurnManager.script_action(2, phy, "cure", k)
	_script_defend(2, [k, s])
	TurnManager.debug_force_rolls([100, 50, 1, 5])
	TurnManager.run_round()
	_check(knight.hp == 30, "自弃：不可被治疗（HP 仍为 30）")

func _test_affliction_self_abuse_move_stress() -> void:
	# 自弃：移动时承受压力（被拉拽 +2）
	TurnManager.start_battle(["knight"], ["forest_wolf_member"], {"hero_stress": {"knight": 98}, "hero_positions": [2]})
	var k := _uid("hero", 0)
	var w := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", w)
	TurnManager.script_action(1, w, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 30, 1, 50, 99, 7])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.crisis == "自弃", "骑士受难自弃")
	var stress_before: int = knight.stress
	# 回合 2：狼用 pounce 把骑士从 2 号位拉到 1 号位
	TurnManager.script_action(2, k, "defend", -1)
	TurnManager.script_action(2, w, "pounce", k)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 7])
	TurnManager.run_round()
	_check(knight.position == 1, "骑士被拉拽至 1 号位")
	_check(knight.stress == stress_before + 2, "自弃：移动时 +2 压力（%d→%d）" % [stress_before, knight.stress])

# ------------------------------------------------------------------
# 4. 受难 >200 立即死亡
# ------------------------------------------------------------------

func _test_affliction_stress_death() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_priest"], {"hero_stress": {"knight": 98}})
	var k := _uid("hero", 0)
	var p := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, p, "fear_bone", k)
	# 掷骰：行动顺序(k,p) → 命中 → 判定(30→受难) → 分支(1→自弃)
	TurnManager.debug_force_rolls([1, 100, 50, 30, 1])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.resolution == "affliction", "受难判定成功")
	knight.stress = 199
	# 回合 2 开始：恐惧 +2 压力 → 201 > 200 → 立即死亡
	_script_defend(2, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	var st := TurnManager.run_round()
	_check(not knight.alive, "受难崩溃下压力 >200 → 立即死亡")
	_check(st["winner"] == CombatUnit.Team.MONSTERS, "怪物获胜")

# ------------------------------------------------------------------
# 5. 火把系统（GDD 2.5）
# ------------------------------------------------------------------

func _test_torch_battle_decay() -> void:
	GameState.torch = 50
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	_script_defend(1, [k, s])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(GameState.torch == 49, "火把战斗每回合 −1（50→49）")

func _test_torch_crit_tiers() -> void:
	# 狂战士 CRIT 0.15；明亮 +5 → 20%，昏暗 0 → 15%，黑暗 −10 → 5%
	# 暴击判定掷 16：明亮命中，昏暗/黑暗不命中
	var results := {}
	for tier in ["bright", "dim", "dark"]:
		match tier:
			"bright":
				GameState.torch = 76
			"dim":
				GameState.torch = 50
			"dark":
				GameState.torch = 11
		TurnManager.start_battle(["berserker"], ["ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 30}})
		var b := _uid("hero", 0)
		var s := _uid("monster", 0)
		TurnManager.script_action(1, b, "blood_rage", s)
		TurnManager.script_action(1, s, "defend", -1)
		# 掷骰：行动顺序(b,s) → 命中50 → 暴击16 → 伤害13 → 暴击压力2（命中时）→ 暴击减压3（命中时）
		if tier == "bright":
			TurnManager.debug_force_rolls([100, 1, 50, 16, 13, 2, 3])
		else:
			TurnManager.debug_force_rolls([100, 1, 50, 16, 13])
		TurnManager.run_round()
		var skel: CombatUnit = TurnManager.find_unit(s)
		# 明亮：伤害 = round(13×(1−0.05)×1.4×1.5)=26 → HP4；昏暗/黑暗：round(13×0.95×1.4)=17 → HP13
		results[tier] = skel.hp
	_check(int(results["bright"]) == 30 - 26, "明亮（暴击+5点）：暴击命中 → HP=%d" % results["bright"])
	_check(int(results["dim"]) == 30 - 17, "昏暗（无修正）：未暴击 → HP=%d" % results["dim"])
	_check(int(results["dark"]) == 30 - 17, "黑暗（暴击-10点）：未暴击 → HP=%d" % results["dark"])

func _test_torch_dark_stress() -> void:
	# 黑暗档：低压氛围每回合 +1 压力（GDD 2.4 压力来源）
	GameState.torch = 11
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	_script_defend(1, [k, s])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.stress == 1, "黑暗低压：每回合 +1 压力 → %d" % knight.stress)

func _test_torch_item_restore() -> void:
	var restore: int = int(GameState.get_torch_config().get("item_restore", 25))
	GameState.torch = 30
	GameState.add_torch(restore)
	_check(restore == 25, "火把道具恢复配置 = 25")
	_check(GameState.torch == 55, "道具 +25 → 火把 55")
