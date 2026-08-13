extends Control
## 战斗场景（WS-4）：自动演示战斗
##
## 进入场景即通过 TurnManager 自动开战：
##   - 有 GameState.pending_battle 时，用其怪物与队伍开战（探索→战斗闭环）；
##   - 否则用默认演示阵容（英雄 4 人 vs 遗迹 4 怪）。
## 自动循环 run_round() 至分出胜负，场景内展示回合结算/状态/死亡日志，
## 结束后写 GameState.battle_result 并回到探索场景。

@onready var info_label: Label = %InfoLabel
@onready var status_label: Label = %StatusLabel
@onready var log_label: RichTextLabel = %LogLabel

## 默认演示阵容（无 pending_battle 时使用；职业名→heroes.json 的 id）。
const DEFAULT_HEROES := ["knight", "hunter", "physician", "occultist"]
const DEFAULT_MONSTERS := ["ruins_skel_soldier", "ruins_skel_archer", "ruins_skel_priest", "ruins_ghoul"]

## 队伍占位 class 名 → heroes.json id（GameState.party 目前只存 class 名）。
const CLASS_TO_HERO := {
	"圣骑士": "knight",
	"盾卫": "shieldguard",
	"狂战士": "berserker",
	"盗贼": "rogue",
	"猎人": "hunter",
	"医师": "physician",
	"神秘学家": "occultist",
	"符文师": "runecrafter",
}

var _battle_over := false
var _victory := false
var _log_count := 0

func _ready() -> void:
	_auto_battle()

## 自动开战：优先用 GameState.pending_battle，否则默认演示阵容。
## 逐回合推进（每回合让出一帧供 UI 刷新），至分出胜负或达到回合上限。
func _auto_battle() -> void:
	var pb: Dictionary = GameState.pending_battle
	var heroes: Array = _resolve_heroes(pb)
	var monsters: Array = pb.get("monsters", DEFAULT_MONSTERS.duplicate())
	if monsters.is_empty():
		monsters = DEFAULT_MONSTERS.duplicate()

	info_label.text = _battle_header(pb, monsters)
	status_label.text = "自动开战：%s" % _fmt_list(heroes, "英雄")
	TurnManager.start_battle(heroes, monsters, {"seed": _pick_seed(pb)})
	_update_roster_text()

	var guard := 0
	while TurnManager.get_battle_state()["active"] and guard < 60:
		TurnManager.run_round()
		_update_roster_text()
		_append_log()
		guard += 1
		await get_tree().process_frame

	_battle_over = true
	_victory = TurnManager.get_battle_state()["winner"] == CombatUnit.Team.HEROES
	status_label.text = "战斗结束：%s（点击返回探索继续）" % ("英雄获胜" if _victory else "怪物获胜")
	info_label.text = _battle_header(pb, monsters) + "\n结果：%s" % ("胜利" if _victory else "失败/撤退")

## 根据 pending_battle 与 GameState.party 解析英雄 id 列表。
func _resolve_heroes(pb: Dictionary) -> Array:
	if pb.is_empty():
		return DEFAULT_HEROES.duplicate()
	var ids: Array = []
	for hero in GameState.party:
		var hero_class: String = String(hero.get("class", ""))
		if CLASS_TO_HERO.has(hero_class):
			ids.append(CLASS_TO_HERO[hero_class])
	# 队伍数据不全时回退默认阵容
	if ids.is_empty():
		return DEFAULT_HEROES.duplicate()
	return ids

func _pick_seed(pb: Dictionary) -> int:
	return int(pb.get("seed", 20240812))

## 展示双方站位与 HP/状态（复用 get_battle_state()）。
func _update_roster_text() -> void:
	var state := TurnManager.get_battle_state()
	var lines: Array[String] = []
	lines.append("[color=#e8a94a]英雄[/color]：%s" % _roster_line(state["heroes"]))
	lines.append("[color=#6aa0d0]怪物[/color]：%s" % _roster_line(state["monsters"]))
	status_label.text = "\n".join(lines)

func _roster_line(units: Array) -> String:
	var parts: Array[String] = []
	for u in units:
		var tag := "[color=#ff5555]濒死[/color]" if bool(u.get("death_struggling", false)) else ""
		var crisis_tag := ""
		if String(u.get("resolution", "")) == "virtue":
			crisis_tag = "[color=#6ad07a]美德·%s[/color]" % u.get("crisis", "")
		elif String(u.get("resolution", "")) == "affliction":
			crisis_tag = "[color=#d06a6a]受难·%s[/color]" % u.get("crisis", "")
		var dead := "" if bool(u.get("alive", true)) else "[color=#666](死亡)[/color]"
		var tags := []
		if tag != "":
			tags.append(tag)
		if crisis_tag != "":
			tags.append(crisis_tag)
		var suffix := ("·".join(tags)) if not tags.is_empty() else ""
		parts.append("%s(%d号位)HP%d压%d%s%s" % [u.get("name", "?"), u.get("position", 0), u.get("hp", 0), u.get("stress", 0), suffix, dead])
	return "、".join(parts)

## 追加 event_log 新增条目到日志面板（只追加自上次显示后的）。
func _append_log() -> void:
	var texts: Array[String] = []
	for i in range(_log_count, TurnManager.event_log.size()):
		var f := _format_event(TurnManager.event_log[i])
		if f != "":
			texts.append(f)
	if texts.is_empty():
		return
	_log_count = TurnManager.event_log.size()
	var joined := "\n".join(texts)
	var existing := log_label.text
	if existing != "":
		joined = existing + "\n" + joined
	log_label.text = joined
	log_label.scroll_to_line(log_label.get_line_count())

func _format_event(entry: Dictionary) -> String:
	var t: String = entry.get("type", "")
	var round: String = _r(int(entry.get("round", 0)))
	match t:
		"skill_used":
			return "第%s回合 [%s] 使用 %s" % [round, _un(entry.get("unit", -1)), entry.get("skill", "")]
		"damage":
			return "第%s回合 伤害 %s→%s %d点%s" % [round, _un(entry.get("attacker", -1)), _un(entry.get("target", -1)), entry.get("amount", 0), ("暴击" if entry.get("crit", false) else "")]
		"unit_died":
			return "第%s回合 %s 死亡（%s）" % [round, _un(entry.get("unit", -1)), entry.get("cause", "")]
		"deathblow_stable":
			return "第%s回合 %s 濒死挣扎稳定" % [round, _un(entry.get("unit", -1))]
		"deathblow_fail":
			return "第%s回合 %s 濒死挣扎失败死亡" % [round, _un(entry.get("unit", -1))]
		"displace":
			return "第%s回合 %s 位移→%d号位" % [round, _un(entry.get("unit", -1)), entry.get("to", 0)]
		"displace_wall":
			return "第%s回合 %s 被击退撞墙受 %d 伤害" % [round, _un(entry.get("unit", -1)), entry.get("dmg", 0)]
		"status_applied":
			return "第%s回合 %s 获得 %s（%d回合）" % [round, _un(entry.get("unit", -1)), entry.get("status", ""), entry.get("duration", 0)]
		"summon":
			return "第%s回合 召唤 %s" % [round, entry.get("monster", "")]
		"stress":
			return "第%s回合 %s 压力%+d" % [round, _un(entry.get("unit", -1)), entry.get("delta", 0)]
		"mental_resolve":
			return "第%s回合 %s 精神判定：%s（%s）" % [round, _un(entry.get("unit", -1)), ("美德" if entry.get("resolution", "") == "virtue" else "受难"), entry.get("crisis", "")]
		"crisis_action":
			var skill_name: String = String(entry.get("skill", ""))
			if skill_name != "":
				var sk := ConfigManager.get_entry("skills", skill_name)
				skill_name = String(sk.get("name", skill_name))
				return "第%s回合 %s[受难·%s] 行动：%s → %s" % [round, _un(entry.get("unit", -1)), entry.get("crisis", ""), skill_name, _un(int(entry.get("target_uid", -1)))]
			return "第%s回合 %s[受难·%s] 空放（不行动）" % [round, _un(entry.get("unit", -1)), entry.get("crisis", "")]
		"stress_death":
			return "第%s回合 %s 压力崩溃，立即死亡！" % [round, _un(entry.get("unit", -1))]
		"heal_blocked":
			return "第%s回合 %s 无法被治疗（%s）" % [round, _un(entry.get("target", -1)), entry.get("crisis", "")]
		"heal":
			return "第%s回合 %s 恢复 %d" % [round, _un(entry.get("target", -1)), entry.get("amount", 0)]
		_:
			return ""

func _r(round: int) -> String:
	return str(round)

func _un(uid: int) -> String:
	var u := TurnManager.find_unit(uid)
	if u == null:
		return "?"
	return "%s" % u.display_name

func _fmt_list(items: Array, label: String) -> String:
	var names: Array[String] = []
	for it in items:
		names.append(String(it))
	return "%s：%s" % [label, "、".join(names)]

func _battle_header(pb: Dictionary, monsters: Array) -> String:
	if not pb.is_empty():
		var names := PackedStringArray()
		for m in monsters:
			var entry := ConfigManager.get_entry("monsters", String(m))
			names.append(String(entry.get("name", m)))
		return "遭遇战！敌人：%s\n火把档位：%s" % ["、".join(names), pb.get("torch_tier", "昏暗")]
	return _fmt_list(monsters, "演示敌人")

## 战斗结束 → 写 GameState.battle_result 返回探索。
func _finish_battle(victory: bool) -> void:
	var pb: Dictionary = GameState.pending_battle
	GameState.battle_result = {
		"victory": victory,
		"room_id": int(pb.get("room_id", -1)),
		"is_boss": bool(pb.get("is_boss", false)),
	}
	GameState.pending_battle = {}
	# 每战斗后自动存档（GDD 7.1）
	if GameState.run_active:
		SaveManager.autosave()
	_change_state(GameMain.GameState.EXPLORATION)

func _on_return_pressed() -> void:
	if not _battle_over:
		status_label.text = "战斗尚未结束"
		return
	_finish_battle(_victory)

func _on_retreat_pressed() -> void:
	_finish_battle(false)

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)
