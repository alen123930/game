extends Node
## 全局游戏运行状态（GDD 1.1 / 2.5，WS-5）
## 持有：当前探索任务（地图数据/位置）、火把、队伍（占位，WS-4 接管前先存基础字段）、补给。
## 场景切换由 GameMain 状态机负责，本单例只承载运行期状态。

signal torch_changed(value: int)
signal run_started
signal run_ended

# ---- 探索运行状态 ----
var current_dungeon: Dictionary = {}          # 由 DungeonGenerator 产出
var current_pos: int = 0                      # 当前房间 id
var torch: int = 75
var run_active: bool = false
var rooms_cleared: int = 0
var boss_defeated: bool = false
var quest_length: String = "short"            # short / medium / long
var quest_type: String = "explore"            # explore / collect / hunt / boss（WS-19 对齐 4 类任务）
var collect_count: int = 0                    # 收集任务已收集数量
var run_gold: int = 0                         # 本次任务获得的金币（展示用，经济系统由 WS-10 接管）

# ---- 剧情（WS-15，GDD 第五章）----
var story_prologue_shown: bool = false        # 序章开场白是否已显示（每局仅一次）

# ---- 战斗衔接（WS-4 就绪前使用占位战斗场景）----
var pending_battle: Dictionary = {}           # {room_id, is_boss, monsters, torch_tier}
var battle_result: Dictionary = {}            # {victory, room_id, is_boss}

# ---- 结算衔接 ----
var result_payload: Dictionary = {}           # 传给结算场景 {outcome, rooms_cleared, gold, boss_defeated, torch}

# ---- 队伍（占位数据，WS-4 接管前仅用于展示/陷阱伤害）----
var party: Array = []
const PLACEHOLDER_PARTY := [
	{"name": "圣骑士", "class": "圣骑士", "hp": 48, "max_hp": 48, "stress": 0},
	{"name": "猎人", "class": "猎人", "hp": 32, "max_hp": 32, "stress": 0},
	{"name": "医师", "class": "医师", "hp": 34, "max_hp": 34, "stress": 0},
	{"name": "神秘学家", "class": "神秘学家", "hp": 28, "max_hp": 28, "stress": 0},
]

# ---- 补给（GDD 3.7 子集，任务内用到的）----
var supplies := {"torch": 4, "key": 2, "shovel": 2, "bandage": 2}

var _dungeon_config: Dictionary = {}


func _ready() -> void:
	_dungeon_config = DataLoader.get_config("exploration.json")
	torch = int(_dungeon_config.get("torch", {}).get("start", 75))


## 开始一次遗迹探索（由城镇/结算场景触发）。
func start_run(length: String, qtype: String = "explore") -> void:
	quest_length = length
	quest_type = qtype
	current_dungeon = {}
	current_pos = 0
	torch = int(_dungeon_config.get("torch", {}).get("start", 75))
	run_active = true
	rooms_cleared = 0
	boss_defeated = false
	collect_count = 0
	run_gold = 0
	pending_battle = {}
	battle_result = {}
	result_payload = {}
	party = []
	if TownManager.has_selected_party():
		party = TownManager.get_selected_party()
	if party.is_empty():
		for hero in PLACEHOLDER_PARTY:
			party.append(hero.duplicate(true))
	# 重置本次任务累计伤害（结算时按伤害量触发伤病，GDD 3.5）
	for hero in party:
		hero["run_damage"] = 0
	supplies = TownManager.supplies
	run_started.emit()


func end_run() -> void:
	run_active = false
	run_ended.emit()


# ---- 火把（GDD 2.5）----

func get_torch_config() -> Dictionary:
	return _dungeon_config.get("torch", {})


func get_torch_tier() -> Dictionary:
	var tiers: Array = get_torch_config().get("tiers", [])
	for tier in tiers:
		var t: Dictionary = tier
		if torch >= int(t.get("min", 0)) and torch <= int(t.get("max", 100)):
			return t
	return tiers.back() if not tiers.is_empty() else {}


func add_torch(amount: int) -> void:
	torch = clampi(torch + amount, 0, 100)
	torch_changed.emit(torch)


# ---- 侦查（WS-19，GDD 4.2 对齐：进入新房间掷侦查骰）----

## 侦查骰基础成功率（未计入任何修正）：exploration.json `exploration.scout_base_chance`。
func get_scout_base_chance() -> float:
	return float(_dungeon_config.get("exploration", {}).get("scout_base_chance", 0.35))


## 当前火把档位带来的侦查修正（百分比值，如 明亮 +25）。
func get_scout_torch_bonus() -> int:
	var tier: Dictionary = get_torch_tier()
	return int(tier.get("scout_bonus", 0))


## 队伍提供的侦查修正（百分比值）：
## 技能（skills.json `scout` 字段）+ 怪癖（`scout` 效果）+ 饰品（`scout` 效果）。
func get_party_scout_bonus() -> int:
	var total := 0
	for hero in party:
		# 技能：技能 id → 等级
		for skill_id in hero.get("skills", {}).keys():
			var scfg: Dictionary = ConfigManager.get_entry("skills", String(skill_id))
			total += int(scfg.get("scout", 0))
		# 怪癖
		for q in hero.get("quirks", []):
			var qcfg: Dictionary = ConfigManager.get_entry("quirks", String(q.get("id", "")))
			for e in qcfg.get("effects", []):
				if String(e.get("status", "")) == "scout":
					total += int(e.get("value", 0))
		# 饰品
		for slot in hero.get("trinkets", []):
			if slot == null or String(slot) == "":
				continue
			var tcfg: Dictionary = ConfigManager.get_entry("trinkets", String(slot))
			for e in tcfg.get("effects", []):
				if String(e.get("status", "")) == "scout":
					total += int(e.get("value", 0))
	return total


## 综合侦查成功率：基础 + 火把修正 + 队伍修正，clamp 到 0.05~0.95。
func get_scout_chance() -> float:
	var chance := get_scout_base_chance() \
		+ float(get_scout_torch_bonus()) / 100.0 \
		+ float(get_party_scout_bonus()) / 100.0
	return clampf(chance, 0.05, 0.95)


## 掷侦查骰：成功返回 true。
func roll_scout() -> bool:
	return randf() < get_scout_chance()


# ---- 露营接口（WS-19 预留，营地系统由 WS-22 独立任务实现）----

## 当前任务长度对应的露营次数：中 = 1、长 = 2、短 = 0。
func get_camp_count() -> int:
	var camp: Dictionary = _dungeon_config.get("exploration", {}).get("camp_count", {})
	return int(camp.get(quest_length, 0))


## 当前任务类型名称（exploration.json `quests`）。
func get_quest_type_name() -> String:
	var quests: Dictionary = _dungeon_config.get("quests", {})
	var q: Dictionary = quests.get(quest_type, {})
	return String(q.get("name", quest_type))


## 收集任务目标数量（exploration.json `quests.collect.target` 按长度）。
func get_collect_target() -> int:
	var quests: Dictionary = _dungeon_config.get("quests", {})
	var collect: Dictionary = quests.get("collect", {})
	return int(collect.get("target", {}).get(quest_length, 3))


# ---- 补给 ----

func has_supply(item: String) -> bool:
	return int(supplies.get(item, 0)) > 0


func add_supply(item: String, amount: int = 1) -> void:
	supplies[item] = int(supplies.get(item, 0)) + amount


func consume_supply(item: String, amount: int = 1) -> bool:
	if int(supplies.get(item, 0)) < amount:
		return false
	supplies[item] = int(supplies.get(item, 0)) - amount
	return true


## 队伍中是否有指定职业（用于撬锁判定，GDD 4.2 盗贼）。
func party_has_class(hero_class: String) -> bool:
	for hero in party:
		if String(hero.get("class", "")) == hero_class:
			return true
	return false


## 队伍受伤（陷阱失败/事件，GDD 4.2）。
## 同时累计每名英雄的 run_damage（结算按伤害量触发伤病，GDD 3.5）。
func damage_party(min_dmg: int, max_dmg: int) -> Dictionary:
	var total := 0
	for hero in party:
		var dmg := randi_range(min_dmg, max_dmg)
		hero["hp"] = maxi(0, int(hero["hp"]) - dmg)
		hero["run_damage"] = int(hero.get("run_damage", 0)) + dmg
		total += dmg
	return {"total_damage": total}


## 队伍存活检查。
func party_alive() -> bool:
	for hero in party:
		if int(hero["hp"]) > 0:
			return true
	return false
