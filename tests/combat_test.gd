extends Node
## 战斗系统可复现测试（WS-4 战斗，WS-18 对齐 DD 后更新）
## 运行：godot --headless --path . res://tests/combat_test.tscn
##
## 覆盖（WS-18 对齐后）：
##  1. 站位系统：1~4 号位、技能来源/目标站位判定、空缺自动前移（英雄）
##  2. 命中公式：95 基准 + ACC − DODGE + acc_mod，clamp [0,100]
##  3. 伤害公式：PROT 减免、暴击 ×1.5 + 目标压力 + 施法者减压
##  4. 状态效果：流血/中毒 DOT 回合结算、状态计时与到期移除、Horror 压力持续
##  5. 死亡之门 + DBR：HP=0 进死亡之门，每次受击掷 DBR（基础 67）失败即死
##  6. 位移：击退/拉拽 + 链条位移；撞墙/受阻 → 眩晕（无墙体伤害、无失位惩罚）
##  7. 尸体机制：敌人死亡留尸占位，可被攻击/清尸移除
##  8. 技能无冷却：可连续使用，仅受站位约束
##  9. 胜负与全灭；10. 同 seed 全自动战斗可复现
##
## 所有命中/伤害/暴击/DBR 通过 debug_force_rolls 固定，完全确定。

var _failures := 0

func _ready() -> void:
	await get_tree().process_frame
	_test_formation_and_positions()
	_test_hit_and_damage()
	_test_miss()
	_test_crit()
	_test_bleed_dot()
	_test_poison_dot()
	_test_death_door()
	_test_death_door_hit_again()
	_test_displacement_push()
	_test_displacement_wall_stun()
	_test_displacement_chain()
	_test_corpse()
	_test_no_cooldown()
	_test_horror_and_stress()
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
	_check(TurnManager.heroes[0].can_use_from_position("knight_smite"), "骑士在1号位可用 knight_smite")
	_check(TurnManager.heroes[0].is_in_target_pos("knight_smite", 1), "knight_smite 可命中敌方1号位")
	_check(not TurnManager.heroes[1].can_use_from_position("pierce_shot"), "猎人在2号位不可用 pierce_shot（来源[3,4]）")
	_check(not TurnManager.heroes[0].is_in_target_pos("knight_zeal", 3), "knight_zeal 不可命中敌方3号位（目标[1,2]）")

# ------------------------------------------------------------------
# 2. 命中 + 伤害（95 基准 + ACC − DODGE + acc_mod）
# ------------------------------------------------------------------

func _test_hit_and_damage() -> void:
	# 骑士(ACC20) knight_smite(acc_mod -5) vs 骷髅兵(DODGE8) → 命中 100%
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
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
	# 提高目标闪避使命中低于 100 → 验证落空
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.find_unit(s).dodge = 40
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
	# 命中 = 95-5+20-40 = 70，掷80 → 落空
	TurnManager.debug_force_rolls([100, 1, 80])
	var st := TurnManager.run_round()
	_check(st["monsters"][0]["hp"] == 22, "落空时骷髅兵 HP 不变")

# ------------------------------------------------------------------
# 4. 暴击（×1.5 + 目标压力 + 施法者减压）
# ------------------------------------------------------------------

func _test_crit() -> void:
	TurnManager.start_battle(["berserker"], ["ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 30}, "hero_stress": {"berserker": 10}})
	var b := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, b, "blood_rage", s)
	TurnManager.script_action(1, s, "defend", -1)
	# 命中50 → 暴击1（crit 20%）→ 伤害13 → 目标压力2 → 施法者减压3
	TurnManager.debug_force_rolls([100, 1, 50, 1, 13, 2, 3])
	var st := TurnManager.run_round()
	var berserker: CombatUnit = _unit_by_uid(b)
	var skel: CombatUnit = _unit_by_uid(s)
	# 伤害 = round(13 × (1−0.05) × 1.4 × 1.5) = round(25.935) = 26
	_check(st["monsters"][0]["hp"] == 30 - 26, "暴击伤害 26，HP=%d" % st["monsters"][0]["hp"])
	_check(skel.stress == 2, "暴击目标受 2 压力")
	_check(berserker.stress == 10, "暴击施法者减压（10+3消耗−3减压=10）")

# ------------------------------------------------------------------
# 5. 流血 DOT：每回合结算，受 PROT，到期移除
# ------------------------------------------------------------------

func _test_bleed_dot() -> void:
	TurnManager.start_battle(["knight"], ["ruins_ghoul"])
	var k := _uid("hero", 0)
	var g := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, g, "claw_tear", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5])
	var st := TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.hp == 48 - 4, "claw_tear 伤害 4，HP=%d" % knight.hp)
	_check(knight.has_status("bleed"), "骑士获得流血状态")
	_check(int(knight.get_status("bleed").get("duration", 0)) == 3, "流血持续 3 回合")

	_script_defend(2, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	st = TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 2, "回合2流血 2 点，HP=%d" % knight.hp)
	_check(int(knight.get_status("bleed").get("duration", 0)) == 2, "流血剩余 2 回合")

	_script_defend(3, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	st = TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 4, "回合3流血 2 点，HP=%d" % knight.hp)

	_script_defend(4, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	st = TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 6, "回合4流血 2 点，HP=%d" % knight.hp)
	_check(not knight.has_status("bleed"), "流血到期移除")

# ------------------------------------------------------------------
# 5b. 中毒 DOT
# ------------------------------------------------------------------

func _test_poison_dot() -> void:
	# 骑士放 4 号位以符合 rot_spore 目标站位 [3,4]
	TurnManager.start_battle(["knight"], ["forest_rot_shooter"], {"hero_positions": [4]})
	var k := _uid("hero", 0)
	var g := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, g, "rot_spore", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5])
	var st := TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.has_status("poison"), "骑士获得中毒状态")
	# 骑士 PROT 0.2：回合1 伤害 = round(5×0.8×0.9)=4；回合2 中毒 tick = round(3×0.8)=2
	_script_defend(2, [k, g])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.hp == 48 - 4 - 2, "回合2中毒 2 点（受 PROT），HP=%d" % knight.hp)

# ------------------------------------------------------------------
# 6. 死亡之门 + DBR（英雄基础约 67）
# ------------------------------------------------------------------

func _test_death_door() -> void:
	# 骑士 1 HP，受骷髅兵一击 → 死亡之门，DBR 掷 40（≤67）→ 稳定保命
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s, "bone_slash", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99, 5, 40])
	var st := TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.alive, "DBR 40 ≤ 67：骑士存活")
	_check(knight.hp == 0, "骑士 HP=0")
	_check(knight.death_struggling, "骑士处于死亡之门")
	_check(st["active"], "战斗仍在进行")

	# 回合2 双方防御：无回合开始自动判定，存活
	_script_defend(2, [k, s])
	TurnManager.debug_force_rolls([1, 100])
	st = TurnManager.run_round()
	_check(knight.alive, "未受击：死亡之门英雄存活")

func _test_death_door_hit_again() -> void:
	# 死亡之门英雄再次受击 → 再次掷 DBR，失败即死
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_archer"], {"hero_hp": {"knight": 1}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, s1, "bone_slash", k)
	TurnManager.script_action(1, s2, "defend", -1)
	TurnManager.debug_force_rolls([1, 100, 1, 50, 99, 5, 40])
	TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.alive and knight.death_struggling, "第一击后处于死亡之门")
	# 回合2：s1 再打骑士，DBR 掷 70 → 死亡
	TurnManager.script_action(2, s1, "bone_slash", k)
	_script_defend(2, [k, s2])
	TurnManager.debug_force_rolls([100, 1, 1, 50, 99, 5, 70])
	var st := TurnManager.run_round()
	_check(not knight.alive, "死亡之门受击 DBR 70 > 67：骑士死亡")

# ------------------------------------------------------------------
# 7. 位移：击退（无失位惩罚）
# ------------------------------------------------------------------

func _test_displacement_push() -> void:
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, sg, "shield_slam", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	var st := TurnManager.run_round()
	var skel: CombatUnit = _unit_by_uid(s)
	_check(skel.hp == 22 - 5, "击退技能伤害 5，HP=%d" % skel.hp)
	_check(skel.position == 2, "骷髅兵被击退至 2 号位")
	_check(st["heroes"][0]["hp"] == 55, "无失位惩罚（盾卫未受影响）")

func _test_displacement_wall_stun() -> void:
	# 4 名骷髅兵占满 1~4，击退 1 号位 → 链条推至 4 号位撞墙 → 眩晕（无墙体伤害）
	TurnManager.start_battle(["shieldguard"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"])
	var sg := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s4 := _uid("monster", 3)
	TurnManager.script_action(1, sg, "shield_slam", s1)
	TurnManager.script_action(1, s1, "defend", -1)
	TurnManager.script_action(1, _uid("monster", 1), "defend", -1)
	TurnManager.script_action(1, _uid("monster", 2), "defend", -1)
	# 4号位被眩晕后跳过攻击：验证盾卫不受伤害
	TurnManager.script_action(1, s4, "bone_slash", sg)
	TurnManager.debug_force_rolls([100, 1, 1, 1, 1, 50, 99, 5])
	var st := TurnManager.run_round()
	var skel4: CombatUnit = _unit_by_uid(s4)
	_check(skel4.hp == 22, "4号位骷髅兵撞墙无伤害（HP=%d）" % skel4.hp)
	_check(skel4.position == 4, "4号位骷髅兵未越过边界")
	var stun_logged := false
	for e in TurnManager.event_log:
		if e.get("type") == "displace_stun" and int(e.get("unit", -1)) == s4:
			stun_logged = true
	_check(stun_logged, "位移受阻 → 眩晕（displace_stun 事件）")
	_check(st["heroes"][0]["hp"] == 55, "被眩晕的4号位跳过攻击（盾卫未受伤）")

func _test_displacement_chain() -> void:
	# 3 名骷髅兵占 1~3，击退 1 号位 → 链条整体后移一格
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
	_check(st["heroes"][0]["hp"] == 55, "链条位移无失位惩罚")

# ------------------------------------------------------------------
# 8. 尸体机制
# ------------------------------------------------------------------

func _test_corpse() -> void:
	# 击杀骷髅兵 → 留尸占位，尸体可被攻击清除，清除后前移
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
	_check(corpse != null, "敌人死亡留尸占位")
	_check(corpse.position == 1, "尸体占用 1 号位")
	_check(_unit_by_uid(s2).position == 2, "尸体阻挡后排前移")
	# 攻击尸体 → 清除 → 前移
	TurnManager.script_action(2, k, "knight_smite", corpse.uid)
	TurnManager.script_action(2, s2, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 10])
	TurnManager.run_round()
	var corpse_exists := false
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse_exists = true
	_check(not corpse_exists, "尸体被攻击清除")
	_check(_unit_by_uid(s2).position == 1, "尸体清除后前移")

# ------------------------------------------------------------------
# 9. 技能无冷却
# ------------------------------------------------------------------

func _test_no_cooldown() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"])
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_zeal", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.stress == 2, "knight_zeal 消耗 2 压力")
	# 回合2 再次使用：无冷却
	TurnManager.script_action(2, k, "knight_zeal", s)
	TurnManager.script_action(2, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 5])
	TurnManager.run_round()
	_check(knight.stress == 4, "knight_zeal 连续使用（无冷却）")
	_check(_unit_by_uid(s).hp == 22 - 10, "knight_zeal 再次生效（HP=%d）" % _unit_by_uid(s).hp)

# ------------------------------------------------------------------
# 10. Horror（压力持续）+ 压力累计
# ------------------------------------------------------------------

func _test_horror_and_stress() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_priest"])
	var k := _uid("hero", 0)
	var p := _uid("monster", 0)
	TurnManager.script_action(1, k, "defend", -1)
	TurnManager.script_action(1, p, "fear_bone", k)
	TurnManager.debug_force_rolls([1, 100, 50, 99])
	TurnManager.run_round()
	var knight: CombatUnit = _unit_by_uid(k)
	_check(knight.stress == 3, "fear_bone 压力伤害 3，压力=%d" % knight.stress)
	_check(knight.has_status("horror"), "骑士获得 Horror")
	_script_defend(2, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 5, "回合2 Horror +2，压力=%d" % knight.stress)
	_check(int(knight.get_status("horror").get("duration", 0)) == 1, "Horror 剩余 1 回合")
	_script_defend(3, [k, p])
	TurnManager.debug_force_rolls([50, 50])
	TurnManager.run_round()
	_check(knight.stress == 7, "回合3 Horror +2，压力=%d" % knight.stress)
	_check(not knight.has_status("horror"), "Horror 到期移除")

# ------------------------------------------------------------------
# 11. 空缺自动前移（英雄）
# ------------------------------------------------------------------

func _test_position_auto_forward() -> void:
	# 3 名骷髅兵，击杀 1 号位 → 尸体占位，后排不前移；清尸后前移
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier", "ruins_skel_soldier", "ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var s1 := _uid("monster", 0)
	var s2 := _uid("monster", 1)
	var s3 := _uid("monster", 2)
	TurnManager.script_action(1, k, "knight_smite", s1)
	_script_defend(1, [s1, s2, s3])
	TurnManager.debug_force_rolls([100, 1, 1, 1, 50, 99, 9])
	TurnManager.run_round()
	var corpse: CombatUnit = null
	for m in TurnManager.monsters:
		if m.is_corpse:
			corpse = m
	_check(corpse != null, "击杀留尸")
	_check(_unit_by_uid(s2).position == 2, "尸体阻挡：原2号位不动")
	# 清尸
	TurnManager.script_action(2, k, "knight_smite", corpse.uid)
	_script_defend(2, [s2, s3])
	TurnManager.debug_force_rolls([100, 1, 1, 50, 99, 10])
	TurnManager.run_round()
	_check(_unit_by_uid(s2).position == 1, "清尸后原2号位前移至 1 号位")
	_check(_unit_by_uid(s3).position == 2, "清尸后原3号位前移至 2 号位")

# ------------------------------------------------------------------
# 12. 胜负（敌方全灭）
# ------------------------------------------------------------------

func _test_victory() -> void:
	TurnManager.start_battle(["knight"], ["ruins_skel_soldier"], {"monster_hp": {"ruins_skel_soldier": 5}})
	var k := _uid("hero", 0)
	var s := _uid("monster", 0)
	TurnManager.script_action(1, k, "knight_smite", s)
	TurnManager.script_action(1, s, "defend", -1)
	TurnManager.debug_force_rolls([100, 1, 50, 99, 9])
	var st := TurnManager.run_round()
	_check(not st["active"], "战斗结束（尸体不判胜）")
	_check(st["winner"] == CombatUnit.Team.HEROES, "英雄获胜")

# ------------------------------------------------------------------
# 13. 同 seed 全自动战斗可复现
# ------------------------------------------------------------------

func _test_reproducible_battle() -> void:
	var heroes := ["knight", "shieldguard", "berserker", "physician"]
	var monsters := ["ruins_skel_soldier", "ruins_skel_archer", "ruins_skel_priest", "ruins_ghoul"]
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