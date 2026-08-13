extends Node
## TurnManager：回合制战斗核心单例（GDD 2.1~2.3 / 2.7 / 2.8 / 2.9）
##
## 职责：
##   1. 回合流程：回合开始结算持续效果 → SPD+D100 行动顺序 → 依次行动 → 回合结束检查。
##   2. 站位系统：双方各 4 格（1~4 号位），技能可用性与目标站位判定，空缺自动前移。
##   3. 技能结算：命中/伤害/暴击/治疗/状态/位移/召唤/冷却/消耗。
##   4. 濒死判定（0 HP 临死挣扎 D100）与死亡结算。
##   5. 胜负判定（敌方全灭胜 / 我方全灭败）。
##
## 数据全部来自 ConfigManager（只读），运行期数值在 CombatUnit 实例上。
## 随机性通过 rng（可播种）与 debug_force_rolls 控制，保证测试可复现。

signal battle_started
signal round_started(round_num: int)
signal unit_acted(unit: CombatUnit, skill_id: String)
signal damage_dealt(attacker: CombatUnit, target: CombatUnit, amount: int, is_crit: bool)
signal status_applied(unit: CombatUnit, status_name: String, duration: int)
signal unit_died(unit: CombatUnit)
signal battle_ended(winner: int)

const MAX_ROUNDS := 50
const TEAM_SLOTS := 4
## 队友死亡给全队英雄的压力（GDD 2.4：队伍成员死亡是压力来源）。
const STRESS_ON_ALLY_DEATH := 10

## 压力系统（GDD 2.4）：0~200，正常上限 100。
const STRESS_RESOLVE_THRESHOLD := 100    # 压力达 100 触发精神判定
const STRESS_DEATH_THRESHOLD := 200     # 受难崩溃下压力 >200 立即死亡
const STRESS_VIRTUE_CHANCE := 25        # D100 ≤25 美德，否则受难

## 美德（virtue）列表与效果。
const VIRTUES := ["强化", "专注", "坚定", "暴怒"]
const VIRTUE_STRENGTHEN_STAT_MULT := 0.20   # 强化：全属性 +20%
const VIRTUE_FOCUSED_CRIT_BONUS := 0.30     # 专注：暴击 +30%
const VIRTUE_STEADFAST_RELIEF := 3          # 坚定：每回合 −3 压力
const VIRTUE_ENRAGED_DMG_MULT := 1.5        # 暴怒：伤害 ×1.5

## 受难（affliction）列表与行为。
const AFFLICTIONS := ["偏执", "自弃", "鲁莽", "怯懦", "自虐"]
const AFFLICTION_PARANOID_ALLY_CHANCE := 50 # 偏执：50% 攻击随机队友
const AFFLICTION_SELF_ABUSE_MOVE_STRESS := 2 # 自弃：移动时 +2 压力

## 火把系统（GDD 2.5）：战斗每回合 −1。
const TORCH_DECAY_PER_BATTLE_ROUND := 1

## 战斗事件日志（测试断言用）。
var event_log: Array[Dictionary] = []

var heroes: Array[CombatUnit] = []
var monsters: Array[CombatUnit] = []
var round_num: int = 0
var battle_active: bool = false
var winner: int = -1   # CombatUnit.Team

## 可播种 RNG（复现测试用）。
var rng := RandomNumberGenerator.new()
var _uid_seq: int = 0
## 本回合已做过濒死判定的单位 uid 集合。
var _deathblow_rolled_round: Dictionary = {}

## 脚本化行动计划：{ round: { uid: {skill, target_uid} } }（测试用，覆盖 AI）。
var _script: Dictionary = {}
## 强制掷骰队列（测试用）：非空时依次弹出作为骰子结果。
var _forced_rolls: Array[int] = []
var _current_actor: CombatUnit = null

func _ready() -> void:
	rng.randomize()

# ------------------------------------------------------------------
# 对外接口
# ------------------------------------------------------------------

## 按配置开启一场「英雄 vs 怪物」战斗。
## opts: seed / hero_positions / monster_positions / hero_hp / monster_hp / hero_stress / monster_stress / script
func start_battle(hero_ids: Array, monster_ids: Array, opts: Dictionary = {}) -> Dictionary:
	reset_battle()
	if opts.has("seed"):
		rng.seed = int(opts["seed"])
	var hero_positions: Array = opts.get("hero_positions", [])
	var monster_positions: Array = opts.get("monster_positions", [])
	var hero_hp: Dictionary = opts.get("hero_hp", {})
	var monster_hp: Dictionary = opts.get("monster_hp", {})
	var hero_stress: Dictionary = opts.get("hero_stress", {})
	var monster_stress: Dictionary = opts.get("monster_stress", {})
	_script = opts.get("script", {})

	for i in hero_ids.size():
		_uid_seq += 1
		var pos := i + 1
		if i < hero_positions.size():
			pos = int(hero_positions[i])
		var u := CombatUnit.from_hero(_uid_seq, hero_ids[i], pos)
		if hero_hp.has(hero_ids[i]):
			u.hp = int(hero_hp[hero_ids[i]])
		if hero_stress.has(hero_ids[i]):
			u.stress = int(hero_stress[hero_ids[i]])
		heroes.append(u)
	for i in monster_ids.size():
		_uid_seq += 1
		var pos := i + 1
		if i < monster_positions.size():
			pos = int(monster_positions[i])
		var u := CombatUnit.from_monster(_uid_seq, monster_ids[i], pos)
		if monster_hp.has(monster_ids[i]):
			u.hp = int(monster_hp[monster_ids[i]])
		if monster_stress.has(monster_ids[i]):
			u.stress = int(monster_stress[monster_ids[i]])
		monsters.append(u)

	battle_active = true
	round_num = 0
	winner = -1
	_log("battle_start", {"heroes": hero_ids, "monsters": monster_ids})
	emit_signal("battle_started")
	return get_battle_state()

func reset_battle() -> void:
	heroes.clear()
	monsters.clear()
	event_log.clear()
	_script = {}
	_forced_rolls.clear()
	_uid_seq = 0
	round_num = 0
	battle_active = false
	winner = -1
	_current_actor = null

## 测试用：强制后续骰子结果（依次弹出；耗尽后回退到 rng）。
func debug_force_rolls(rolls: Array) -> void:
	for r in rolls:
		_forced_rolls.append(int(r))

func debug_pending_rolls() -> int:
	return _forced_rolls.size()

## 测试用：为第 round 回合的 uid 单位指定行动。
func script_action(round: int, uid: int, skill_id: String, target_uid: int = -1) -> void:
	if not _script.has(round):
		_script[round] = {}
	_script[round][uid] = {"skill": skill_id, "target_uid": target_uid}

## 回合开始 → 行动顺序 → 依次行动 → 回合结束检查。
func run_round() -> Dictionary:
	if not battle_active:
		return get_battle_state()
	round_num += 1
	emit_signal("round_started", round_num)
	_apply_torch_battle_decay()
	_round_start_effects()
	if not battle_active:
		return get_battle_state()
	for unit in _initiative_order():
		if not battle_active:
			break
		if not unit.alive:
			continue
		_perform_action(unit)
	_check_battle_end()
	_log("round_end", {"round": round_num})
	return get_battle_state()

## 自动战斗直到结束或超过 max_rounds。
func run_battle(max_rounds: int = MAX_ROUNDS) -> Dictionary:
	var guard := 0
	while battle_active and guard < max_rounds:
		run_round()
		guard += 1
	return get_battle_state()

func get_battle_state() -> Dictionary:
	return {
		"round": round_num,
		"active": battle_active,
		"winner": winner,
		"heroes": _unit_snapshots(heroes),
		"monsters": _unit_snapshots(monsters),
	}

func _unit_snapshots(list: Array) -> Array:
	var out: Array = []
	for u in list:
		out.append({
			"uid": u.uid,
			"cfg_id": u.cfg_id,
			"name": u.display_name,
			"team": u.team,
			"position": u.position,
			"hp": u.hp,
			"max_hp": u.max_hp,
			"alive": u.alive,
			"death_struggling": u.death_struggling,
			"stress": u.stress,
			"resolution": u.resolution,
			"crisis": u.crisis,
			"statuses": u.statuses.duplicate(true),
		})
	return out

## 火把系统（GDD 2.5）：战斗每回合 −1（团队共享，走 GameState）。
func _apply_torch_battle_decay() -> void:
	if GameState == null:
		return
	var decay := TORCH_DECAY_PER_BATTLE_ROUND
	var cfg: Dictionary = GameState.get_torch_config()
	if cfg.has("decay_per_battle_round"):
		decay = int(cfg["decay_per_battle_round"])
	GameState.add_torch(-decay)

# ------------------------------------------------------------------
# 回合开始：持续效果 / 状态计时 / 冷却 / 濒死（GDD 2.1）
# ------------------------------------------------------------------

func _round_start_effects() -> void:
	# 本回合内已做过濒死判定的单位（避免 DOT 触发后回合开始再重复判定）
	_deathblow_rolled_round = {}
	for u in _all_units():
		if not u.alive:
			continue
		# 持续伤害（流血/中毒/燃烧）
		var dots: Dictionary = u.tick_dots()
		for status_name in dots:
			_apply_damage(null, u, int(dots[status_name]), false, true)
		# 恐惧：每回合 +2 压力（GDD 2.8）
		if u.has_status("fear"):
			_apply_stress(u, 2)
		# 美德「坚定」：每回合 −3 压力（GDD 2.4）
		if u.resolved and u.resolution == "virtue" and u.crisis == "坚定":
			_apply_stress(u, -VIRTUE_STEADFAST_RELIEF)
		# 时间型状态计时
		u.tick_status_timers()
		# 冷却递减
		u.tick_cooldowns()
	# 火把熄灭（低压氛围）：黑暗档每回合 +1 压力（GDD 2.4 压力来源）
	if GameState != null:
		var tier_stress := int(GameState.get_torch_tier().get("stress_per_round", 0))
		if tier_stress > 0:
			for h in heroes:
				if h.alive:
					_apply_stress(h, tier_stress)
	# 濒死单位每回合 D100 判定（GDD 2.4），本回合已判定过的不再重复
	for u in _all_units():
		if u.alive and u.death_struggling and not _deathblow_rolled_round.has(u.uid):
			_roll_death_struggle(u, "round_start")
	_check_battle_end()

# ------------------------------------------------------------------
# 行动顺序（GDD 2.1）：SPD + D100，从高到低；速度相同玩家方优先
# ------------------------------------------------------------------

func _initiative_order() -> Array:
	var list: Array = []
	for u in _all_units():
		if u.alive:
			list.append({"unit": u, "init": u.spd + _roll(1, 100)})
	list.sort_custom(func(a, b):
		if a["init"] != b["init"]:
			return a["init"] > b["init"]
		if a["unit"].is_hero != b["unit"].is_hero:
			return a["unit"].is_hero
		return a["unit"].uid < b["unit"].uid)
	return list.map(func(e): return e["unit"])

# ------------------------------------------------------------------
# 单单位行动
# ------------------------------------------------------------------

func _perform_action(unit: CombatUnit) -> void:
	# 濒死单位（0 HP 临死挣扎中）无法行动（GDD 2.4）
	if unit.death_struggling:
		_log("skip_deathblow", {"unit": unit.uid})
		return
	# 失位惩罚 / 眩晕：跳过行动（GDD 2.7 / 2.8）
	if unit.displaced_skip_round > 0 and round_num >= unit.displaced_skip_round:
		unit.displaced_skip_round = 0
		_log("skip_displaced", {"unit": unit.uid})
		return
	if unit.has_status("stun"):
		unit.remove_status("stun")
		_log("skip_stun", {"unit": unit.uid})
		return

	_current_actor = unit
	var choice := _choose_action(unit)
	if choice.is_empty():
		_log("skip_no_skill", {"unit": unit.uid})
		_current_actor = null
		return
	_resolve_skill(unit, choice)
	_current_actor = null

## 选择行动：脚本优先，否则受难行为覆盖，否则 AI。
func _choose_action(unit: CombatUnit) -> Dictionary:
	var plan: Dictionary = _script.get(round_num, {}).get(unit.uid, {})
	if not plan.is_empty():
		return {"skill_id": plan.get("skill", ""), "target_uid": int(plan.get("target_uid", -1))}
	if unit.is_hero:
		if unit.resolution == "affliction":
			var crisis_choice := _crisis_choice(unit)
			if not crisis_choice.is_empty():
				_log("crisis_action", {"unit": unit.uid, "crisis": unit.crisis, "skill": crisis_choice.get("skill_id", ""), "target_uid": int(crisis_choice.get("target_uid", -1))})
				return crisis_choice
		return _hero_ai_choice(unit)
	return _monster_ai_choice(unit)

## 受难崩溃状态行为（GDD 2.4）：
##   偏执：50% 攻击随机队友，否则空放；自弃：正常行动（不可治疗/移动施压单独处理）；
##   鲁莽：强制攻击最前排；怯懦：不攻击（空放）；自虐：攻击自身。
func _crisis_choice(unit: CombatUnit) -> Dictionary:
	# 空放：skill_id 为空串，_resolve_skill 会直接跳过本次行动
	var waste := {"skill_id": "", "target_uid": -1}
	match unit.crisis:
		"偏执":
			if _roll(1, 100) <= AFFLICTION_PARANOID_ALLY_CHANCE:
				var allies: Array = _team_units(unit.team).filter(func(a): return a.alive and a.uid != unit.uid)
				if allies.is_empty():
					return waste
				var target: CombatUnit = allies[_roll(0, allies.size() - 1)]
				var skill_id := _pick_crisis_skill(unit, target.position)
				if skill_id != "":
					return {"skill_id": skill_id, "target_uid": target.uid}
			return waste
		"鲁莽":
			var front := _frontmost_opponent(unit)
			if front == null:
				return waste
			var skill_id := _pick_crisis_skill(unit, front.position)
			if skill_id != "":
				return {"skill_id": skill_id, "target_uid": front.uid}
			return waste
		"自虐":
			var skill_id := _pick_crisis_skill(unit, unit.position)
			if skill_id != "":
				return {"skill_id": skill_id, "target_uid": unit.uid}
			return waste
		"怯懦":
			return waste
		_:
			return {}  # 自弃：正常行动

## 受难行为选技能：优先伤害类且能命中指定站位；无则返回空。
func _pick_crisis_skill(unit: CombatUnit, target_pos: int) -> String:
	var fallback := ""
	for skill_id: String in unit.skills.keys():
		if not unit.can_use_from_position(skill_id) or not unit.is_skill_ready(skill_id):
			continue
		var skill: Dictionary = unit.skills[skill_id]
		if not (target_pos in skill.get("target_pos", [1, 2, 3, 4])):
			continue
		if skill.get("type", "damage") == "damage":
			return skill_id
		if fallback == "":
			fallback = skill_id
	return fallback

## 敌方最前排（位置号最小）存活单位。
func _frontmost_opponent(unit: CombatUnit) -> CombatUnit:
	var best: CombatUnit = null
	for u in _opponents(unit):
		if u.alive and (best == null or u.position < best.position):
			best = u
	return best

# ------------------------------------------------------------------
# 技能结算
# ------------------------------------------------------------------

func _resolve_skill(actor: CombatUnit, choice: Dictionary) -> void:
	var skill_id: String = choice.get("skill_id", "")
	var skill: Dictionary = actor.skills.get(skill_id, {})
	if skill.is_empty():
		return
	# 技能可用性：站位 / 冷却
	if not actor.can_use_from_position(skill_id) or not actor.is_skill_ready(skill_id):
		_log("skill_unavailable", {"unit": actor.uid, "skill": skill_id})
		return
	# 消耗（cost）
	var cost: Dictionary = skill.get("cost", {})
	if int(cost.get("stress", 0)) > 0:
		_apply_stress(actor, int(cost["stress"]))
		# 施压消耗可能触发精神判定/压力死亡，若已死亡则不再结算本次行动
		if not actor.alive:
			return

	var targets: Array = _select_targets(actor, skill, int(choice.get("target_uid", -1)))
	if targets.is_empty():
		_log("skill_no_target", {"unit": actor.uid, "skill": skill_id})
		return

	# 冷却开始计算：cooldown=N 表示 N 个回合不可用（回合开始时 -1）
	var cd := int(skill.get("cooldown", 0))
	actor.set_cooldown(skill_id, cd + 1)

	emit_signal("unit_acted", actor, skill_id)
	_log("skill_used", {"unit": actor.uid, "skill": skill_id, "targets": targets.map(func(u): return u.uid)})

	# 迷惑：行动时 30% 概率攻击随机目标（GDD 2.8）
	if actor.has_status("confuse") and _roll(1, 100) <= 30:
		targets = [_pick_random_opponent(actor)]

	for target in targets:
		if not target.alive:
			continue
		_resolve_skill_vs_target(actor, skill, target)

## 目标选择：AOE 打全部存活敌方；target_pos=[0] 为自身；否则单目标（脚本指定或 AI）。
func _select_targets(actor: CombatUnit, skill: Dictionary, script_target_uid: int) -> Array:
	var is_aoe := false
	for e in skill.get("effects", []):
		if e.get("status", "") == "aoe":
			is_aoe = true
			break
	if is_aoe:
		var list: Array = []
		for u in _opponents(actor):
			if u.alive:
				list.append(u)
		return list
	var tpos: Array = skill.get("target_pos", [1, 2, 3, 4])
	if tpos == [0]:
		return [actor]
	var target: CombatUnit = null
	if script_target_uid >= 0:
		target = find_unit(script_target_uid)
	if target == null or not target.alive or not (target.position in tpos):
		target = _ai_pick_target(actor, skill)
	if target == null:
		return []
	return [target]

func _resolve_skill_vs_target(actor: CombatUnit, skill: Dictionary, target: CombatUnit) -> void:
	# 守护：目标相邻队友有 guard 时，攻击转移到守护者（GDD 2.8）
	var guarder := _find_adjacent_guard(target)
	if guarder != null:
		_log("guard_redirect", {"target": target.uid, "guarder": guarder.uid})
		target = guarder

	var hit_result := _roll_hit(actor, target, skill)
	_log("hit_roll", {"attacker": actor.uid, "target": target.uid, "chance": hit_result["hit_chance"], "hit": hit_result["hit"], "crit": hit_result["crit"]})

	if not hit_result["hit"]:
		emit_signal("damage_dealt", actor, target, 0, false)
		return

	# 按类型结算
	var stype: String = skill.get("type", "damage")
	match stype:
		"damage":
			var is_crit: bool = hit_result["crit"]
			var dmg_roll := _roll(actor.dmg_min, actor.dmg_max)
			var prot := target.prot
			# 虚弱：造成伤害 −25%；狂暴：+40%；目标虚弱/诅咒额外受伤害
			var dmg_mult := float(skill.get("dmg_mult", 1.0))
			# 暴怒美德：伤害 ×1.5（GDD 2.4）
			if actor.resolution == "virtue" and actor.crisis == "暴怒":
				dmg_mult *= VIRTUE_ENRAGED_DMG_MULT
			var vuln_mult := 1.0
			if target.has_status("vulnerable"):
				vuln_mult += float(target.get_status("vulnerable").get("value", 0.0))
			var dmg := BattleRules.compute_damage(dmg_roll, prot, dmg_mult, 1.5 if is_crit else 1.0, vuln_mult)
			_apply_damage(actor, target, dmg, is_crit)
			if is_crit:
				_apply_stress(target, _roll(1, 3))
				# 暴击减压：施法者 −2~−4 压力（GDD 2.4 减压来源）
				_apply_stress(actor, -_roll(2, 4))
		"heal":
			var dmg_roll := _roll(actor.dmg_min, actor.dmg_max)
			var heal := BattleRules.compute_heal(dmg_roll, float(skill.get("dmg_mult", 0.5)))
			if _can_be_healed(target):
				target.heal(heal)
				_log("heal", {"target": target.uid, "amount": heal})
			else:
				_log("heal_blocked", {"target": target.uid, "crisis": target.crisis})
		"stress_damage":
			var v := int(_effect_value(skill, "stress_damage", 0))
			# 恐惧：对施压技能伤害 +50%（GDD 2.8）
			if target.has_status("fear"):
				v = int(round(v * 1.5))
			_apply_stress(target, v)
		"stress_heal":
			var v := int(_effect_value(skill, "stress_heal", 0))
			_apply_stress(target, -v)
		"movement":
			var dist := int(_effect_value(skill, "move", 1))
			_move_self(actor, dist)
		_:
			pass  # buff/debuff/special/summon 等仅走 effects

	# 附加效果
	_apply_effects(actor, skill, target)

## 命中判定（GDD 2.3）：基准命中 + 施法者ACC − 目标DODGE − 位置惩罚。
## 致盲 −20 命中；狂暴命中 −15%；标记目标受击命中 +20%。
func _roll_hit(attacker: CombatUnit, target: CombatUnit, skill: Dictionary) -> Dictionary:
	var base_acc := int(skill.get("base_acc", 80))
	var acc := attacker.acc
	if attacker.has_status("blind"):
		acc -= 20
	if attacker.has_status("berserk"):
		acc -= int(float(attacker.get_status("berserk").get("acc_down", 0.15)) * 100.0)
	var dodge := target.dodge
	var chance := BattleRules.hit_chance(base_acc, acc, dodge, 0)
	if target.has_status("mark"):
		var mark := target.get_status("mark")
		var bonus := float(mark.get("acc_bonus", 0.2))
		chance += int(bonus * 100.0)
	chance = clampi(chance, 5, 95)
	var hit := _roll(1, 100) <= chance
	var crit := false
	# 仅伤害类技能掷暴击（GDD 2.3：命中掷出暴击时 ×1.5）
	if hit and skill.get("type", "damage") == "damage":
		var crit_chance := (attacker.crit + float(skill.get("crit_bonus", 0.0))) * 100.0
		# 火把档位暴击修正（GDD 2.5：明亮 +5 / 黑暗 −10）
		if GameState != null:
			crit_chance += float(GameState.get_torch_tier().get("crit_bonus", 0))
		if _roll(1, 100) <= int(crit_chance):
			crit = true
	return {"hit": hit, "crit": crit, "hit_chance": chance}

## 附加效果（状态 / 位移 / 召唤 / 治疗 / 净化等）。
## 治疗/压力类已在 type 分支结算，此处跳过对应项避免重复。
func _apply_effects(actor: CombatUnit, skill: Dictionary, target: CombatUnit) -> void:
	var stype: String = skill.get("type", "damage")
	for e in skill.get("effects", []):
		var status_name: String = e.get("status", "")
		match status_name:
			"aoe":
				pass  # 目标选择已处理
			"heal":
				if stype != "heal":
					var dmg_roll := _roll(actor.dmg_min, actor.dmg_max)
					var heal := BattleRules.compute_heal(dmg_roll, float(e.get("mult", 0.5)))
					if _can_be_healed(target):
						target.heal(heal)
						_log("heal", {"target": target.uid, "amount": heal})
					else:
						_log("heal_blocked", {"target": target.uid, "crisis": target.crisis})
			"stress_damage":
				if stype != "stress_damage":
					var v := int(e.get("value", 0))
					if target.has_status("fear"):
						v = int(round(v * 1.5))
					_apply_stress(target, v)
			"stress_heal":
				if stype != "stress_heal":
					_apply_stress(target, -int(e.get("value", 0)))
			"bleed", "poison", "burn":
				if _effect_procs(e):
					target.apply_status(status_name, float(e.get("value", 0)), int(e.get("duration", 3)), actor.uid)
					emit_signal("status_applied", target, status_name, int(e.get("duration", 3)))
			"stun", "mark", "fear", "weak", "blind", "guard", "berserk", "confuse":
				if _effect_procs(e):
					target.apply_status(status_name, float(e.get("value", 0)), int(e.get("duration", 1)), actor.uid, _status_extra(e))
					emit_signal("status_applied", target, status_name, int(e.get("duration", 1)))
			"prot_up", "dodge_up", "vulnerable", "slow", "immune_displacement":
				if _effect_procs(e):
					target.apply_status(status_name, float(e.get("value", 0)), int(e.get("duration", 2)), actor.uid, _status_extra(e))
					emit_signal("status_applied", target, status_name, int(e.get("duration", 2)))
			"push":
				_displace(target, 1, int(e.get("distance", 1)))
			"pull":
				_displace(target, -1, int(e.get("distance", 1)))
			"move":
				if stype != "movement":
					_move_self(actor, int(e.get("distance", 1)))
			"cure":
				for rm in e.get("statuses", []):
					target.remove_status(rm)
			"summon":
				_summon(actor.team, e.get("unit", ""), int(e.get("count", 1)))
			_:
				push_warning("[TurnManager] 未识别的效果: %s" % status_name)

func _effect_procs(e: Dictionary) -> bool:
	if not e.has("chance"):
		return true
	return _roll(1, 100) <= int(float(e["chance"]) * 100.0)

func _status_extra(e: Dictionary) -> Dictionary:
	var extra := {}
	for key in ["acc_bonus", "dmg_up", "acc_down"]:
		if e.has(key):
			extra[key] = e[key]
	return extra

func _effect_value(skill: Dictionary, status_name: String, default: float) -> float:
	for e in skill.get("effects", []):
		if e.get("status", "") == status_name:
			return float(e.get("value", default))
	return default

# ------------------------------------------------------------------
# 伤害 / 濒死 / 死亡
# ------------------------------------------------------------------

func _apply_damage(attacker: CombatUnit, target: CombatUnit, amount: int, is_crit: bool = false, is_dot: bool = false) -> void:
	if not target.alive or amount <= 0:
		return
	target.take_damage(amount)
	emit_signal("damage_dealt", attacker, target, amount, is_crit)
	_log("damage", {"attacker": attacker.uid if attacker else -1, "target": target.uid, "amount": amount, "crit": is_crit, "dot": is_dot, "hp_left": target.hp})
	if target.hp <= 0 and target.alive:
		_roll_death_struggle(target, "dot" if is_dot else "hit")

## 濒死判定（GDD 2.4 / 2.9）：D100 ≤50 稳定保命，否则死亡。
## 受击（含 DOT）时触发再次判定；回合开始由 _round_start_effects 统一判定。
func _roll_death_struggle(unit: CombatUnit, reason: String) -> void:
	if not unit.alive:
		return
	_deathblow_rolled_round[unit.uid] = true
	unit.death_struggling = true
	var roll := _roll(1, 100)
	if BattleRules.deathblow_stable(roll):
		_log("deathblow_stable", {"unit": unit.uid, "roll": roll})
	else:
		_log("deathblow_fail", {"unit": unit.uid, "roll": roll})
		_kill_unit(unit, "deathblow")

func _kill_unit(unit: CombatUnit, cause: String) -> void:
	if not unit.alive:
		return
	unit.alive = false
	unit.death_struggling = false
	unit.statuses.clear()
	unit.cooldowns.clear()
	emit_signal("unit_died", unit)
	_log("unit_died", {"unit": unit.uid, "cause": cause})
	# 队友死亡压力（仅英雄）
	if unit.is_hero:
		for h in heroes:
			if h.alive:
				_apply_stress(h, STRESS_ON_ALLY_DEATH)
	# 空缺自动前移（GDD 2.1）
	_compact_team(unit.team)
	_check_battle_end()

## 空缺自动前移：存活单位按站位重排到 1..N。
func _compact_team(team: int) -> void:
	var list: Array = []
	for u in _team_units(team):
		if u.alive:
			list.append(u)
	list.sort_custom(func(a, b): return a.position < b.position)
	for i in list.size():
		list[i].position = i + 1

# ------------------------------------------------------------------
# 位移（GDD 2.7）
# ------------------------------------------------------------------

## 击退（dir=1，向后） / 拉拽（dir=-1，向前）。成功位移 → 失位惩罚（下回合跳过行动）。
## 撞墙（击退至 4 号位边界）→ 额外 1~3 点地形伤害。
## 目标位被占时链条位移：先把占据者推出/拉走，腾出位置再移动本目标。
## 返回该单位是否成功移动。
func _displace(target: CombatUnit, dir: int, distance: int) -> bool:
	if not target.alive:
		return false
	if target.has_status("immune_displacement"):
		_log("displace_immune", {"unit": target.uid})
		return false
	var dest := target.position + dir * distance
	if dest > TEAM_SLOTS:
		var wall_dmg := _roll(1, 3)
		_log("displace_wall", {"unit": target.uid, "dmg": wall_dmg})
		_apply_damage(_current_actor, target, wall_dmg, false, true)
		return false
	if dest < 1:
		return false
	var occupant := _unit_at(target.team, dest)
	if occupant == null:
		_do_move(target, dest, dir)
		return true
	# 链条位移：先把占据者推出/拉走
	if _displace(occupant, dir, distance):
		if _unit_at(target.team, dest) == null:
			_do_move(target, dest, dir)
			return true
	return false

func _do_move(unit: CombatUnit, dest: int, dir: int) -> void:
	unit.position = dest
	# 失位惩罚：下回合（round_num+1）起跳过行动（GDD 2.7）
	unit.displaced_skip_round = round_num + 1
	_log("displace", {"unit": unit.uid, "to": dest, "dir": dir})
	# 自弃受难：移动时承受压力（GDD 2.4）
	if unit.resolution == "affliction" and unit.crisis == "自弃":
		_apply_stress(unit, AFFLICTION_SELF_ABUSE_MOVE_STRESS)

## 自身移动技能（movement）：向前移动 distance 格，受阻则向后；不产生失位惩罚。
func _move_self(unit: CombatUnit, distance: int) -> void:
	var dest := unit.position - distance
	if dest < 1:
		dest = unit.position + distance
	if dest > TEAM_SLOTS:
		dest = unit.position - distance
	if dest < 1 or dest > TEAM_SLOTS:
		return
	if _unit_at(unit.team, dest) != null:
		return
	unit.position = dest
	_log("move_self", {"unit": unit.uid, "to": dest})
	# 自弃受难：移动时承受压力（GDD 2.4）
	if unit.resolution == "affliction" and unit.crisis == "自弃":
		_apply_stress(unit, AFFLICTION_SELF_ABUSE_MOVE_STRESS)

# ------------------------------------------------------------------
# AI（简单规则；正式战斗交互由 WS-8 UI 提供）
# ------------------------------------------------------------------

func _hero_ai_choice(unit: CombatUnit) -> Dictionary:
	for skill_id in unit.skills.keys():
		if not unit.can_use_from_position(skill_id) or not unit.is_skill_ready(skill_id):
			continue
		var skill: Dictionary = unit.skills[skill_id]
		var stype: String = skill.get("type", "damage")
		var tpos: Array = skill.get("target_pos", [1, 2, 3, 4])
		if stype in ["heal", "stress_heal"]:
			var ally := _pick_ally_target(unit, skill)
			if ally != null:
				return {"skill_id": skill_id, "target_uid": ally.uid}
			continue
		if stype == "buff" and tpos == [0]:
			return {"skill_id": skill_id, "target_uid": unit.uid}
		if tpos == [0]:
			return {"skill_id": skill_id, "target_uid": unit.uid}
		var target := _ai_pick_target(unit, skill)
		if target != null:
			return {"skill_id": skill_id, "target_uid": target.uid}
	return {}

func _monster_ai_choice(unit: CombatUnit) -> Dictionary:
	for skill_id in unit.skills.keys():
		if not unit.can_use_from_position(skill_id) or not unit.is_skill_ready(skill_id):
			continue
		var skill: Dictionary = unit.skills[skill_id]
		if skill.get("target_pos", []) == [0]:
			return {"skill_id": skill_id, "target_uid": unit.uid}
		var target := _monster_pick_target(unit, skill)
		if target != null:
			return {"skill_id": skill_id, "target_uid": target.uid}
	return {}

func _ai_pick_target(actor: CombatUnit, skill: Dictionary) -> CombatUnit:
	var tpos: Array = skill.get("target_pos", [1, 2, 3, 4])
	var best: CombatUnit = null
	for u in _opponents(actor):
		if u.alive and (u.position in tpos):
			if best == null or u.position < best.position:
				best = u
	return best

func _monster_pick_target(mon: CombatUnit, skill: Dictionary) -> CombatUnit:
	var priority: Array = ConfigManager.get_entry("monsters", mon.cfg_id).get("ai", {}).get("priority", ["front_most"])
	var tpos: Array = skill.get("target_pos", [1, 2, 3, 4])
	var candidates: Array = []
	for h in heroes:
		if h.alive and (h.position in tpos):
			candidates.append(h)
	if candidates.is_empty():
		return null
	var first: String = priority[0]
	match first:
		"lowest_hp":
			candidates.sort_custom(func(a, b): return a.hp < b.hp)
		"back_most":
			candidates.sort_custom(func(a, b): return a.position > b.position)
		"highest_stress":
			candidates.sort_custom(func(a, b): return a.stress > b.stress)
		"random_hero":
			return candidates[_roll(0, candidates.size() - 1)]
		_:
			candidates.sort_custom(func(a, b): return a.position < b.position)
	return candidates[0]

func _pick_ally_target(actor: CombatUnit, skill: Dictionary) -> CombatUnit:
	var tpos: Array = skill.get("target_pos", [1, 2, 3, 4])
	var stype: String = skill.get("type", "heal")
	var best: CombatUnit = null
	for u in _team_units(actor.team):
		if not u.alive or not (u.position in tpos):
			continue
		if stype == "stress_heal":
			if best == null or u.stress > best.stress:
				best = u
		else:
			if not _can_be_healed(u):
				continue
			if u.hp >= u.max_hp:
				continue
			if best == null or float(u.hp) / float(u.max_hp) < float(best.hp) / float(best.max_hp):
				best = u
	return best

# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

func _roll(min_val: int, max_val: int) -> int:
	if _forced_rolls.size() > 0:
		var v: int = _forced_rolls.pop_front()
		return clampi(v, min_val, max_val)
	return rng.randi_range(min_val, max_val)

## 压力结算（GDD 2.4）：
##   - 0~200 区间；未判定英雄以 100 为正常上限（达 100 即触发精神判定）。
##   - 已受难（崩溃）英雄压力 >200 → 立即死亡。
##   - 美德英雄不因压力死亡，压力在 0~200 内累积。
func _apply_stress(unit: CombatUnit, amount: int) -> void:
	if unit == null or not unit.alive:
		return
	var new_stress := unit.stress + amount
	# 已受难崩溃且压力 >200 → 立即死亡（GDD 2.4）
	if unit.resolved and unit.resolution == "affliction" and new_stress > STRESS_DEATH_THRESHOLD:
		unit.stress = STRESS_DEATH_THRESHOLD
		_log("stress", {"unit": unit.uid, "delta": amount, "total": unit.stress})
		_log("stress_death", {"unit": unit.uid})
		_kill_unit(unit, "stress_death")
		return
	# 未判定英雄：正常上限 100，达到即触发精神判定（仅一次）
	if unit.is_hero and not unit.resolved:
		unit.stress = clampi(new_stress, 0, STRESS_RESOLVE_THRESHOLD)
		_log("stress", {"unit": unit.uid, "delta": amount, "total": unit.stress})
		if unit.stress >= STRESS_RESOLVE_THRESHOLD:
			_resolve_mental(unit)
		return
	unit.stress = clampi(new_stress, 0, unit.max_stress)
	_log("stress", {"unit": unit.uid, "delta": amount, "total": unit.stress})

## 精神判定（GDD 2.4）：D100 ≤25 → 美德，否则受难崩溃；分支随机。
func _resolve_mental(unit: CombatUnit) -> void:
	if unit == null or not unit.is_hero or unit.resolved:
		return
	unit.resolved = true
	var roll := _roll(1, 100)
	if roll <= STRESS_VIRTUE_CHANCE:
		unit.resolution = "virtue"
		unit.crisis = VIRTUES[_roll(0, VIRTUES.size() - 1)]
		_apply_virtue_effect(unit)
	else:
		unit.resolution = "affliction"
		unit.crisis = AFFLICTIONS[_roll(0, AFFLICTIONS.size() - 1)]
		_log("crisis", {"unit": unit.uid, "crisis": unit.crisis})
	_log("mental_resolve", {"unit": unit.uid, "roll": roll, "resolution": unit.resolution, "crisis": unit.crisis})

## 应用美德效果（GDD 2.4）。
func _apply_virtue_effect(unit: CombatUnit) -> void:
	match unit.crisis:
		"强化":
			unit.max_hp = maxi(1, roundi(unit.max_hp * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT)))
			unit.spd = roundi(unit.spd * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT))
			unit.acc = roundi(unit.acc * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT))
			unit.dodge = roundi(unit.dodge * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT))
			unit.crit = clampf(unit.crit * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT), 0.0, 0.4)
			unit.dmg_min = roundi(unit.dmg_min * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT))
			unit.dmg_max = roundi(unit.dmg_max * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT))
			unit.prot = clampf(unit.prot * (1.0 + VIRTUE_STRENGTHEN_STAT_MULT), 0.0, 0.8)
			unit.hp = mini(unit.hp, unit.max_hp)
		"专注":
			unit.crit = clampf(unit.crit + VIRTUE_FOCUSED_CRIT_BONUS, 0.0, 0.4)
		"坚定":
			pass  # 每回合 −3 压力在 _round_start_effects 处理
		"暴怒":
			pass  # 伤害 ×1.5 与不可治疗在结算处处理

## 该单位是否可被治疗（GDD 2.4：暴怒/自弃不可被治疗）。
func _can_be_healed(unit: CombatUnit) -> bool:
	if unit == null or not unit.alive:
		return false
	return not (unit.resolution == "virtue" and unit.crisis == "暴怒") \
		and not (unit.resolution == "affliction" and unit.crisis == "自弃")

func _all_units() -> Array:
	var out: Array = []
	out.append_array(heroes)
	out.append_array(monsters)
	return out

func _team_units(team: int) -> Array:
	return heroes if team == CombatUnit.Team.HEROES else monsters

func _opponents(unit: CombatUnit) -> Array:
	return _team_units(CombatUnit.Team.HEROES if unit.team == CombatUnit.Team.MONSTERS else CombatUnit.Team.MONSTERS)

func _unit_at(team: int, pos: int) -> CombatUnit:
	for u in _team_units(team):
		if u.alive and u.position == pos:
			return u
	return null

## 按 uid 查找单位（英雄或怪物），不存在返回 null。
func find_unit(uid: int) -> CombatUnit:
	for u in _all_units():
		if u.uid == uid:
			return u
	return null

## 守护：寻找 target 相邻（position±1）且带 guard 状态的队友。
func _find_adjacent_guard(target: CombatUnit) -> CombatUnit:
	for u in _team_units(target.team):
		if not u.alive or u == target:
			continue
		if u.has_status("guard") and absi(u.position - target.position) == 1:
			return u
	return null

func _pick_random_opponent(actor: CombatUnit) -> CombatUnit:
	var opp := _opponents(actor).filter(func(u): return u.alive)
	if opp.is_empty():
		return null
	return opp[_roll(0, opp.size() - 1)]

## 召唤（GDD 2.6 summon）：在己方后排空位生成配置中的怪物。
func _summon(team: int, monster_id: String, count: int) -> void:
	if monster_id == "" or count <= 0:
		return
	if not ConfigManager.has_entry("monsters", monster_id):
		push_warning("[TurnManager] 召唤目标不存在: %s" % monster_id)
		return
	var team_units: Array = _team_units(team)
	for i in count:
		if team_units.filter(func(u): return u.alive).size() >= TEAM_SLOTS:
			break
		var pos := TEAM_SLOTS
		while _unit_at(team, pos) != null and pos > 1:
			pos -= 1
		if _unit_at(team, pos) != null:
			break
		_uid_seq += 1
		var u := CombatUnit.from_monster(_uid_seq, monster_id, pos)
		team_units.append(u)
		_log("summon", {"monster": monster_id, "pos": pos})

func _check_battle_end() -> void:
	if not battle_active:
		return
	var heroes_alive := 0
	for h in heroes:
		if h.alive:
			heroes_alive += 1
	var mons_alive := 0
	for m in monsters:
		if m.alive:
			mons_alive += 1
	if heroes_alive == 0 or mons_alive == 0:
		battle_active = false
		winner = CombatUnit.Team.MONSTERS if heroes_alive == 0 else CombatUnit.Team.HEROES
		emit_signal("battle_ended", winner)
		_log("battle_end", {"winner": winner})

func _log(type: String, data: Dictionary) -> void:
	var entry := {"type": type, "round": round_num}
	for k in data:
		entry[k] = data[k]
	event_log.append(entry)
