class_name CombatUnit
extends RefCounted
## 战斗单位（英雄或怪物）：属性、站位、技能、冷却、状态。
##
## 由 TurnManager 从 heroes.json / monsters.json + skills.json 构建，
## 运行期数值全部在实例上（hp、stress、position、statuses、cooldowns），
## 不修改 ConfigManager 的只读缓存。

enum Team { HEROES, MONSTERS }

## 单位唯一 id（同队内唯一；TurnManager 分配）。
var uid: int = 0
## 配置 id（heroes.json / monsters.json 的 key）。
var cfg_id: String = ""
var display_name: String = ""
var team: int = Team.HEROES
var is_hero: bool = false

# ---- 基础属性（来自 base_stats）----
var max_hp: int = 1
var hp: int = 1
var spd: int = 0
var acc: int = 0
var dodge: int = 0
var crit: float = 0.0          # 暴击率（0~1）
var dmg_min: int = 0
var dmg_max: int = 0
var prot: float = 0.0          # 护甲（0~0.8）
var stress: int = 0
var max_stress: int = 200
## 是否已触发「精神判定」（压力到 100 一次，GDD 2.4）。
var resolved: bool = false
## 精神判定结果："virtue" 美德 / "affliction" 受难崩溃。
var resolution: String = ""
## 具体美德/受难名（强化/专注/坚定/暴怒 或 偏执/自弃/鲁莽/怯懦/自虐）。
var crisis: String = ""

# ---- 战斗状态 ----
## 站位 1~4（1 为最前排）。
var position: int = 0
var alive: bool = true
## 濒死挣扎中（0 HP，每回合 D100 判定）。
var death_struggling: bool = false
## 本回合被位移（击退/拉拽）后，该回合之后的下一回合跳过行动（GDD 2.7）。
## 存储应跳过的回合号（0 = 无惩罚）；由 TurnManager 在 _do_move 时写 round_num+1。
var displaced_skip_round: int = 0
## 已行动（供回合循环判断）。
var acted: bool = false

## skill_id -> 技能配置（已标准化）。
var skills: Dictionary = {}
## skill_id -> 剩余冷却回合数（>0 表示不可用）。
var cooldowns: Dictionary = {}
## 状态效果列表：{ status: String, value: float, duration: int, source_uid: int, ... }
var statuses: Array[Dictionary] = []

## 可被施加的状态名（GDD 2.8 核心 11 种 + 其他）。
const STATUS_NAMES := ["bleed", "poison", "burn", "stun", "mark", "fear", "weak", "blind", "guard", "berserk", "confuse"]

func _init(p_uid: int, p_cfg_id: String, p_team: int, p_is_hero: bool, p_pos: int) -> void:
	uid = p_uid
	cfg_id = p_cfg_id
	team = p_team
	is_hero = p_is_hero
	position = p_pos

## 从 heroes.json 构建英雄（技能引用 skills.json）。
static func from_hero(uid: int, hero_id: String, pos: int) -> CombatUnit:
	var cfg := ConfigManager.get_entry("heroes", hero_id)
	var u := CombatUnit.new(uid, hero_id, Team.HEROES, true, pos)
	u.display_name = cfg.get("name", hero_id)
	u._apply_base_stats(cfg.get("base_stats", {}))
	for skill_id: String in cfg.get("skill_ids", []):
		var sk := ConfigManager.get_entry("skills", skill_id)
		if not sk.is_empty():
			u.skills[skill_id] = _normalize_skill(sk)
	return u

## 从 monsters.json 构建怪物（内联技能，source_pos 默认全站位可用）。
static func from_monster(uid: int, monster_id: String, pos: int) -> CombatUnit:
	var cfg := ConfigManager.get_entry("monsters", monster_id)
	var u := CombatUnit.new(uid, monster_id, Team.MONSTERS, false, pos)
	u.display_name = cfg.get("name", monster_id)
	u._apply_base_stats(cfg.get("base_stats", {}))
	var ai: Dictionary = cfg.get("ai", {})
	var skill_cd: Dictionary = ai.get("skill_cooldown", {})
	for sk in cfg.get("skills", []):
		var sk_dict: Dictionary = sk.duplicate()
		if not sk_dict.has("source_pos"):
			sk_dict["source_pos"] = [1, 2, 3, 4]
		if not sk_dict.has("dmg_mult"):
			sk_dict["dmg_mult"] = 1.0
		if not sk_dict.has("crit_bonus"):
			sk_dict["crit_bonus"] = 0.0
		if not sk_dict.has("cooldown"):
			sk_dict["cooldown"] = int(skill_cd.get(sk_dict.get("id", ""), 0))
		if not sk_dict.has("cost"):
			sk_dict["cost"] = {}
		if not sk_dict.has("effects"):
			sk_dict["effects"] = []
		var sk_id: String = sk_dict.get("id", "")
		if sk_id != "":
			u.skills[sk_id] = _normalize_skill(sk_dict)
	return u

## 技能字段归一化：JSON 数字会解析为 float，站位数组需转 int 保证 in 判断正确。
static func _normalize_skill(skill: Dictionary) -> Dictionary:
	var out := skill.duplicate(true)
	if out.has("source_pos"):
		out["source_pos"] = _to_int_array(out["source_pos"])
	if out.has("target_pos"):
		out["target_pos"] = _to_int_array(out["target_pos"])
	for e in out.get("effects", []):
		var ed: Dictionary = e
		for key in ed.keys():
			if ed[key] is float and is_equal_approx(ed[key], floor(ed[key])):
				ed[key] = int(ed[key])
	return out

static func _to_int_array(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(int(v))
	return out

func _apply_base_stats(bs: Dictionary) -> void:
	max_hp = int(bs.get("hp", 1))
	hp = max_hp
	spd = int(bs.get("spd", 0))
	acc = int(bs.get("acc", 0))
	dodge = int(bs.get("dodge", 0))
	crit = float(bs.get("crit", 0.0))
	dmg_min = int(bs.get("dmg_min", 0))
	dmg_max = int(bs.get("dmg_max", 0))
	prot = float(bs.get("prot", 0.0))
	if bs.has("stress"):
		stress = int(bs["stress"])

# ------------------------------------------------------------------
# 状态效果
# ------------------------------------------------------------------

func has_status(status_name: String) -> bool:
	for s in statuses:
		if s.get("status", "") == status_name:
			return true
	return false

func get_status(status_name: String) -> Dictionary:
	for s in statuses:
		if s.get("status", "") == status_name:
			return s
	return {}

## 施加状态：同名刷新（取更大 duration/value），否则新增。
func apply_status(status_name: String, value: float, duration: int, source_uid: int, extra: Dictionary = {}) -> void:
	if not status_name in STATUS_NAMES and not extra.get("allow_unknown", false):
		return
	var status := {
		"status": status_name,
		"value": value,
		"duration": duration,
		"source_uid": source_uid,
	}
	for k in extra:
		status[k] = extra[k]
	for i in statuses.size():
		if statuses[i].get("status", "") == status_name:
			if int(statuses[i].get("duration", 0)) < duration or float(statuses[i].get("value", 0.0)) < value:
				statuses[i] = status
			return
	statuses.append(status)

func remove_status(status_name: String) -> void:
	for i in range(statuses.size() - 1, -1, -1):
		if statuses[i].get("status", "") == status_name:
			statuses.remove_at(i)

## 回合开始结算持续伤害（GDD 2.1 / 2.3），返回 {status: 伤害值}。
## 燃烧忽略 PROT；其余受 PROT 影响。
func tick_dots() -> Dictionary:
	var result := {}
	for s in statuses.duplicate():
		var name: String = s.get("status", "")
		if name in ["bleed", "poison", "burn"]:
			var ignore_prot := name == "burn"
			var dmg := BattleRules.dot_damage(int(s.get("value", 0)), prot, ignore_prot)
			result[name] = result.get(name, 0) + dmg
	return result

## 回合开始：时间型状态计时（duration -1，到期移除）。
## 流血/中毒/燃烧在 tick_dots 结算伤害后递减。
func tick_status_timers() -> void:
	for i in range(statuses.size() - 1, -1, -1):
		var s: Dictionary = statuses[i]
		var name: String = s.get("status", "")
		if name in ["bleed", "poison", "burn", "stun", "mark", "fear", "weak", "blind", "guard", "berserk", "confuse"]:
			s["duration"] = int(s["duration"]) - 1
			if int(s["duration"]) <= 0:
				statuses.remove_at(i)

# ------------------------------------------------------------------
# 冷却
# ------------------------------------------------------------------

## 回合开始：所有冷却 -1。
func tick_cooldowns() -> void:
	for skill_id in cooldowns.keys():
		cooldowns[skill_id] = int(cooldowns[skill_id]) - 1
		if int(cooldowns[skill_id]) <= 0:
			cooldowns.erase(skill_id)

func is_skill_ready(skill_id: String) -> bool:
	return not cooldowns.has(skill_id)

func set_cooldown(skill_id: String, turns: int) -> void:
	if turns > 0:
		cooldowns[skill_id] = turns

## 技能从当前站位是否可用（GDD 2.1：技能可用性取决于己方站位）。
func can_use_from_position(skill_id: String) -> bool:
	var skill: Dictionary = skills.get(skill_id, {})
	if skill.is_empty():
		return false
	var source_pos: Array = skill.get("source_pos", [1, 2, 3, 4])
	return position in source_pos

## 目标是否在技能目标站位内。
func is_in_target_pos(skill_id: String, target_pos: int) -> bool:
	var skill: Dictionary = skills.get(skill_id, {})
	if skill.is_empty():
		return false
	var target_pos_list: Array = skill.get("target_pos", [1, 2, 3, 4])
	return target_pos in target_pos_list

## 本次战斗累计受到的伤害（战斗结束写回任务累计 run_damage，GDD 3.5）。
var damage_taken: int = 0

func take_damage(amount: int) -> void:
	hp = maxi(hp - amount, 0)
	damage_taken += amount

func heal(amount: int) -> void:
	if not alive:
		return
	hp = mini(hp + amount, max_hp)
	if hp > 0 and death_struggling:
		death_struggling = false
