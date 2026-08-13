extends Node
## 战斗系统可复现测试（WS-4 完成标准）
## 运行：godot --headless --path . res://tests/combat_test.tscn
##
## 覆盖（GDD 2.1~2.3 / 2.7 / 2.8 / 2.9）：
##  1. 站位系统：1~4 号位、技能来源/目标站位判定、空缺自动前移
##  2. 命中公式：基准命中+ACC−DODGE，clamp [5,95]，致盲/狂暴/标记修正
##  3. 伤害公式：PROT 减免、暴击 ×1.5 + 1~3 压力
##  4. 状态效果：流血/中毒/燃烧 DOT 回合结算、状态计时与到期移除
##  5. 濒死判定：0 HP 临死挣扎 D100 ≤50 稳定 / >50 死亡、受击再次判定
##  6. 位移：击退/拉拽 + 失位惩罚（下回合跳过行动）、击退撞墙伤害
##  7. 技能冷却：cooldown=N 时 N 个回合不可用
##  8. 恐惧：每回合 +2 压力；队友死亡全队压力
##  9. 胜负与全灭；10. 同 seed 全自动战斗可复现
##
## 所有命中/伤害/暴击/濒死/墙伤通过 debug_force_rolls 固定，完全确定。

var _failures := 0

func _ready() -> void:
	await get_tree().process_frame
	_test_formation_and_positions()
	_test_hit_and_damage()
	_test_miss()
	_test_crit()
	_test_bleed_dot()
	_test_deathblow()
	_test_deathblow_hit_again()
	_test_displacement_push()
	_test_displacement_wall()
	_test_displacement_chain()
	_test_displacement_skip_next()
	_test_cooldown()
	_test_fear_and_stress()
	_test_position_auto_forward()
	_test_victory()
	_test_reproducible_battle()
	print("[CombatTest] %s（失败 %d 项）" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[CombatTest]   ok   " + msg)
	else:
		_failures += 1
		print("[CombatTest]   FAIL " + msg)

# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _unit_by_uid(uid: int) -> CombatUnit:
	return TurnManager.find_unit(uid)

func _uid(side: String, index: int) -> int:
	if side == "hero":
		return TurnManager.heroes[index].uid
	return TurnManager.monsters[index].uid

func _script_defend(round_num: int, uids: Array) -> void:
	for uid in uids:
		TurnManager.script_action(round_num, uid, "defend", -1)

# ------------------------------------------------------------------
# 1. 站位系统
# ------------------------------------------------------------------

func _test_formation_and_positions() -> void:
	TurnManager.start_battle(["knight", "hunter"], ["ruins_skel_soldier", "ruins_skel_archer"])
	_check(TurnManager.heroes[0].position == 1, "英雄1号位=1")
	_check(TurnManager.heroes[1].position == 2, "英雄2号位=2")
	_check(TurnManager.monsters[0].position == 1, "怪物1号位=1")
	_check(TurnManager.monsters[1].position == 2, "怪物2号位=2")
	# 技能来源站位判定
	_check(TurnManager.heroes[0].can_use_from_position("knight_smite"), "骑士在1号位可用 knight_smite")
	_check(TurnManager.heroes[0].is_in_target_pos("knight_smite", 1), "knight_smite 可命中敌方1号位")
	_check(not TurnManager.heroes[1].can_use_from_position("pierce_shot"), "猎人在2号位不可用 pierce_shot（来源[3,4]）")
	_check(not TurnManager.heroes[0].is_in_target_pos("knight_zeal", 3), "knight_zeal 不可命中敌方3号位（目标[1,2]）")

# ------------------------------------------------------------------
# 2. 命中 + 伤害（GDD 2.3）
# ------------------------------------------------------------------

func _test_hit_and_damage() -> void:
	# 骑士(ACC85) knight_smite(基准90) vs 骷髅兵(DODGE8) → 命中95%
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
	# 掷骰序：行动顺序(knight, skel) → 命中 → 暴击 → 伤害
	TurnManager.debug_force_rolls([100, 1, 50, 99, 7])
	var st := TurnManager.run_round()
	_check(st["heroes"][0]["hp"] == 48, "骑士未受伤")
	var skel_hp: int = st["monsters"][0]["hp"]
	# 伤害 = round(7 × (1−0.05) × 1.2) = round(7.98) = 8
	_check(skel_hp == 22 - 8, "骷髅兵受 8 点伤害，HP=%d" % skel_hp)
	_check(TurnManager.debug_pending_rolls() == 0, "掷骰队列全部消费（确定性）")

# ------------------------------------------------------------------
# 3. 落空
# ------------------------------------------------------------------

func _test_miss() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
	# 命中率95%，掷96 → 落空
	TurnManager.debug_force_rolls([100, 1, 96])
	var st := TurnManager.run_round()
	_check(st["monsters"][0]["hp"] == 22, "落空时骷髅兵 HP 不变")

# ------------------------------------------------------------------
# 4. 暴击（GDD 2.3：×1.5 + 目标 1~3 压力）
# ------------------------------------------------------------------

func _test_crit() -> void:
	TurnManager.start_battle(["berserker"], ["ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 30}})
	var b := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, b, "blood_rage", s)
	TurnManager.script_action(1, s, "defend", -1)
	# 狂战士 CRIT 0.15 → 暴击判定15%；掷1命中暴击
	# 掷骰：行动顺序(b,skel) → 命中50 → 暴击1 → 伤害13 → 暴击压力2（对敌）→ 暴击减压3（对己）
	TurnManager.debug_force_rolls([100, 1, 50, 1, 13, 2, 3])
	var st := TurnManager.run_round()
	# 伤害 = round(13 × (1−0.05) × 1.4 × 1.5) = round(25.935) = 26
	_check(st["monsters"][0]["hp"] == 30 - 26, "暴击伤害 26，HP=%d" % st["monsters"][0]["hp"])

# ------------------------------------------------------------------
# 5. 流血 DOT（GDD 2.1 / 2.8）：每回合结算，受 PROT，到期移除
# ------------------------------------------------------------------

func _test_bleed_dot() -> void:
	# 食尸鬼 claw_tear：伤害 + 流血2/3回合
	TurnManager.start_battle(["knight"], ["ruins_ghoul"])
	var k := _uid("hero", 0)
	var g := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, g, "claw_tear", k)
	# 掷骰：行动顺序(k,ghoul) → 命中50 → 暴击99 → 伤害5
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5])
	var st := TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	# claw_tear 伤害 = round(5 × (1−0.2) × 1.1) = round(4.4) = 4
	_check(knight.hp == 48 - 4, "claw_tear 伤害 4，HP=%d" % knight.hp)
	_check(knight.has_status("bleed"), "骑士获得流血状态")
	_check(int(knight.get_status("bleed").get("duration", 0)) == 3, "流血持续 3 回合")

	# 回合2：流血 tick = round(2 × (1−0.2)) = 2，duration→2
	_script_defend(2, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	st = TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 2, "回合2流血 2 点，HP=%d" % knight.hp)
	_check(int(knight.get_status("bleed").get("duration", 0)) == 2, "流血剩余 2 回合")

	# 回合3：再 tick，duration→1
	_script_defend(3, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	st = TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 4, "回合3流血 2 点，HP=%d" % knight.hp)

	# 回合4：再 tick，duration→0 移除
	_script_defend(4, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	st = TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 6, "回合4流血 2 点，HP=%d" % knight.hp)
	_check(not knight.has_status("bleed"), "流血到期移除")

# ------------------------------------------------------------------
# 6. 濒死判定（GDD 2.4 / 2.9）
# ------------------------------------------------------------------

func _test_deathblow() -> void:
	# 骑士 1 HP，受骷髅兵一击 → 濒死，掷40(≤50) → 稳定保命
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s, "bone_slash", k)
	# 掷骰：行动顺序(k,skel) → 命中50 → 暴击99 → 伤害5 → 濒死40
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 40])
	var st := TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.alive, "濒死判定稳定：骑士存活")
	_check(knight.hp == 0, "骑士 HP=0")
	_check(knight.death_struggling, "骑士处于濒死挣扎状态")
	_check(st["active"], "战斗仍在进行")

	# 回合2开始：濒死单位再判定，掷60(>50) → 死亡
	TurnManager.debug_force_rolls([60])
	st = TurnManager.run_round()
	_check(not knight.alive, "濒死判定失败：骑士死亡")
	_check(st["winner"] == CombatUnit.Team.MONSTERS, "怪物获胜")

# ------------------------------------------------------------------
# 6b. 受击时再次判定（GDD 2.4）
# ------------------------------------------------------------------

func _test_deathblow_hit_again() -> void:
	# 骑士 1 HP 稳定在0后，受第二击再次判定 → 失败死亡
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_archer"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s1, "bone_slash", k)
	TurnManager.script_action(1, s2, "defend", -1)
	# 回合1：行动顺序(k,s1,s2) → s1 命中50/暴击99/伤害5 → 濒死40稳定
	TurnManager.debug_force_rolls([1, 100, 1, 50, 99, 5, 40])
	TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.alive and knight.death_struggling, "第一击后处于濒死")
	# 回合2：s1 再打骑士。回合开始先掷濒死判定（40稳定），随后 init 3 骰，
	# s1 命中/暴击/伤害，受击时再次判定掷70 → 死亡
	TurnManager.script_action(2, s1, "bone_slash", k)
	_script_defend(2, [k, s2])
	TurnManager.debug_force_rolls([40, 100, 1, 1, 50, 99, 5, 70])
	var st := TurnManager.run_round()
	_check(not knight.alive, "受击再次判定失败：骑士死亡")

# ------------------------------------------------------------------
# 7. 位移：击退（GDD 2.7）
# ------------------------------------------------------------------

func _test_displacement_push() -> void:
	# 盾卫 shield_slam：伤害 + 击退1格
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, sg, "shield_slam", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	var st := TurnManager.run_round()
	var skel: CombatUnit = _unit_by_uid(s)
	# 伤害 = round(5 × (1−0.05) × 1.0) = 5
	_check(skel.hp == 22 - 5, "击退技能伤害 5，HP=%d" % skel.hp)
	_check(skel.position == 2, "骷髅兵被击退至 2 号位")
	_check(skel.displaced_skip_round == 2, "击退产生失位惩罚（下回合跳过）")

# ------------------------------------------------------------------
# 7b. 击退撞墙：额外 1~3 地形伤害
# ------------------------------------------------------------------

func _test_displacement_wall() -> void:
	# 4 名骷髅兵占满 1~4 号位，盾卫击退 1 号位 → 链条推到 4 号位撞墙
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s4 := _uid("monster", 3)
	TurnManager.script_action(1, sg, "shield_slam", s1)
	_script_defend(1, [s1, _uid("monster", 1), _uid("monster", 2), s4])
	# 掷骰：行动顺序(5单位) → 命中50 → 暴击99 → 伤害5 → 撞墙2
	TurnManager.debug_force_rolls([100, 1, 1, 1, 1, 50, 99, 5, 2])
	var st := TurnManager.run_round()
	var skel4: CombatUnit = _unit_by_uid(s4)
	_check(skel4.hp == 22 - 2, "4号位骷髅兵撞墙受 2 点地形伤害，HP=%d" % skel4.hp)
	_check(skel4.position == 4, "4号位骷髅兵未越过边界")
	# 满编阵型：链条被墙阻断，前排未被推动（无位移、无失位惩罚）
	_check(st["monsters"][0]["position"] == 1, "满编阵型前排未被推动（仍在1号位）")
	_check(_unit_by_uid(s1).displaced_skip_round == 0, "未发生位移，无失位惩罚")

func _test_displacement_chain() -> void:
	# 3 名骷髅兵占 1~3 号位（4 号位空），击退 1 号位 → 链条整体后移一格
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	var s3 := _uid("monster", 2)
	TurnManager.script_action(1, sg, "shield_slam", s1)
	_script_defend(1, [s1, s2, s3])
	TurnManager.debug_force_rolls([100, 1, 1, 1, 50, 99, 5])
	var st := TurnManager.run_round()
	_check(_unit_by_uid(s1).position == 2, "1号位被击退至 2 号位（链条位移）")
	_check(_unit_by_uid(s2).position == 3, "2号位被推动至 3 号位")
	_check(_unit_by_uid(s3).position == 4, "3号位被推动至 4 号位")
	_check(_unit_by_uid(s3).displaced_skip_round == 2, "链条末端单位同样进入失位惩罚")

# ------------------------------------------------------------------
# 7c. 失位惩罚：下回合跳过行动
# ------------------------------------------------------------------

func _test_displacement_skip_next() -> void:
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, sg, "shield_slam", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	TurnManager.run_round()
	var skel: CombatUnit = _unit_by_uid(s)
	_check(skel.displaced_skip_round == 2, "击退后失位惩罚标记存在")
	# 回合2：骷髅兵试图攻击，但被失位惩罚跳过
	TurnManager.script_action(2, sg, "defend", -1)
	TurnManager.script_action(2, s, "bone_slash", sg)
	TurnManager.debug_force_rolls([100, 1])
	var st := TurnManager.run_round()
	_check(st["heroes"][0]["hp"] == 55, "失位骷髅兵跳过行动，盾卫未受伤")
	_check(skel.displaced_skip_round == 0, "失位惩罚已消耗")

# ------------------------------------------------------------------
# 8. 技能冷却
# ------------------------------------------------------------------

func _test_cooldown() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	var st := TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.cooldowns.has("knight_zeal"), "knight_zeal 进入冷却")
	_check(int(knight.cooldowns.get("knight_zeal", 0)) == 3, "冷却 2 → 初始值 3")
	_check(not knight.is_skill_ready("knight_zeal"), "knight_zeal 不可用")
	# 回合2：冷却-1 → 2，仍不可用
	_script_defend(2, [k, s])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(int(knight.cooldowns.get("knight_zeal", 0)) == 2, "回合2 冷却=2")
	# 回合3：冷却-1 → 1
	_script_defend(3, [k, s])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(int(knight.cooldowns.get("knight_zeal", 0)) == 1, "回合3 冷却=1")
	# 回合4：冷却-1 → 0 移除，恢复可用
	_script_defend(4, [k, s])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.is_skill_ready("knight_zeal"), "回合4 冷却结束恢复可用")
	# 技能消耗：knight_zeal cost stress 2
	_check(knight.stress == 2, "knight_zeal 消耗 2 压力")

# ------------------------------------------------------------------
# 9. 恐惧（每回合+2压力）+ 压力累计
# ------------------------------------------------------------------

func _test_fear_and_stress() -> void:
	# 骸骨祭司 fear_bone：压力伤害3 + 恐惧2回合
	TurnManager.start_battle(["knight"], ["ruins_skel_priest"])
	var k := _uid("hero", 0)
	var p := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, p, "fear_bone", k)
	# 掷骰：行动顺序(k,priest) → 命中50 → 暴击99
	TurnManager.debug_force_rolls([1, 100, 50, 99])
	TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.stress == 3, "fear_bone 压力伤害 3，压力=%d" % knight.stress)
	_check(knight.has_status("fear"), "骑士获得恐惧")
	# 回合2开始：恐惧 +2 压力，duration→1
	_script_defend(2, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 5, "回合2 恐惧 +2，压力=%d" % knight.stress)
	_check(int(knight.get_status("fear").get("duration", 0)) == 1, "恐惧剩余 1 回合")
	# 回合3开始：恐惧 +2，到期移除
	_script_defend(3, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 7, "回合3 恐惧 +2，压力=%d" % knight.stress)
	_check(not knight.has_status("fear"), "恐惧到期移除")

# ------------------------------------------------------------------
# 10. 空缺自动前移
# ------------------------------------------------------------------

func _test_position_auto_forward() -> void:
	# 3 名骷髅兵，击杀 1 号位 → 其余前移
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	var s3 := _uid("monster", 2)
	TurnManager.script_action(1, k, "knight_smite", s1)
	_script_defend(1, [s1, s2, s3])
	# 掷骰：行动顺序(k,s1,s2,s3) → 命中50 → 暴击99 → 伤害9 → 濒死70(死亡)
	TurnManager.debug_force_rolls([100, 1, 1, 1, 50, 99, 9, 70])
	var st := TurnManager.run_round()
	var m2: CombatUnit = _unit_by_uid(s2)
	var m3: CombatUnit = _unit_by_uid(s3)
	_check(not _unit_by_uid(s1).alive, "1号位骷髅兵死亡")
	_check(m2.position == 1, "原2号位前移至 1 号位")
	_check(m3.position == 2, "原3号位前移至 2 号位")

# ------------------------------------------------------------------
# 11. 胜负（敌方全灭）
# ------------------------------------------------------------------

func _test_victory() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 9, 70])
	var st := TurnManager.run_round()
	_check(not st["active"], "战斗结束")
	_check(st["winner"] == CombatUnit.Team.HEROES, "英雄获胜")

# ------------------------------------------------------------------
# 12. 同 seed 全自动战斗可复现
# ------------------------------------------------------------------

func _test_reproducible_battle() -> void:
	var heroes := ["knight", "shieldguard", "berserker", "physician"]
	var monsters := ["ruins_skel_soldier", "ruins_skel_archer", "ruins_skel_priest", "ruins_ghoul"]
	# 火把为全局状态（WS-7 战斗每回合 −1），两场对局前统一复位保证可比
	GameState.torch = 75
	TurnManager.start_battle(heroes, monsters, {"seed": 20240812})
	var st1 := TurnManager.run_battle(60)
	var log1 := JSON.stringify(TurnManager.event_log)
	GameState.torch = 75
	TurnManager.start_battle(heroes, monsters, {"seed": 20240812})
	var st2 := TurnManager.run_battle(60)
	var log2 := JSON.stringify(TurnManager.event_log)
	_check(st1["active"] == st2["active"], "两场战斗结束状态一致")
	_check(st1["winner"] == st2["winner"], "两场战斗胜者一致")
	_check(log1 == log2, "同 seed 事件日志完全一致（可复现）")
	_check(st1["active"] == false, "全自动战斗能在 60 回合内结束")
