extends Node
## WS-18 战斗系统返工验证测试（按 WS-17 第 2 节对齐《暗黑地牢》）
## 运行：godot --headless --path . res://tests/test_ws18.tscn
##
## 覆盖 9 项交付物：
##  D1 敌人上限 4（双方各 4 站位，特殊遭遇可召唤）
##  D2 命中公式 95% 基准 + ACC − DODGE + 技能 acc_mod，clamp [0,100]
##  D3 死亡之门 + DBR（英雄基础约 67，失败即死；移除 D100≤50）
##  D4 状态效果表对齐：无燃烧/致盲/狂暴/迷惑残留；Horror（压力持续）/Riposte（反击）/Debuff 生效
##  D5 尸体机制：敌人死亡留尸占位、可被攻击/清尸技能移除
##  D6 位移受阻→眩晕（去墙体伤害）；失位机制移除
##  D7 暴击：目标受压力伤害 + 施法者减压
##  D8 技能移除冷却，仅受站位/目标站位约束
##  D9 战斗内撤退逐人判定（成功者逃、失败者留）
##
## 所有掷骰通过 debug_force_rolls 固定，完全确定。

var _failures := 0

func _ready() -> void:
	await get_tree().process_frame
	_d1_enemy_cap_4()
	_d2_hit_formula()
	_d2_miss()
	_d3_death_door_dbr()
	_d3_no_auto_deathblow_at_round_start()
	_d3_dbr_threshold_67()
	_d4_status_table_no_residue()
	_d4_horror_stress()
	_d4_riposte()
	_d5_corpse_spawn_and_block()
	_d5_corpse_attackable()
	_d5_corpse_clear_skill()
	_d6_displace_wall_stun()
	_d6_displace_chain_no_skip()
	_d7_crit_stress_and_relief()
	_d8_no_cooldown()
	_d9_retreat_per_hero()
	print("[WS18Test] %s（失败 %d 项）" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[WS18Test]   ok   " + msg)
	else:
		_failures += 1
		print("[WS18Test]   FAIL " + msg)

func _script_defend(round_num: int, uids: Array) -> void:
	for uid in uids:
		TurnManager.script_action(round_num, uid, "defend", -1)

func _uid(side: String, index: int) -> int:
	if side == "hero":
		return TurnManager.heroes[index].uid
	return TurnManager.monsters[index].uid

# ------------------------------------------------------------------
# D1 敌人上限 4（双方各 4 站位，特殊遭遇可召唤）
# ------------------------------------------------------------------

func _d1_enemy_cap_4() -> void:
	TurnManager.start_battle(
		["knight", "hunter", "physician", "rogue", "berserker", "occultist"],
		["ruins_skel_soldier", "ruins_skel_archer", "ruins_skel_priest", "ruins_ghoul", "ruins_ghost", "forest_wolf_member"])
	_check(TurnManager.heroes.size() == 4, "英雄上限 4（传入 6 截断到 4）")
	_check(TurnManager.monsters.size() == 4, "敌人上限 4（传入 6 截断到 4）")
	var pos_ok := true
	for i in TurnManager.monsters.size():
		if TurnManager.monsters[i].position != i + 1:
			pos_ok = false
	_check(pos_ok, "敌人站位 1~4 号位")

# ------------------------------------------------------------------
# D2 命中公式：95% 基准 + ACC − DODGE + acc_mod，clamp [0,100]
# ------------------------------------------------------------------

func _d2_hit_formula() -> void:
	_check(BattleRules.hit_chance(-5, 20, 10) == 100, "公式 95-5+20-10=100（clamp 100）")
	_check(BattleRules.hit_chance(-25, 20, 25) == 65, "公式 95-25+20-25=65")
	_check(BattleRules.hit_chance(5, 20, 200) == 0, "超低命中 clamp 到 0")
	_check(BattleRules.hit_chance(5, 200, 20) == 100, "超高命中 clamp 到 100")

func _d2_miss() -> void:
	# 骑士 smite(acc_mod -5, acc 20) vs 骷髅兵：把 dodge 提到 40 → 命中 70
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.find_unit(s).dodge = 40
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 80])
	var st := TurnManager.run_round()
	_check(st["monsters"][0]["hp"] == 22, "命中率 70，掷 80 落空（骷髅兵 HP 不变）")

# ------------------------------------------------------------------
# D3 死亡之门 + DBR（英雄基础约 67，失败即死）
# ------------------------------------------------------------------

func _d3_death_door_dbr() -> void:
	# 骑士 1 HP 受击 → 死亡之门，DBR 掷 60（≤67）→ 稳定
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s, "bone_slash", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 60])
	var st := TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.alive, "DBR 60 ≤ 67 → 英雄存活")
	_check(knight.hp == 0 and knight.death_struggling, "英雄进入死亡之门（HP=0）")
	_check(bool(st["active"]), "战斗仍在进行")
	# 后续再受击：DBR 掷 70（>67）→ 即死
	TurnManager.script_action(2, k, "defend", -1)
	TurnManager.script_action(2, s, "bone_slash", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 70])
	st = TurnManager.run_round()
	_check(not knight.alive, "死亡之门再次受击 DBR 70 > 67 → 死亡")
	_check(st["winner"] == CombatUnit.Team.MONSTERS, "怪物获胜")

func _d3_no_auto_deathblow_at_round_start() -> void:
	# 死亡之门英雄不再在回合开始自动判定（仅受击触发）
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s, "bone_slash", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 40])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.alive and knight.death_struggling, "回合1 进入死亡之门并稳定")
	# 回合2 双方防御：回合开始无自动 DBR 判定
	_script_defend(2, [k, s])
	TurnManager.debug_force_rolls([1, 100])
	TurnManager.run_round()
	_check(knight.alive, "回合2 未受击：死亡之门英雄存活（无回合开始自动判定）")
	_check(knight.death_struggling, "仍在死亡之门")

func _d3_dbr_threshold_67() -> void:
	# 证明阈值是 DBR(67) 而非旧 D100≤50：掷 60 在旧规则下死亡、新规则下存活
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s, "bone_slash", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 60])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.alive, "DBR 掷 60：旧 D100≤50 规则会死，新 DBR67 规则存活")
	# DBR 可被怪癖/饰品修正：手动降低 dbr 后 60 判死
	knight.dbr = 40
	TurnManager.script_action(3, k, "defend", -1)
	TurnManager.script_action(3, s, "bone_slash", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 50])
	TurnManager.run_round()
	_check(not knight.alive, "DBR 修正为 40：掷 50 > 40 → 死亡（DBR 修正生效）")

# ------------------------------------------------------------------
# D4 状态效果表对齐
# ------------------------------------------------------------------

func _d4_status_table_no_residue() -> void:
	# 数据层：无燃烧/致盲/狂暴/迷惑残留
	var removed := ["burn", "blind", "berserk", "confuse"]
	var residue: Array[String] = []
	for id: String in ConfigManager.get_section("skills").keys():
		if id.begins_with("_"):
			continue
		var sk: Dictionary = ConfigManager.get_entry("skills", id)
		residue.append_array(_effect_statuses(sk))
	for id: String in ConfigManager.get_section("monsters").keys():
		if id.begins_with("_"):
			continue
		var mon: Dictionary = ConfigManager.get_entry("monsters", id)
		for sk in mon.get("skills", []):
			residue.append_array(_effect_statuses(sk))
	for id: String in ConfigManager.get_section("heroes").keys():
		if id.begins_with("_"):
			continue
		for sk_id in ConfigManager.get_entry("heroes", id).get("skill_ids", []):
			residue.append_array(_effect_statuses(ConfigManager.get_entry("skills", sk_id)))
	var bad: Array[String] = []
	for s in residue:
		if s in removed:
			bad.append(s)
	_check(bad.is_empty(), "无燃烧/致盲/狂暴/迷惑残留（残留：%s）" % ", ".join(bad))

func _effect_statuses(skill: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for e in skill.get("effects", []):
		var ed: Dictionary = e
		out.append(String(ed.get("status", "")))
	return out

func _d4_horror_stress() -> void:
	# 骸骨祭司 fear_bone：压力伤害 3 + Horror 2 回合，回合开始 +2 压力
	TurnManager.start_battle(["knight"], ["ruins_skel_priest"])
	var k := _uid("hero", 0)
	var p := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, p, "fear_bone", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.stress == 3, "fear_bone 压力伤害 3")
	_check(knight.has_status("horror"), "骑士获得 Horror（压力持续）")
	_script_defend(2, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 5, "回合2 Horror +2 压力（%d）" % knight.stress)
	_check(int(knight.get_status("horror").get("duration", 0)) == 1, "Horror 剩余 1 回合")
	_script_defend(3, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 7, "回合3 Horror +2 压力（%d）" % knight.stress)
	_check(not knight.has_status("horror"), "Horror 到期移除")

func _d4_riposte() -> void:
	# 盾卫 shield_wall（护甲↑ + 反击 1 回合）；食尸鬼攻击后被反击
	TurnManager.start_battle(["shieldguard"], ["ruins_ghoul"])
	var sg := _uid("hero", 0)
	var g := _uid("monster", 0)
	TurnManager.script_action(1, sg, "shield_wall", sg)
	TurnManager.script_action(1, g, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50])
	TurnManager.run_round()
	var guard: CombatUnit = TurnManager.find_unit(sg)
	_check(guard.has_status("riposte"), "盾卫获得反击（Riposte）")
	# 回合2：食尸鬼攻击盾卫 → 被反击
	TurnManager.script_action(2, sg, "defend", -1)
	TurnManager.script_action(2, g, "claw_tear", sg)
	# 掷骰：行动顺序(sg,g) → 命中 → 暴击 → 伤害5 → 反击伤害6
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5, 6])
	TurnManager.run_round()
	var ghoul: CombatUnit = TurnManager.find_unit(g)
	_check(guard.hp == 55 - 4, "食尸鬼造成 4 伤害（盾卫 HP=%d）" % guard.hp)
	_check(ghoul.hp == 30 - 6, "盾卫反击食尸鬼 6 伤害（HP=%d）" % ghoul.hp)

# ------------------------------------------------------------------
# D5 尸体机制
# ------------------------------------------------------------------

func _d5_corpse_spawn_and_block() -> void:
	# 击杀骷髅兵 → 留尸占位；后排不因尸体前移
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	TurnManager.script_action(1, k, "knight_smite", s1)
	_script_defend(1, [s1, s2])
	TurnManager.debug_force_rolls([100, 1, 1, 50, 99, 9])
	var st := TurnManager.run_round()
	var corpse: CombatUnit = null
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse = m
	_check(not _unit_alive(s1), "1号位骷髅兵被击杀")
	_check(corpse != null, "敌人死亡留尸占位")
	_check(corpse.position == 1, "尸体占用 1 号位")
	_check(corpse.max_hp == TurnManager.CORPSE_HP_DEFAULT, "尸体 HP = 默认 10")
	_check(TurnManager.find_unit(s2).position == 2, "尸体阻挡：原2号位未前移")
	_check(bool(st["active"]), "战斗继续（尸体不判胜）")

func _d5_corpse_attackable() -> void:
	# 尸体可被攻击，HP 归零后移除并前移存活敌人
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	TurnManager.script_action(1, k, "knight_smite", s1)
	_script_defend(1, [s1, s2])
	TurnManager.debug_force_rolls([100, 1, 1, 50, 99, 9])
	TurnManager.run_round()
	var corpse: CombatUnit = null
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse = m
	# 回合2：骑士攻击尸体（伤害 11 ≥ 10）→ 尸体被清除
	TurnManager.script_action(2, k, "knight_smite", corpse.uid)
	TurnManager.script_action(2, s2, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 10])
	TurnManager.run_round()
	var corpse_exists := false
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse_exists = true
	_check(not corpse_exists, "尸体被攻击清除")
	_check(TurnManager.find_unit(s2).position == 1, "尸体清除后存活敌人前移至 1 号位")

func _d5_corpse_clear_skill() -> void:
	# 医师 corpse_cleanse 清尸技能移除尸体
	TurnManager.start_battle(["knight", "physician"], ["ruins_skel_soldier", "ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var phy := _uid("hero", 1)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	TurnManager.script_action(1, k, "knight_smite", s1)
	_script_defend(1, [phy, s1, s2])
	TurnManager.debug_force_rolls([100, 50, 1, 1, 50, 99, 9])
	TurnManager.run_round()
	var corpse: CombatUnit = null
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse = m
	_check(corpse != null, "回合1 留下尸体")
	# 回合2：医师清尸
	TurnManager.script_action(2, k, "defend", -1)
	TurnManager.script_action(2, phy, "corpse_cleanse", corpse.uid)
	TurnManager.script_action(2, s2, "defend", -1)
	TurnManager.debug_force_rolls([100, 50, 1, 50])
	TurnManager.run_round()
	var corpse_exists := false
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse_exists = true
	_check(not corpse_exists, "清尸技能移除尸体")
	_check(TurnManager.find_unit(s2).position == 1, "清尸后敌人前移")

# ------------------------------------------------------------------
# D6 位移受阻→眩晕（去墙体伤害、去失位）
# ------------------------------------------------------------------

func _d6_displace_wall_stun() -> void:
	# 4 名骷髅兵占满 1~4，盾卫击退 1 号位 → 链条推至 4 号位撞墙 → 眩晕（无墙体伤害）
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s4 := _uid("monster", 3)
	TurnManager.script_action(1, sg, "shield_slam", s1)
	TurnManager.script_action(1, s1, "defend", -1)
	TurnManager.script_action(1, _uid("monster", 1), "defend", -1)
	TurnManager.script_action(1, _uid("monster", 2), "defend", -1)
	# 4号位骷髅兵被眩晕后应跳过攻击：让它攻击盾卫，验证盾卫不受伤害
	TurnManager.script_action(1, s4, "bone_slash", sg)
	TurnManager.debug_force_rolls([100, 1, 1, 1, 1, 50, 99, 5])
	TurnManager.run_round()
	var skel4: CombatUnit = TurnManager.find_unit(s4)
	_check(skel4.hp == 22, "撞墙无墙体伤害（HP 仍 22）")
	_check(skel4.position == 4, "未越过边界")
	var stun_logged := false
	for e in TurnManager.event_log:
		if e.get("type") == "displace_stun" and int(e.get("unit", -1)) == s4:
			stun_logged = true
	_check(stun_logged, "位移受阻 → 眩晕（displace_stun 事件）")
	_check(TurnManager.find_unit(sg).hp == 55, "被眩晕的4号位跳过攻击（盾卫未受伤）")
	_check(_unit_skip_round(TurnManager.find_unit(s1)) == 0, "无失位惩罚（s1 不跳过行动）")

func _d6_displace_chain_no_skip() -> void:
	# 3 名骷髅兵 1~3，击退 1 号位 → 链条后移一格，无失位惩罚
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	var s3 := _uid("monster", 2)
	TurnManager.script_action(1, sg, "shield_slam", s1)
	_script_defend(1, [s1, s2, s3])
	TurnManager.debug_force_rolls([100, 1, 1, 1, 50, 99, 5])
	TurnManager.run_round()
	_check(TurnManager.find_unit(s1).position == 2, "1号位被击退至 2 号位（链条）")
	_check(TurnManager.find_unit(s2).position == 3, "2号位被推动至 3 号位")
	_check(TurnManager.find_unit(s3).position == 4, "3号位被推动至 4 号位")
	_check(_unit_skip_round(TurnManager.find_unit(s3)) == 0, "链条末端无失位惩罚")

func _unit_alive(uid: int) -> bool:
	var u := TurnManager.find_unit(uid)
	return u != null and u.alive

func _unit_skip_round(u: CombatUnit) -> int:
	return 0  # 失位机制已移除（无 displaced_skip_round）

# ------------------------------------------------------------------
# D7 暴击：目标受压力伤害 + 施法者减压
# ------------------------------------------------------------------

func _d7_crit_stress_and_relief() -> void:
	TurnManager.start_battle(["berserker"], ["ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 30}, "hero_stress": {"berserker": 10}})
	var b := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, b, "blood_rage", s)
	TurnManager.script_action(1, s, "defend", -1)
	# 掷骰：行动顺序(b,s) → 命中50 → 暴击1 → 伤害13 → 暴击目标压力2 → 暴击施法者减压3
	TurnManager.debug_force_rolls([100, 1, 50, 1, 13, 2, 3])
	var st := TurnManager.run_round()
	var berserker: CombatUnit = TurnManager.find_unit(b)
	var skel: CombatUnit = TurnManager.find_unit(s)
	_check(skel.hp == 30 - 26, "暴击伤害 26（HP=%d）" % skel.hp)
	_check(skel.stress == 2, "暴击目标受 2 压力")
	_check(berserker.stress == 10, "暴击施法者减压：10+3消耗−3减压=10")
	_check(st["monsters"][0]["hp"] == 4, "骷髅兵 HP 4")

# ------------------------------------------------------------------
# D8 技能移除冷却，仅受站位/目标站位约束
# ------------------------------------------------------------------

func _d8_no_cooldown() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	# 回合1：knight_zeal（旧冷却2）使用一次
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	TurnManager.run_round()
	var knight: CombatUnit = TurnManager.find_unit(k)
	_check(knight.stress == 2, "knight_zeal 消耗 2 压力")
	_check(TurnManager.find_unit(s).hp == 22 - 5, "回合1 knight_zeal 造成 5 伤害")
	# 回合2：再次使用 knight_zeal（无冷却）
	TurnManager.script_action(2, k, "knight_zeal", s)
	TurnManager.script_action(2, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	TurnManager.run_round()
	_check(knight.stress == 4, "回合2 knight_zeal 可再次使用（无冷却，压力 4）")
	_check(TurnManager.find_unit(s).hp == 22 - 10, "回合2 再次造成 5 伤害（HP=%d）" % TurnManager.find_unit(s).hp)
	_check(knight.can_use_from_position("knight_zeal"), "knight_zeal 站位可用")
	_check(not knight.skills.get("knight_zeal", {}).has("cooldown"), "技能数据无 cooldown 字段")

# ------------------------------------------------------------------
# D9 战斗内撤退逐人判定
# ------------------------------------------------------------------

func _d9_retreat_per_hero() -> void:
	TurnManager.start_battle(["knight", "physician"], ["ruins_skel_soldier", "ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var phy := _uid("hero", 1)
	# 骑士：50+3*2=56；医师：50+6*2=62
	TurnManager.debug_force_rolls([60, 70])
	var res := TurnManager.attempt_retreat()
	_check(res["escaped"].is_empty() and res["stayed"].size() == 2, "撤退判定：两人均失败留场")
	_check(not res["all_escaped"], "未全逃 → 战斗继续")
	_check(TurnManager.battle_active, "战斗仍进行")
	_check(TurnManager.find_unit(k).alive, "失败者留在战场")
	# 第二次：骑士成功（50≤56），医师失败（70>62）
	TurnManager.debug_force_rolls([50, 70])
	res = TurnManager.attempt_retreat()
	_check(res["escaped"] == [k] and res["stayed"] == [phy], "骑士逃跑、医师留下")
	_check(TurnManager.find_unit(k).retreated, "骑士标记为已撤退")
	_check(not TurnManager.find_unit(k).alive, "骑士离开战场（alive=false）")
	_check(TurnManager.battle_active, "仍有英雄在场 → 战斗继续")
	# 第三次：医师成功（60≤62）→ 全逃，战斗结束
	TurnManager.debug_force_rolls([60])
	res = TurnManager.attempt_retreat()
	_check(res["all_escaped"], "医师成功 → 全员撤退")
	_check(not TurnManager.battle_active, "全员撤退 → 战斗结束")
	_check(TurnManager.winner == CombatUnit.Team.MONSTERS, "撤退按失败结算")
	# 压力影响撤退判定：高压力骑士更难逃（50+6-10=46，掷50失败）
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_stress": {"knight": 100}})
	TurnManager.debug_force_rolls([50])
	res = TurnManager.attempt_retreat()
	_check(res["stayed"] == [k], "高压力（100）降低撤退成功率：掷50>46 失败留场")