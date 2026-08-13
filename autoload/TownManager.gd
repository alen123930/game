extends Node
## 城镇经营系统核心（GDD 第三章）
##
## 职责：
##   1. 资源管理：金币 / 传承物（statue/scroll/badge/tablet）/ 补给品库存 / 饰品仓库
##   2. 建筑：8 栋各 3 级，升级消耗传承物（buildings.json），等级门控功能上限
##   3. 招募：每日候选 4~8 名、稀有度（白/蓝/紫/金）与费用、2~4 怪癖
##   4. 养成：经验升级、技能装备与训练场升级、武器/护甲 5 级、饰品 2 槽
##   5. 治疗/减压：诊疗室（伤病/疾病）、教堂/酒馆（减压）、派遣休息、补给商店
##   6. 结算衔接：settle_run 把任务收益/经验/伤病写回城镇
##
## 全部数值来自 ConfigManager（只读），随机性由 rng（可播种）控制保证测试可复现。

const BUILDING_IDS := [
	"recruitment", "clinic", "training_ground", "blacksmith",
	"armory", "church", "tavern", "graveyard",
]
const HEIRLOOM_TYPES := ["statue", "scroll", "badge", "tablet"]
const MAX_GEAR_LEVEL := 5
const MAX_EQUIPPED_SKILLS := 4

var rng := RandomNumberGenerator.new()
var _hero_uid: int = 1
var _buried_count: int = 0

# ---- 资源 ----
var gold: int = 0
var heirlooms := {"statue": 0, "scroll": 0, "badge": 0, "tablet": 0}
var supplies := {}                 # item_id -> 数量（城镇补给库存，任务中消耗同一份）
var trinkets: Array = []           # 已拥有的饰品 id 列表

# ---- 建筑 ----
var building_levels := {}          # building_id -> level（1..3）
var roster: Array = []             # 已招募英雄字典
var candidates: Array = []         # 当日招募候选
var refresh_left: int = 0          # 当日剩余刷新次数
var _selected_party_ids: Array = []


func _ready() -> void:
	rng.randomize()


# ------------------------------------------------------------------
# 游戏初始化
# ------------------------------------------------------------------

## 开新档：重置全部城镇状态（seed 用于测试复现）。
func reset_game(seed: int = 0) -> void:
	rng.seed = seed if seed != 0 else Time.get_ticks_usec()
	_hero_uid = 1
	_buried_count = 0
	var hero_meta: Dictionary = ConfigManager.get_entry("heroes", "_meta")
	gold = int(hero_meta.get("starting_gold", 8000))
	heirlooms = (hero_meta.get("start_heirlooms", {}) as Dictionary).duplicate(true)
	supplies = {}
	trinkets = []
	building_levels = {}
	for bid in BUILDING_IDS:
		building_levels[bid] = 1
	roster = []
	candidates = []
	_selected_party_ids = []
	refresh_candidates()


# ------------------------------------------------------------------
# 资源
# ------------------------------------------------------------------

func add_gold(amount: int) -> void:
	gold += maxi(amount, 0)

func spend_gold(amount: int) -> bool:
	if gold < amount:
		return false
	gold -= amount
	return true

func add_heirloom(heirloom_type: String, amount: int) -> void:
	if heirloom_type in HEIRLOOM_TYPES:
		heirlooms[heirloom_type] = int(heirlooms[heirloom_type]) + amount

## 一次消费多种传承物；任一种不足则整体失败（不扣任何一项）。
func spend_heirlooms(cost: Dictionary) -> bool:
	for h in HEIRLOOM_TYPES:
		if int(heirlooms.get(h, 0)) < int(cost.get(h, 0)):
			return false
	for h in HEIRLOOM_TYPES:
		heirlooms[h] = int(heirlooms[h]) - int(cost.get(h, 0))
	return true

func add_supply(item_id: String, amount: int) -> void:
	supplies[item_id] = int(supplies.get(item_id, 0)) + amount

func spend_supply(item_id: String, amount: int) -> bool:
	if int(supplies.get(item_id, 0)) < amount:
		return false
	supplies[item_id] = int(supplies.get(item_id, 0)) - amount
	return true

func add_trinket(trinket_id: String) -> void:
	if ConfigManager.has_entry("trinkets", trinket_id) and not trinkets.has(trinket_id):
		trinkets.append(trinket_id)

## 补给商店可售物品（items.json 中 type == "supply" 的 9 种）。
func shop_items() -> Array:
	var out: Array = []
	for key in ConfigManager.get_section("items"):
		if key.begins_with("_"):
			continue
		var cfg: Dictionary = ConfigManager.get_entry("items", key)
		if cfg.get("type", "supply") == "supply":
			out.append({"id": key, "name": cfg.get("name", key), "price": int(cfg.get("price", 0))})
	return out

func buy_supply(item_id: String, count: int) -> Dictionary:
	var cfg: Dictionary = ConfigManager.get_entry("items", item_id)
	if cfg.is_empty():
		return {"ok": false, "reason": "no_item"}
	var price := int(cfg.get("price", 0)) * count
	if not spend_gold(price):
		return {"ok": false, "reason": "funds"}
	add_supply(item_id, count)
	return {"ok": true, "count": count, "cost": price}


# ------------------------------------------------------------------
# 建筑
# ------------------------------------------------------------------

func get_building_level(building_id: String) -> int:
	return int(building_levels.get(building_id, 1))

## 当前等级的建筑配置条目（levels 数组中 level == 当前等级）。
func _building_cfg(building_id: String) -> Dictionary:
	var cfg: Dictionary = ConfigManager.get_entry("buildings", building_id)
	var lvl := get_building_level(building_id)
	for entry in cfg.get("levels", []):
		if int(entry.get("level", 0)) == lvl:
			return entry
	return {}

## 升到下一级所需传承物（cost 位于「目标等级」的条目中）。
func get_upgrade_cost(building_id: String) -> Dictionary:
	var cfg: Dictionary = ConfigManager.get_entry("buildings", building_id)
	var target := get_building_level(building_id) + 1
	for entry in cfg.get("levels", []):
		if int(entry.get("level", 0)) == target:
			return entry.get("upgrade_cost", {})
	return {}

func can_upgrade(building_id: String) -> bool:
	if get_building_level(building_id) >= 3:
		return false
	var cost := get_upgrade_cost(building_id)
	for h in HEIRLOOM_TYPES:
		if int(heirlooms.get(h, 0)) < int(cost.get(h, 0)):
			return false
	return true

func upgrade_building(building_id: String) -> Dictionary:
	if not can_upgrade(building_id):
		return {"ok": false, "reason": "cannot"}
	var cost := get_upgrade_cost(building_id)
	if not spend_heirlooms(cost):
		return {"ok": false, "reason": "funds"}
	building_levels[building_id] = get_building_level(building_id) + 1
	return {"ok": true, "level": get_building_level(building_id)}

## 训练场当前等级允许的技能最高等级（GDD 3.2：2/3/5）。
func get_max_skill_level() -> int:
	return int(_building_cfg("training_ground").get("max_skill_level", 2))

func get_max_weapon_level() -> int:
	return int(_building_cfg("blacksmith").get("max_weapon_level", 2))

func get_max_armor_level() -> int:
	return int(_building_cfg("armory").get("max_armor_level", 2))

## 诊疗室当前等级的治疗费用倍率（GDD 3.2：1 级 1.0，3 级 0.5）。
func get_clinic_fee_mult() -> float:
	return float(_building_cfg("clinic").get("fee_mult", 1.0))

func get_recruit_count() -> int:
	return int(_building_cfg("recruitment").get("candidates_per_day", 4))

func get_church_actions() -> Array:
	return _building_cfg("church").get("stress_relief", [])

func get_tavern_actions() -> Array:
	return _building_cfg("tavern").get("activities", [])

func get_graveyard_bonus_per_burial() -> float:
	return float(_building_cfg("graveyard").get("stat_per_burial", 0.0))


# ------------------------------------------------------------------
# 招募
# ------------------------------------------------------------------

func refresh_candidates() -> void:
	candidates.clear()
	var n := get_recruit_count()
	for i in n:
		candidates.append(_generate_candidate())
	refresh_left = int(_building_cfg("recruitment").get("refresh_count", 0))

func _generate_candidate() -> Dictionary:
	var classes: Array = []
	for key in ConfigManager.get_section("heroes"):
		if key.begins_with("_"):
			continue
		classes.append(key)
	var class_id := String(classes[_roll(0, classes.size() - 1)])
	var rarity := _roll_rarity()
	return {
		"class_id": class_id,
		"rarity": rarity,
		"cost": _recruit_cost(rarity),
		"quirks": _roll_quirks(),
	}

## 稀有度加权抽取（白 55 / 蓝 30 / 紫 12 / 金 3）。
func _roll_rarity() -> String:
	var meta: Dictionary = ConfigManager.get_entry("heroes", "_meta")
	var weights: Dictionary = meta.get("rarity_weights", {"white": 55, "blue": 30, "purple": 12, "gold": 3})
	var total := 0
	for r in weights:
		total += int(weights[r])
	var roll := _roll(0, total - 1)
	for r in weights:
		if roll < int(weights[r]):
			return r
		roll -= int(weights[r])
	return "white"

func _recruit_cost(rarity: String) -> int:
	var meta: Dictionary = ConfigManager.get_entry("heroes", "_meta")
	var costs: Dictionary = meta.get("recruit_cost_by_rarity", {})
	return int(costs.get(rarity, 2500))

func _roll_quirks() -> Array:
	var n := _roll(2, 4)
	var all: Array = []
	for key in ConfigManager.get_section("quirks"):
		if key.begins_with("_"):
			continue
		all.append(key)
	var picked: Array = []
	# 抽满 n 个且不重复（重掷避免重复导致数量不足，GDD 3.5：每位英雄 2~4 怪癖）
	var guard := 0
	while picked.size() < n and guard < 50:
		guard += 1
		if all.is_empty():
			break
		var q := String(all[_roll(0, all.size() - 1)])
		if not picked.has(q):
			picked.append(q)
	var quirks: Array = []
	for q in picked:
		var cfg: Dictionary = ConfigManager.get_entry("quirks", q)
		quirks.append({"id": q, "name": cfg.get("name", q), "type": cfg.get("type", "positive")})
	return quirks

## 招募第 index 个候选：扣金币、入名册；成功返回英雄字典，失败返回空字典。
func recruit(index: int) -> Dictionary:
	if index < 0 or index >= candidates.size():
		return {}
	var cand: Dictionary = candidates[index]
	if not spend_gold(int(cand.get("cost", 0))):
		return {}
	var hero := _make_hero(String(cand["class_id"]), String(cand["rarity"]))
	hero["quirks"] = cand["quirks"]
	roster.append(hero)
	candidates.remove_at(index)
	return hero


# ------------------------------------------------------------------
# 英雄构造 / 属性
# ------------------------------------------------------------------

func _make_hero(class_id: String, rarity: String) -> Dictionary:
	var cfg: Dictionary = ConfigManager.get_entry("heroes", class_id)
	var hero := {
		"id": "hero_%d" % _hero_uid,
		"class_id": class_id,
		"name": cfg.get("name", class_id),
		"class": cfg.get("name", class_id),
		"rarity": rarity,
		"level": 1,
		"exp": 0,
		"skills": {},
		"weapon_level": 1,
		"armor_level": 1,
		"trinkets": [null, null],
		"quirks": [],
		"injuries": [],
		"diseases": [],
		"resting": false,
		"dead": false,
	}
	for skill_id in cfg.get("skill_ids", []):
		if int(hero["skills"].size()) < MAX_EQUIPPED_SKILLS:
			hero["skills"][String(skill_id)] = 1
	_hero_uid += 1
	var stats := get_hero_stats(hero)
	hero["max_hp"] = stats["max_hp"]
	hero["hp"] = stats["max_hp"]
	hero["stress"] = 0
	return hero

## 计算英雄综合属性：基础 + 成长×（等级-1）+ 稀有度上浮 + 武器/护甲 + 怪癖/伤病/疾病/饰品。
func get_hero_stats(hero: Dictionary) -> Dictionary:
	var cfg: Dictionary = ConfigManager.get_entry("heroes", String(hero["class_id"]))
	var base: Dictionary = cfg.get("base_stats", {})
	var growth: Dictionary = cfg.get("growth", {})
	var lvl := int(hero.get("level", 1))
	var meta: Dictionary = ConfigManager.get_entry("heroes", "_meta")
	var rarity_bonus := float(meta.get("rarity_stat_bonus", {}).get(String(hero.get("rarity", "white")), 0.0))

	var s := {
		"max_hp": int(base.get("hp", 1)) + int(growth.get("hp", 0)) * (lvl - 1),
		"spd": int(base.get("spd", 0)) + int(growth.get("spd", 0)) * (lvl - 1),
		"acc": int(base.get("acc", 0)) + int(growth.get("acc", 0)) * (lvl - 1),
		"dodge": int(base.get("dodge", 0)) + int(growth.get("dodge", 0)) * (lvl - 1),
		"crit": float(base.get("crit", 0.0)) + float(growth.get("crit", 0.0)) * (lvl - 1),
		"dmg_min": int(base.get("dmg_min", 0)) + int(growth.get("dmg_min", 0)) * (lvl - 1),
		"dmg_max": int(base.get("dmg_max", 0)) + int(growth.get("dmg_max", 0)) * (lvl - 1),
		"prot": float(base.get("prot", 0.0)) + float(growth.get("prot", 0.0)) * (lvl - 1),
	}
	# 稀有度基础属性上浮（GDD 3.3：白 0% / 蓝 5% / 紫 10% / 金 15%）
	for k in s:
		if k == "prot":
			s[k] = clampf(float(s[k]) * (1.0 + rarity_bonus), 0.0, 0.8)
		elif k == "crit":
			s[k] = clampf(float(s[k]) * (1.0 + rarity_bonus), 0.0, 0.4)
		else:
			s[k] = roundi(float(s[k]) * (1.0 + rarity_bonus))
	# 武器/护甲（GDD 2.10：武器 +1/+2 DMG，护甲 +3 HP +1% PROT）
	s["dmg_min"] += (int(hero.get("weapon_level", 1)) - 1) * 1
	s["dmg_max"] += (int(hero.get("weapon_level", 1)) - 1) * 2
	s["max_hp"] += (int(hero.get("armor_level", 1)) - 1) * 3
	s["prot"] = clampf(float(s["prot"]) + (int(hero.get("armor_level", 1)) - 1) * 0.01, 0.0, 0.8)
	# 怪癖
	for q in hero.get("quirks", []):
		var qcfg: Dictionary = ConfigManager.get_entry("quirks", String(q.get("id", "")))
		for e in qcfg.get("effects", []):
			_apply_stat_effect(s, e)
	# 伤病 / 疾病
	for id_list in [hero.get("injuries", []), hero.get("diseases", [])]:
		for inj_id in id_list:
			var icfg: Dictionary = ConfigManager.get_entry("injuries", String(inj_id))
			for e in icfg.get("effects", []):
				_apply_stat_effect(s, e)
	# 饰品（2 槽）
	for slot in hero.get("trinkets", []):
		if slot == null or String(slot) == "":
			continue
		var tcfg: Dictionary = ConfigManager.get_entry("trinkets", String(slot))
		for e in tcfg.get("effects", []):
			_apply_stat_effect(s, e)
	return s

## 把配置中的单条效果应用到属性字典。
func _apply_stat_effect(s: Dictionary, e: Dictionary) -> void:
	var status := String(e.get("status", ""))
	var value := float(e.get("value", 0.0))
	match status:
		"hp_up", "hp_pct":
			s["max_hp"] = roundi(float(s["max_hp"]) * (1.0 + value))
		"hp_down", "max_hp_pct":
			s["max_hp"] = roundi(float(s["max_hp"]) * (1.0 + value))
		"spd", "spd_up":
			s["spd"] = maxi(int(s["spd"]) + int(value), 0)
		"spd_down":
			s["spd"] = maxi(int(s["spd"]) - int(value), 0)
		"acc", "acc_up":
			s["acc"] = maxi(int(s["acc"]) + int(value), 0)
		"acc_down":
			s["acc"] = maxi(int(s["acc"]) - int(value), 0)
		"dodge", "dodge_up":
			s["dodge"] = maxi(int(s["dodge"]) + int(value), 0)
		"crit", "crit_up":
			s["crit"] = clampf(float(s["crit"]) + value, 0.0, 0.4)
		_:
			pass


# ------------------------------------------------------------------
# 养成
# ------------------------------------------------------------------

## 升级所需经验（GDD 3.4：1→2 需 1500，之后 ×1.6）。
func get_exp_needed(level: int) -> int:
	var meta: Dictionary = ConfigManager.get_entry("loot_tables", "_meta")
	var exp_cfg: Dictionary = meta.get("exp_level", {"base": 1500, "mult": 1.6})
	return roundi(int(exp_cfg.get("base", 1500)) * pow(float(exp_cfg.get("mult", 1.6)), level - 1))

## 发放经验；可连续升级。返回 {leveled, level}。
func add_exp(hero: Dictionary, amount: int) -> Dictionary:
	hero["exp"] = int(hero.get("exp", 0)) + amount
	var leveled := false
	var guard := 0
	while int(hero["exp"]) >= get_exp_needed(int(hero["level"])) and guard < 200:
		hero["exp"] = int(hero["exp"]) - get_exp_needed(int(hero["level"]))
		hero["level"] = int(hero["level"]) + 1
		leveled = true
		guard += 1
	_refresh_hp(hero)
	return {"leveled": leveled, "level": int(hero["level"])}

func _refresh_hp(hero: Dictionary) -> void:
	var stats := get_hero_stats(hero)
	hero["max_hp"] = stats["max_hp"]
	hero["hp"] = mini(int(hero.get("hp", stats["max_hp"])), stats["max_hp"])

## 装备技能：职业池内、未满 4 个。返回 {ok}。
func equip_skill(hero: Dictionary, skill_id: String) -> Dictionary:
	var cfg: Dictionary = ConfigManager.get_entry("heroes", String(hero["class_id"]))
	if not cfg.get("skill_ids", []).has(skill_id):
		return {"ok": false, "reason": "not_in_pool"}
	if int(hero["skills"].size()) >= MAX_EQUIPPED_SKILLS and not hero["skills"].has(skill_id):
		return {"ok": false, "reason": "slots"}
	if not hero["skills"].has(skill_id):
		hero["skills"][skill_id] = 1
	return {"ok": true}

## 训练场升级技能等级（上限由训练场等级门控），消耗金币。
func upgrade_skill(hero: Dictionary, skill_id: String) -> Dictionary:
	if not hero["skills"].has(skill_id):
		return {"ok": false, "reason": "not_equipped"}
	var cur := int(hero["skills"][skill_id])
	if cur >= get_max_skill_level():
		return {"ok": false, "reason": "max_level"}
	var cost := 400 * (cur + 1)
	if not spend_gold(cost):
		return {"ok": false, "reason": "funds"}
	hero["skills"][skill_id] = cur + 1
	return {"ok": true, "level": cur + 1}

## 铁匠铺升级武器（上限由铁匠铺等级门控），消耗金币 + 传承物。
func upgrade_weapon(hero: Dictionary) -> Dictionary:
	if int(hero.get("weapon_level", 1)) >= get_max_weapon_level():
		return {"ok": false, "reason": "max_level"}
	return _upgrade_gear(hero, "weapon")

## 护甲坊升级护甲（上限由护甲坊等级门控）。
func upgrade_armor(hero: Dictionary) -> Dictionary:
	if int(hero.get("armor_level", 1)) >= get_max_armor_level():
		return {"ok": false, "reason": "max_level"}
	return _upgrade_gear(hero, "armor")

func _upgrade_gear(hero: Dictionary, kind: String) -> Dictionary:
	var lvl := int(hero.get(kind + "_level", 1))
	var cost := {"gold": 600 * lvl}
	if not spend_gold(int(cost["gold"])):
		return {"ok": false, "reason": "funds"}
	hero[kind + "_level"] = lvl + 1
	_refresh_hp(hero)
	return {"ok": true, "level": lvl + 1}

## 装备饰品到槽位（0/1）。返回 {ok}。
func equip_trinket(hero: Dictionary, slot: int, trinket_id: String) -> Dictionary:
	if slot < 0 or slot > 1:
		return {"ok": false, "reason": "slot"}
	if not ConfigManager.has_entry("trinkets", trinket_id):
		return {"ok": false, "reason": "no_item"}
	hero["trinkets"][slot] = trinket_id
	_refresh_hp(hero)
	return {"ok": true}

func unequip_trinket(hero: Dictionary, slot: int) -> Dictionary:
	if slot < 0 or slot > 1:
		return {"ok": false, "reason": "slot"}
	hero["trinkets"][slot] = null
	_refresh_hp(hero)
	return {"ok": true}


# ------------------------------------------------------------------
# 治疗 / 减压（GDD 3.5 / 3.6）
# ------------------------------------------------------------------

## 派遣休息：免费 -10 压力，该英雄下次任务不可参战。
func dispatch_rest(hero: Dictionary) -> Dictionary:
	if hero.get("resting", false):
		return {"ok": false, "reason": "already"}
	hero["resting"] = true
	hero["stress"] = maxi(int(hero.get("stress", 0)) - 10, 0)
	return {"ok": true, "stress": int(hero["stress"])}

## 教堂减压活动（烛光冥想 / 安魂曲）。
func church_relieve(hero: Dictionary, action_id: String) -> Dictionary:
	for a in get_church_actions():
		if String(a.get("action", "")) == action_id:
			if not spend_gold(int(a.get("cost", 0))):
				return {"ok": false, "reason": "funds"}
			hero["stress"] = clampi(int(hero.get("stress", 0)) + int(a.get("stress", 0)), 0, 200)
			return {"ok": true, "stress": int(hero["stress"])}
	return {"ok": false, "reason": "no_action"}

## 酒馆活动（痛饮 / 赌局），带风险。
func tavern_activity(hero: Dictionary, action_id: String) -> Dictionary:
	for a in get_tavern_actions():
		if String(a.get("action", "")) == action_id:
			if not spend_gold(int(a.get("cost", 0))):
				return {"ok": false, "reason": "funds"}
			if int(a.get("stress", 0)) != 0:
				hero["stress"] = clampi(int(hero.get("stress", 0)) + int(a.get("stress", 0)), 0, 200)
			var result := {"ok": true, "stress": int(hero.get("stress", 0))}
			if float(a.get("risk_new_quirk", 0.0)) > 0.0 and _roll(1, 100) <= int(float(a["risk_new_quirk"]) * 100.0):
				_add_random_quirk(hero, "negative")
				result["new_quirk"] = true
			return result
	return {"ok": false, "reason": "no_action"}

func _add_random_quirk(hero: Dictionary, quirk_type: String) -> void:
	gain_quirk(hero, quirk_type)

## 随机施加一处伤病（GDD 3.5：任务结束按伤害量触发）。
func apply_random_injury(hero: Dictionary) -> Dictionary:
	var pool: Array = []
	for key in ConfigManager.get_section("injuries"):
		if key.begins_with("_"):
			continue
		if ConfigManager.get_entry("injuries", key).get("type", "injury") == "injury":
			pool.append(key)
	if pool.is_empty():
		return {}
	var pick := String(pool[_roll(0, pool.size() - 1)])
	if not hero["injuries"].has(pick):
		hero["injuries"].append(pick)
		_refresh_hp(hero)
	return {"id": pick, "name": ConfigManager.get_entry("injuries", pick).get("name", pick)}

## 任务结束按伤害量触发伤病（GDD 3.5）：
##   伤害越高触发概率越高（injuries.json `_meta.injury_trigger`），且受上限约束。
## damage 为本次任务累计承受伤害；触发时按权重（由配置各伤病 chance 决定）抽取。
## 返回本次新增的伤病 id 列表。
func apply_injuries_by_damage(hero: Dictionary, damage: int) -> Array:
	var trigger: Dictionary = ConfigManager.get_entry("injuries", "_meta").get("injury_trigger", {})
	var min_damage := int(trigger.get("min_damage", 10))
	var chance_per_10 := float(trigger.get("chance_per_10_damage", 0.35))
	var max_per_hero := int(trigger.get("max_per_hero", 2))
	if damage < min_damage:
		return []
	var granted: Array = []
	var guard := 0
	# 按伤害量滚动机会：伤害/10 × 单次概率（上限封顶 1.0）。
	var chance := clampf(chance_per_10 * (float(damage) / 10.0), 0.0, 1.0)
	while guard < max_per_hero and int(hero["injuries"].size()) < max_per_hero:
		guard += 1
		if _roll(1, 100) > int(chance * 100.0):
			break
		var res := apply_random_injury(hero)
		if res.is_empty() or res.get("id", "") in granted:
			break
		granted.append(res["id"])
	return granted

## 随机感染一种疾病（GDD 3.5：特定区域/事件感染）。
## region 提供区域疾病池（injuries.json `_meta.disease.region_pools`），为空则取全部疾病。
func apply_random_disease(hero: Dictionary, region: String = "") -> Dictionary:
	var pool: Array = _disease_pool(region)
	if pool.is_empty():
		return {}
	var pick := String(pool[_roll(0, pool.size() - 1)])
	if not hero["diseases"].has(pick):
		hero["diseases"].append(pick)
		_refresh_hp(hero)
	return {"id": pick, "name": ConfigManager.get_entry("injuries", pick).get("name", pick)}

## 区域疾病池：优先 injuries.json `_meta.disease.region_pools[region]`，回退全部疾病。
func _disease_pool(region: String) -> Array:
	var pools: Dictionary = ConfigManager.get_entry("injuries", "_meta").get("disease", {}).get("region_pools", {})
	if region != "" and pools.has(region):
		return pools[region]
	var all: Array = []
	for key in ConfigManager.get_section("injuries"):
		if key.begins_with("_"):
			continue
		if ConfigManager.get_entry("injuries", key).get("type", "") == "disease":
			all.append(key)
	return all

## 事件房疾病感染判定概率（exploration.json `afflictions.event_disease_chance`）。
func get_event_disease_chance() -> float:
	return float(DataLoader.get_config("exploration.json").get("afflictions", {}).get("event_disease_chance", 0.12))

## 关底 Boss 疾病感染判定概率（exploration.json `afflictions.boss_disease_chance`）。
func get_boss_disease_chance() -> float:
	return float(DataLoader.get_config("exploration.json").get("afflictions", {}).get("boss_disease_chance", 0.3))

## 事件怪癖获取/改变概率与方向（exploration.json `afflictions`）。
func get_event_quirk_chance() -> float:
	return float(DataLoader.get_config("exploration.json").get("afflictions", {}).get("event_quirk_chance", 0.15))

func get_event_quirk_positive_chance() -> float:
	return float(DataLoader.get_config("exploration.json").get("afflictions", {}).get("event_quirk_positive_chance", 0.5))

## 任务结束怪癖获取概率与方向（quirks.json `_meta.gain`）。
func get_mission_quirk_chance() -> float:
	return float(ConfigManager.get_entry("quirks", "_meta").get("gain", {}).get("mission_chance", 0.1))

func get_mission_quirk_positive_chance() -> float:
	return float(ConfigManager.get_entry("quirks", "_meta").get("gain", {}).get("mission_positive_chance", 0.5))

## 诊疗室治疗伤病（1 级可治）。
func cure_injury(hero: Dictionary, injury_id: String) -> Dictionary:
	if not hero["injuries"].has(injury_id):
		return {"ok": false, "reason": "none"}
	var cfg: Dictionary = ConfigManager.get_entry("injuries", injury_id)
	var cost := roundi(int(cfg.get("cure_cost", 300)) * get_clinic_fee_mult())
	if not spend_gold(cost):
		return {"ok": false, "reason": "funds"}
	hero["injuries"].erase(injury_id)
	_refresh_hp(hero)
	return {"ok": true}

## 诊疗室治疗疾病（需 2 级）。
func cure_disease(hero: Dictionary, disease_id: String) -> Dictionary:
	if not hero["diseases"].has(disease_id):
		return {"ok": false, "reason": "none"}
	if get_building_level("clinic") < 2:
		return {"ok": false, "reason": "clinic_level"}
	var cfg: Dictionary = ConfigManager.get_entry("injuries", disease_id)
	var cost := roundi(int(cfg.get("cure_cost", 800)) * get_clinic_fee_mult())
	if not spend_gold(cost):
		return {"ok": false, "reason": "funds"}
	hero["diseases"].erase(disease_id)
	return {"ok": true}

## 教堂净化怪癖费用（GDD 3.5）：quirks.json `_meta.purge.base_cost × cost_mult`。
func get_purge_cost() -> int:
	var purge: Dictionary = ConfigManager.get_entry("quirks", "_meta").get("purge", {})
	return roundi(int(purge.get("base_cost", 800)) * float(purge.get("cost_mult", 1.0)))

## 英雄怪癖数量上限（GDD 3.5）：quirks.json `_meta.max_quirks`。
func get_max_quirks() -> int:
	return int(ConfigManager.get_entry("quirks", "_meta").get("max_quirks", 5))

## 教堂净化怪癖（费用高，GDD 3.5）。
func purge_quirk(hero: Dictionary, quirk_id: String) -> Dictionary:
	var cost := get_purge_cost()
	if not spend_gold(cost):
		return {"ok": false, "reason": "funds"}
	for i in range(hero["quirks"].size() - 1, -1, -1):
		if String(hero["quirks"][i].get("id", "")) == quirk_id:
			hero["quirks"].remove_at(i)
			_refresh_hp(hero)
			return {"ok": true}
	return {"ok": false, "reason": "no_quirk"}

## 任务中获取/改变怪癖（GDD 3.5）：按 quirk_type（""=随机正负）抽一个未拥有的怪癖。
## 已满 max_quirks 时替换一个随机已有怪癖（改变机制），返回操作结果。
func gain_quirk(hero: Dictionary, quirk_type: String = "") -> Dictionary:
	var t := quirk_type
	if t == "":
		t = "positive" if _roll(1, 100) <= 50 else "negative"
	var pool: Array = []
	for key in ConfigManager.get_section("quirks"):
		if key.begins_with("_"):
			continue
		if ConfigManager.get_entry("quirks", key).get("type", "") != t:
			continue
		if not _has_quirk(hero, String(key)):
			pool.append(key)
	if pool.is_empty():
		return {"ok": false, "reason": "no_available"}
	var pick := String(pool[_roll(0, pool.size() - 1)])
	var cfg: Dictionary = ConfigManager.get_entry("quirks", pick)
	var entry := {"id": pick, "name": cfg.get("name", pick), "type": t}
	var replaced := ""
	if hero["quirks"].size() >= get_max_quirks():
		var old_idx := _roll(0, hero["quirks"].size() - 1)
		replaced = String(hero["quirks"][old_idx].get("id", ""))
		hero["quirks"][old_idx] = entry
	else:
		hero["quirks"].append(entry)
	_refresh_hp(hero)
	return {"ok": true, "quirk": entry, "replaced": replaced}

## 事件改变怪癖：随机移除一个已有怪癖再获取一个新怪癖（GDD 3.5）。
func change_quirk(hero: Dictionary) -> Dictionary:
	if hero["quirks"].is_empty():
		return gain_quirk(hero, "")
	var old_idx := _roll(0, hero["quirks"].size() - 1)
	var old_id := String(hero["quirks"][old_idx].get("id", ""))
	hero["quirks"].remove_at(old_idx)
	var res := gain_quirk(hero, "")
	if not res.get("ok", false):
		# 无可用怪癖时保留原样
		return {"ok": false, "reason": "no_available", "removed": old_id}
	_refresh_hp(hero)
	return {"ok": true, "removed": old_id, "quirk": res["quirk"]}

func _has_quirk(hero: Dictionary, quirk_id: String) -> bool:
	for q in hero.get("quirks", []):
		if String(q.get("id", "")) == quirk_id:
			return true
	return false


# ------------------------------------------------------------------
# 队伍 / 出发 / 结算
# ------------------------------------------------------------------

func get_selected_party() -> Array:
	var out: Array = []
	for hid in _selected_party_ids:
		var hero := _find_hero(String(hid))
		if hero != null:
			out.append(hero)
	return out

func has_selected_party() -> bool:
	return not _selected_party_ids.is_empty()

func _find_hero(hero_id: String) -> Dictionary:
	for hero in roster:
		if String(hero.get("id", "")) == hero_id:
			return hero
	return {}

func select_party(hero_ids: Array) -> Dictionary:
	var ids: Array = []
	for hid in hero_ids:
		var hero := _find_hero(String(hid))
		if hero != null and not hero.get("resting", false):
			ids.append(String(hid))
	if ids.is_empty():
		return {"ok": false, "reason": "empty"}
	_selected_party_ids = ids
	return {"ok": true, "count": ids.size()}

## 出发：把选定队伍写入 GameState.party（复用 WS-5 探索闭环），补给用城镇库存。
func prepare_run(length: String) -> Dictionary:
	if not has_selected_party():
		return {"ok": false, "reason": "no_party"}
	GameState.start_run(length)
	return {"ok": true}

## 结算：金币/经验/伤病/怪癖回写名册，任务收益进城镇（GDD 3.5 / 4.5 子集，完整经济由 WS-10）。
## 伤病按本次任务累计伤害量触发（run_damage）；任务结束有概率获取/改变怪癖。
func settle_run(payload: Dictionary) -> Dictionary:
	var run_gold := int(payload.get("gold", 0))
	var length := String(GameState.quest_length)
	add_gold(run_gold)
	var exp_each := _compute_exp(length)
	var exp_total := 0
	var injury_report: Array = []
	var quirk_report: Array = []
	var disease_report: Array = []
	for ph in payload.get("party", []):
		var hero := _find_hero(String(ph.get("id", "")))
		if hero.is_empty():
			continue
		hero["hp"] = int(ph.get("hp", hero["max_hp"]))
		hero["stress"] = clampi(int(ph.get("stress", hero.get("stress", 0))), 0, 200)
		# 按伤害量触发伤病（GDD 3.5）
		var run_damage := int(hero.get("run_damage", 0))
		var new_injuries := apply_injuries_by_damage(hero, run_damage)
		if not new_injuries.is_empty():
			injury_report.append({"name": hero["name"], "ids": new_injuries})
		# 疾病：结算时按区域感染概率补充（exploration afflictions 已在任务中判定，这里兜底）
		var disease_region := String(payload.get("region", GameState.current_dungeon.get("map_type", "ruins")))
		var disease_pool: Array = _disease_pool(disease_region)
		if not disease_pool.is_empty() and _roll(1, 100) <= int(get_event_disease_chance() * 100.0):
			var d := apply_random_disease(hero, disease_region)
			if not d.is_empty():
				disease_report.append({"name": hero["name"], "id": d["id"]})
		# 任务结束怪癖获取/改变（GDD 3.5）
		if _roll(1, 100) <= int(get_mission_quirk_chance() * 100.0):
			var qtype := "positive" if _roll(1, 100) <= int(get_mission_quirk_positive_chance() * 100.0) else "negative"
			var q := gain_quirk(hero, qtype)
			if q.get("ok", false):
				quirk_report.append({"name": hero["name"], "quirk": q["quirk"], "replaced": q.get("replaced", "")})
		hero["run_damage"] = 0
		var r := add_exp(hero, exp_each)
		exp_total += exp_each
	# 解除所有派遣休息标记（已完成一次任务间隔）
	for hero in roster:
		hero["resting"] = false
	return {
		"ok": true,
		"gold_awarded": run_gold,
		"exp_awarded": exp_total,
		"injuries": injury_report,
		"quirks": quirk_report,
		"diseases": disease_report,
	}

## 经验公式（GDD 4.5）：300 × 长度系数（默认 1 星）。
func _compute_exp(length: String) -> int:
	var meta: Dictionary = ConfigManager.get_entry("loot_tables", "_meta")
	var formula: Dictionary = meta.get("exp_formula", {})
	var coefs: Dictionary = formula.get("length_coef", {"short": 1.0, "medium": 1.5, "long": 2.0})
	return roundi(int(formula.get("base", 300)) * float(coefs.get(length, 1.0)))


# ------------------------------------------------------------------
# 墓地（GDD 3.2：永久增益）
# ------------------------------------------------------------------

## 安葬英雄：从名册移除，计入墓地永久增益。
func bury_hero(hero: Dictionary) -> Dictionary:
	var idx := -1
	for i in roster.size():
		if String(roster[i].get("id", "")) == String(hero.get("id", "")):
			idx = i
			break
	if idx < 0:
		return {"ok": false, "reason": "not_in_roster"}
	hero["dead"] = true
	roster.remove_at(idx)
	_buried_count += 1
	return {"ok": true, "buried": _buried_count}

func get_buried_count() -> int:
	return _buried_count


# ------------------------------------------------------------------
# 随机工具
# ------------------------------------------------------------------

func _roll(min_val: int, max_val: int) -> int:
	return rng.randi_range(min_val, max_val)
