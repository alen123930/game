extends Control
## 战斗场景（WS-8）：Android 触屏交互战斗 UI（GDD 2.11 / 7.3）
##
## 单指流交互（GDD 2.11）：
##   点选我方英雄 → 底部技能栏 → 点选技能 → 高亮可攻击目标 → 点目标执行；
##   支持「先选技能再选施法者」：技能保持持械时点选其他可用英雄可切换施法者。
## 触屏适配（GDD 7.3）：
##   - 底部按钮热区 ≥44×44dp、间距 ≥8dp（设计分辨率 1920×1080 下按钮 ≥150px ≈ 54dp）；
##   - 技能不可用（站位不符 / 冷却中 / 无有效目标）即时置灰；
##   - 长按任意单位显示详细属性与状态；
##   - 撤退等危险操作二次确认；
##   - SafeArea 刘海/圆角避让 + Control anchors 自适应。

enum Phase { COMMAND, ROUND, OVER }

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
## 状态 key → 中文名（长按详情/状态栏展示）。
const STATUS_NAMES_ZH := {
	"bleed": "流血", "poison": "中毒", "burn": "燃烧", "stun": "眩晕", "mark": "标记",
	"fear": "恐惧", "weak": "虚弱", "blind": "致盲", "guard": "守护", "berserk": "狂暴",
	"confuse": "迷惑", "prot_up": "护甲↑", "dodge_up": "闪避↑", "vulnerable": "脆弱",
	"slow": "迟缓", "immune_displacement": "免位移", "taunt": "嘲讽",
}
const ITEM_NAMES_ZH := {
	"bandage": "绷带", "torch": "火把", "antidote": "解毒剂", "holy_water": "圣水",
	"herb": "药草", "food": "食物",
}

## 站位格尺寸（设计分辨率 1920×1080，横屏）。
const SLOT_W := 250.0
const SLOT_H := 124.0
const SLOT_GAP := 12.0
const SLOT_X_MARGIN := 110.0
const BOTTOM_BAR_H := 420.0
## 长按判定阈值（秒）。
const LONG_PRESS_SEC := 0.5

@onready var safe_area: Control = %SafeArea
@onready var round_label: Label = %RoundLabel
@onready var torch_label: Label = %TorchLabel
@onready var field: Control = %Field
@onready var log_label: RichTextLabel = %LogLabel
@onready var hero_row: HBoxContainer = %HeroRow
@onready var skill_row: HBoxContainer = %SkillRow
@onready var detail_panel: PanelContainer = %DetailPanel
@onready var detail_vbox: VBoxContainer = %DetailVBox
@onready var item_panel: PanelContainer = %ItemPanel
@onready var item_vbox: VBoxContainer = %ItemVBox
@onready var retreat_panel: PanelContainer = %RetreatPanel
@onready var retreat_vbox: VBoxContainer = %RetreatVBox
@onready var defend_btn: Button = %DefendBtn
@onready var item_btn: Button = %ItemBtn
@onready var end_turn_btn: Button = %EndTurnBtn
@onready var retreat_btn: Button = %RetreatBtn

var _phase: int = Phase.COMMAND
var _selected_hero: CombatUnit = null
var _armed_skill: String = ""
var _valid_targets: Array[CombatUnit] = []
var _commanded: Dictionary = {}
var _battle_over := false
var _victory := false
var _log_count := 0
var _slots: Dictionary = {}   # uid -> UnitSlot
var _skill_buttons: Dictionary = {}  # skill_id -> Button

func _ready() -> void:
	get_viewport().size_changed.connect(_update_safe_area)
	field.resized.connect(func():
		if _phase != Phase.OVER and not _slots.is_empty():
			_rebuild_field())
	_update_safe_area()
	_panel_style(detail_panel)
	_panel_style(item_panel)
	_panel_style(retreat_panel)
	_start_battle()

func _start_battle() -> void:
	var pb: Dictionary = GameState.pending_battle
	var heroes: Array = _resolve_heroes(pb)
	var monsters: Array = pb.get("monsters", DEFAULT_MONSTERS.duplicate())
	if monsters.is_empty():
		monsters = DEFAULT_MONSTERS.duplicate()
	TurnManager.start_battle(heroes, monsters, {"seed": _pick_seed(pb)})
	_phase = Phase.COMMAND
	_commanded = {}
	_log("战斗开始！单指操作：点英雄 → 选技能 → 点目标执行。")
	_refresh_all()
	_append_log()
	# 首帧容器布局完成后重排站位格（保证 slots 定位正确）。
	await get_tree().process_frame
	if not _battle_over:
		_refresh_all()

# ------------------------------------------------------------------
# 对外 / 测试接口
# ------------------------------------------------------------------

## 测试与调试快照：当前交互状态。
func _get_debug_state() -> Dictionary:
	var valid_uids: Array = []
	for u in _valid_targets:
		valid_uids.append(u.uid)
	return {
		"phase": _phase,
		"selected_hero_uid": _selected_hero.uid if _selected_hero != null else -1,
		"armed_skill": _armed_skill,
		"valid_targets": valid_uids,
		"commanded": _commanded.keys(),
		"battle_over": _battle_over,
		"victory": _victory,
		"round": TurnManager.round_num,
	}

## 测试：指定技能按钮是否置灰（disabled）。
func _is_skill_greyed(skill_id: String) -> bool:
	if not _skill_buttons.has(skill_id):
		return true
	return (_skill_buttons[skill_id] as Button).disabled

# ------------------------------------------------------------------
# 回合 / 交互状态流转
# ------------------------------------------------------------------

## 刷新全部 UI：顶部信息、站位格、英雄栏、技能栏，并自动选择可行动英雄。
func _refresh_all() -> void:
	_update_top_labels()
	_rebuild_field()
	_rebuild_hero_row()
	_rebuild_skill_row()
	_update_action_buttons()
	_auto_select()

func _auto_select() -> void:
	if _phase != Phase.COMMAND:
		return
	if _is_commandable(_selected_hero):
		return
	for h in TurnManager.heroes:
		if _is_commandable(h):
			_select_hero(h)
			return
	_selected_hero = null
	_armed_skill = ""
	_valid_targets = []
	_rebuild_hero_row()
	_rebuild_skill_row()
	_rebuild_field()

func _select_hero(unit: CombatUnit) -> void:
	_selected_hero = unit
	_armed_skill = ""
	_valid_targets = []
	_rebuild_hero_row()
	_rebuild_skill_row()
	_rebuild_field()

func _arm_skill(skill_id: String) -> void:
	_armed_skill = skill_id
	_valid_targets = _compute_targets(_selected_hero, skill_id)
	_rebuild_skill_row()
	_rebuild_field()

func _cancel_skill() -> void:
	_armed_skill = ""
	_valid_targets = []
	_rebuild_skill_row()
	_rebuild_field()

## 执行命令：把选中英雄 + 持械技能 + 目标写入 TurnManager 脚本。
func _execute_command(target_uid: int) -> void:
	var hero := _selected_hero
	if hero == null or _armed_skill == "":
		return
	TurnManager.script_action(TurnManager.round_num, hero.uid, _armed_skill, target_uid)
	_commanded[hero.uid] = true
	_armed_skill = ""
	_valid_targets = []
	_rebuild_hero_row()
	_rebuild_skill_row()
	_rebuild_field()
	_maybe_auto_end()

## 全部可行动英雄已下令（或无人可行动）→ 自动结束回合。
func _maybe_auto_end() -> void:
	if _phase != Phase.COMMAND:
		return
	if not _all_commandable_commanded():
		return
	await get_tree().create_timer(0.35).timeout
	if _phase == Phase.COMMAND and _all_commandable_commanded():
		_end_turn()

func _all_commandable_commanded() -> bool:
	var any := false
	for h in TurnManager.heroes:
		if h.alive and not h.death_struggling:
			any = true
			if not _commanded.has(h.uid):
				return false
	return true

func _is_commandable(unit: CombatUnit) -> bool:
	return unit != null and unit.alive and not unit.death_struggling and not _commanded.has(unit.uid)

## 结束回合：按玩家脚本 + 敌方/其余 AI 推进一个完整回合。
func _end_turn() -> void:
	if _phase != Phase.COMMAND:
		return
	_phase = Phase.ROUND
	_armed_skill = ""
	_valid_targets = []
	TurnManager.run_round()
	_append_log()
	var st := TurnManager.get_battle_state()
	if not st["active"]:
		_victory = st["winner"] == CombatUnit.Team.HEROES
		_log("战斗结束：%s" % ("英雄获胜！" if _victory else "英雄战败/撤退。"))
		_finish_battle(_victory)
		return
	_phase = Phase.COMMAND
	_commanded = {}
	_refresh_all()

# ------------------------------------------------------------------
# 输入处理（单指流）
# ------------------------------------------------------------------

## 站位格点选：持械状态下点有效目标执行；否则点英雄选择。
func _on_slot_pressed(uid: int) -> void:
	if _phase != Phase.COMMAND or _battle_over:
		return
	if _armed_skill != "":
		var u := TurnManager.find_unit(uid)
		if u != null and u.is_hero and u.alive and not u.death_struggling:
			if u.skills.has(_armed_skill) and _skill_usable(u, _armed_skill):
				_selected_hero = u
				_arm_skill(_armed_skill)
				return
		if _valid_targets.any(func(t): return t.uid == uid):
			_execute_command(uid)
			return
		_cancel_skill()
		return
	var hero := TurnManager.find_unit(uid)
	if hero != null and hero.is_hero and _is_commandable(hero):
		_select_hero(hero)

## 测试/便捷接口：点选有效目标执行命令。
func _on_target_selected(uid: int) -> void:
	if _phase != Phase.COMMAND or _battle_over:
		return
	if _armed_skill != "" and _valid_targets.any(func(t): return t.uid == uid):
		_execute_command(uid)

func _on_slot_long_pressed(uid: int) -> void:
	var u := TurnManager.find_unit(uid)
	if u != null:
		_show_detail(u)

## 英雄栏点选：支持「先选技能再选施法者」切换。
func _on_hero_button_pressed(uid: int) -> void:
	if _phase != Phase.COMMAND or _battle_over:
		return
	var u := TurnManager.find_unit(uid)
	if u == null or not _is_commandable(u):
		return
	if _armed_skill != "" and u.skills.has(_armed_skill) and _skill_usable(u, _armed_skill):
		_selected_hero = u
		_arm_skill(_armed_skill)
		return
	_select_hero(u)

func _on_skill_selected(skill_id: String) -> void:
	if _phase != Phase.COMMAND or _selected_hero == null:
		return
	if _armed_skill == skill_id:
		_cancel_skill()
		return
	if not _skill_usable(_selected_hero, skill_id):
		return
	_arm_skill(skill_id)

func _on_defend_pressed() -> void:
	if _phase != Phase.COMMAND or _selected_hero == null:
		return
	if not _is_commandable(_selected_hero):
		return
	TurnManager.script_action(TurnManager.round_num, _selected_hero.uid, "defend", -1)
	_commanded[_selected_hero.uid] = true
	_cancel_skill()
	_auto_select()
	_maybe_auto_end()

func _on_end_turn_pressed() -> void:
	_end_turn()

func _on_retreat_pressed() -> void:
	if _battle_over:
		return
	_show_retreat_confirm()

func _on_confirm_retreat() -> void:
	retreat_panel.visible = false
	_finish_battle(false)

func _on_cancel_retreat() -> void:
	retreat_panel.visible = false

func _on_item_pressed() -> void:
	if _phase != Phase.COMMAND or _battle_over:
		return
	if item_panel.visible:
		item_panel.visible = false
		return
	_rebuild_item_panel()
	item_panel.visible = true

func _on_item_apply(item_id: String) -> void:
	if _selected_hero == null or not _selected_hero.alive:
		return
	if not GameState.consume_supply(item_id, 1):
		return
	_apply_item_effect(item_id, _selected_hero)
	item_panel.visible = false
	_refresh_all()

# ------------------------------------------------------------------
# 技能可用性 / 目标计算
# ------------------------------------------------------------------

func _skill_usable(hero: CombatUnit, skill_id: String) -> bool:
	if hero == null or not hero.alive or hero.death_struggling:
		return false
	if not hero.skills.has(skill_id):
		return false
	if not hero.can_use_from_position(skill_id):
		return false
	if not hero.is_skill_ready(skill_id):
		return false
	return not _compute_targets(hero, skill_id).is_empty()

## 持械技能的有效目标列表：自施法=[自己]；AOE=全部存活敌方；
## 治疗/增益=己方存活且站位匹配；其余=敌方存活且站位匹配。
func _compute_targets(hero: CombatUnit, skill_id: String) -> Array[CombatUnit]:
	var skill: Dictionary = hero.skills.get(skill_id, {})
	if skill.is_empty():
		return []
	var tpos: Array = skill.get("target_pos", [1, 2, 3, 4])
	if tpos == [0]:
		return [hero]
	var is_aoe := false
	for e in skill.get("effects", []):
		if e.get("status", "") == "aoe":
			is_aoe = true
			break
	if is_aoe:
		return _alive(_opponents(hero))
	var team: Array = _target_team(hero, skill)
	var out: Array[CombatUnit] = []
	for u in team:
		if u.alive and (u.position in tpos):
			out.append(u)
	return out

## 目标阵营：治疗/减压/增益/净化 → 己方；其余 → 敌方。
func _target_team(hero: CombatUnit, skill: Dictionary) -> Array:
	var stype: String = skill.get("type", "damage")
	if stype in ["heal", "stress_heal", "buff"]:
		return TurnManager.heroes
	for e in skill.get("effects", []):
		var status_name: String = e.get("status", "")
		if status_name in ["heal", "stress_heal", "cure", "prot_up", "dodge_up", "stress_heal"]:
			return TurnManager.heroes
	return TurnManager.monsters

func _alive(units: Array) -> Array[CombatUnit]:
	var out: Array[CombatUnit] = []
	for u in units:
		if u.alive:
			out.append(u)
	return out

func _opponents(unit: CombatUnit) -> Array:
	return TurnManager.heroes if unit.team == CombatUnit.Team.MONSTERS else TurnManager.monsters

# ------------------------------------------------------------------
# 站位格 / 英雄栏 / 技能栏渲染
# ------------------------------------------------------------------

func _rebuild_field() -> void:
	for c in field.get_children():
		c.queue_free()
	_slots.clear()
	var valid_uids: Dictionary = {}
	for t in _valid_targets:
		valid_uids[t.uid] = true

	var heroes_sorted: Array = TurnManager.heroes.duplicate()
	heroes_sorted.sort_custom(func(a, b): return a.position > b.position)
	var monsters_sorted: Array = TurnManager.monsters.duplicate()
	monsters_sorted.sort_custom(func(a, b): return a.position > b.position)

	var rect := field.get_rect()
	var hero_x := rect.position.x + SLOT_X_MARGIN
	var monster_x := rect.end.x - SLOT_X_MARGIN - SLOT_W
	for u in heroes_sorted:
		var slot := _make_slot(u, hero_x)
		_slots[u.uid] = slot
		field.add_child(slot)
	for u in monsters_sorted:
		var slot := _make_slot(u, monster_x)
		_slots[u.uid] = slot
		field.add_child(slot)
	_apply_slot_styles(valid_uids)

func _make_slot(unit: CombatUnit, x: float) -> UnitSlot:
	var rect := field.get_rect()
	var base_y := rect.end.y - 16.0 - SLOT_H
	var y := base_y - (unit.position - 1) * (SLOT_H + SLOT_GAP)
	var slot := UnitSlot.new()
	slot.setup(unit)
	slot.position = Vector2(x, y)
	slot.size = Vector2(SLOT_W, SLOT_H)
	slot.unit_pressed.connect(_on_slot_pressed)
	slot.unit_long_pressed.connect(_on_slot_long_pressed)
	return slot

func _apply_slot_styles(valid_uids: Dictionary) -> void:
	for uid in _slots:
		var slot: UnitSlot = _slots[uid]
		var u := TurnManager.find_unit(int(uid))
		if u == null:
			continue
		var is_valid := valid_uids.has(int(uid))
		var is_selected := _selected_hero != null and _selected_hero.uid == int(uid)
		slot.apply_state(u, is_selected, is_valid, _commanded.has(int(uid)))

func _rebuild_hero_row() -> void:
	for c in hero_row.get_children():
		c.queue_free()
	for h in TurnManager.heroes:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(205, 118)
		btn.add_theme_font_size_override("font_size", 22)
		var tag := ""
		if not h.alive:
			tag = "（死亡）"
		elif h.death_struggling:
			tag = "（濒死）"
		elif _commanded.has(h.uid):
			tag = "（已行动）"
		btn.text = "%s %s\nHP %d/%d 压力%d" % [h.display_name, tag, h.hp, h.max_hp, h.stress]
		btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		if not h.alive:
			btn.disabled = true
			btn.modulate = Color(0.45, 0.45, 0.45)
			btn.add_theme_stylebox_override("disabled", _style(Color(0.14, 0.13, 0.12), Color(0.2, 0.2, 0.2), 2))
		elif h == _selected_hero:
			btn.add_theme_stylebox_override("normal", _style(Color(0.36, 0.30, 0.12), Color(0.95, 0.75, 0.35), 4))
			btn.add_theme_stylebox_override("hover", _style(Color(0.42, 0.35, 0.14), Color(1.0, 0.85, 0.45), 4))
			btn.add_theme_stylebox_override("pressed", _style(Color(0.46, 0.38, 0.16), Color(1.0, 0.9, 0.5), 4))
		elif _commanded.has(h.uid):
			btn.modulate = Color(0.75, 0.75, 0.75)
			btn.add_theme_stylebox_override("normal", _style(Color(0.20, 0.17, 0.13), Color(0.35, 0.30, 0.22), 2))
			btn.add_theme_stylebox_override("hover", _style(Color(0.26, 0.22, 0.16), Color(0.5, 0.42, 0.3), 2))
			btn.add_theme_stylebox_override("pressed", _style(Color(0.30, 0.25, 0.18), Color(0.6, 0.5, 0.36), 2))
		else:
			btn.add_theme_stylebox_override("normal", _style(Color(0.24, 0.20, 0.15), Color(0.5, 0.42, 0.30), 2))
			btn.add_theme_stylebox_override("hover", _style(Color(0.30, 0.25, 0.18), Color(0.7, 0.6, 0.4), 2))
			btn.add_theme_stylebox_override("pressed", _style(Color(0.34, 0.28, 0.20), Color(0.8, 0.68, 0.45), 2))
		btn.pressed.connect(_on_hero_button_pressed.bind(h.uid))
		hero_row.add_child(btn)

func _rebuild_skill_row() -> void:
	for c in skill_row.get_children():
		c.queue_free()
	_skill_buttons.clear()
	if _selected_hero == null or not _selected_hero.alive:
		return
	for skill_id: String in _selected_hero.skills.keys():
		var skill: Dictionary = _selected_hero.skills[skill_id]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(205, 165)
		btn.add_theme_font_size_override("font_size", 26)
		var cd := int(_selected_hero.cooldowns.get(skill_id, 0))
		var txt := String(skill.get("name", skill_id))
		if cd > 0:
			txt += "\n冷却 %d" % cd
		btn.text = txt
		btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		if not _skill_usable(_selected_hero, skill_id):
			btn.disabled = true
			btn.modulate = Color(0.55, 0.55, 0.55)
			btn.add_theme_stylebox_override("disabled", _style(Color(0.16, 0.15, 0.14), Color(0.28, 0.26, 0.24), 2))
		elif _armed_skill == skill_id:
			btn.add_theme_stylebox_override("normal", _style(Color(0.42, 0.34, 0.12), Color(0.9, 0.72, 0.3), 4))
			btn.add_theme_stylebox_override("hover", _style(Color(0.5, 0.4, 0.14), Color(1.0, 0.85, 0.4), 4))
			btn.add_theme_stylebox_override("pressed", _style(Color(0.55, 0.45, 0.16), Color(1.0, 0.9, 0.5), 4))
		else:
			btn.add_theme_stylebox_override("normal", _style(Color(0.24, 0.20, 0.15), Color(0.5, 0.42, 0.30), 2))
			btn.add_theme_stylebox_override("hover", _style(Color(0.30, 0.25, 0.18), Color(0.7, 0.6, 0.4), 2))
			btn.add_theme_stylebox_override("pressed", _style(Color(0.34, 0.28, 0.20), Color(0.8, 0.68, 0.45), 2))
		btn.pressed.connect(_on_skill_selected.bind(skill_id))
		skill_row.add_child(btn)
		_skill_buttons[skill_id] = btn

func _update_action_buttons() -> void:
	var interactive := _phase == Phase.COMMAND and not _battle_over
	defend_btn.disabled = not interactive
	item_btn.disabled = not interactive
	end_turn_btn.disabled = not interactive

func _update_top_labels() -> void:
	round_label.text = "回合 %d" % TurnManager.round_num
	torch_label.text = "火把 %d" % GameState.torch

# ------------------------------------------------------------------
# 长按详情 / 撤退确认 / 道具
# ------------------------------------------------------------------

func _show_detail(unit: CombatUnit) -> void:
	for c in detail_vbox.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "%s（%s）　%s号位" % [unit.display_name, "英雄" if unit.is_hero else "敌人", unit.position]
	title.add_theme_font_size_override("font_size", 32)
	detail_vbox.add_child(title)

	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 22)
	var statuses: Array[String] = []
	for s in unit.statuses:
		var sname: String = String(s.get("status", ""))
		statuses.append("%s(%d)" % [STATUS_NAMES_ZH.get(sname, sname), int(s.get("duration", 0))])
	var lines: Array[String] = [
		"生命：%d / %d　　%s" % [unit.hp, unit.max_hp, "濒死挣扎中" if unit.death_struggling else "存活"],
		"速度 %d　精准 %d　闪避 %d" % [unit.spd, unit.acc, unit.dodge],
		"暴击 %.0f%%　护甲 %.0f%%　伤害 %d~%d" % [unit.crit * 100.0, unit.prot * 100.0, unit.dmg_min, unit.dmg_max],
		"压力 %d / %d" % [unit.stress, unit.max_stress],
	]
	if not statuses.is_empty():
		lines.append("状态：" + "、".join(statuses))
	body.text = "\n".join(lines)
	detail_vbox.add_child(body)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 72)
	close.add_theme_font_size_override("font_size", 26)
	close.pressed.connect(func(): detail_panel.visible = false)
	detail_vbox.add_child(close)
	detail_panel.visible = true

func _show_retreat_confirm() -> void:
	for c in retreat_vbox.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "⚠ 确定要撤退吗？"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	retreat_vbox.add_child(title)
	var body := Label.new()
	body.text = "撤退将立即结束战斗并按失败结算。\n（危险操作二次确认）"
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 22)
	retreat_vbox.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 32)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.custom_minimum_size = Vector2(160, 76)
	cancel.add_theme_font_size_override("font_size", 26)
	cancel.pressed.connect(_on_cancel_retreat)
	row.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "确认撤退"
	confirm.custom_minimum_size = Vector2(160, 76)
	confirm.add_theme_font_size_override("font_size", 26)
	confirm.add_theme_stylebox_override("normal", _style(Color(0.35, 0.12, 0.10), Color(0.9, 0.3, 0.25), 3))
	confirm.add_theme_stylebox_override("hover", _style(Color(0.45, 0.16, 0.13), Color(1.0, 0.4, 0.3), 3))
	confirm.add_theme_stylebox_override("pressed", _style(Color(0.5, 0.18, 0.15), Color(1.0, 0.5, 0.4), 3))
	confirm.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	confirm.pressed.connect(_on_confirm_retreat)
	row.add_child(confirm)
	retreat_vbox.add_child(row)
	retreat_panel.visible = true

func _rebuild_item_panel() -> void:
	for c in item_vbox.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "使用道具（作用于当前选中英雄）"
	title.add_theme_font_size_override("font_size", 26)
	item_vbox.add_child(title)
	var any_item := false
	for item_id: String in ITEM_NAMES_ZH:
		if not GameState.has_supply(item_id):
			continue
		any_item = true
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 64)
		btn.text = "%s（剩 %d）" % [ITEM_NAMES_ZH[item_id], int(GameState.supplies.get(item_id, 0))]
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(_on_item_apply.bind(item_id))
		item_vbox.add_child(btn)
	if not any_item:
		var empty := Label.new()
		empty.text = "没有可用补给。"
		empty.add_theme_font_size_override("font_size", 22)
		item_vbox.add_child(empty)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 64)
	close.add_theme_font_size_override("font_size", 24)
	close.pressed.connect(func(): item_panel.visible = false)
	item_vbox.add_child(close)

func _apply_item_effect(item_id: String, hero: CombatUnit) -> void:
	match item_id:
		"bandage":
			var heal := int(ceil(hero.max_hp * 0.2))
			hero.heal(heal)
			hero.remove_status("bleed")
			_log("%s 使用绷带，回复 %d 并止血。" % [hero.display_name, heal])
		"torch":
			GameState.add_torch(25)
			_log("点燃火把，火把 +25。")
		"antidote":
			hero.remove_status("poison")
			_log("%s 使用解毒剂，解除中毒。" % hero.display_name)
		"holy_water":
			hero.remove_status("burn")
			_log("%s 使用圣水，解除燃烧。" % hero.display_name)
		"herb":
			hero.remove_status("weak")
			_log("%s 使用药草，解除虚弱。" % hero.display_name)
		"food":
			hero.heal(5)
			_log("%s 进食，回复 5 生命。" % hero.display_name)

# ------------------------------------------------------------------
# SafeArea / 样式 / 场景切换
# ------------------------------------------------------------------

func _update_safe_area() -> void:
	var win := DisplayServer.window_get_size()
	var safe := DisplayServer.get_display_safe_area()
	safe_area.offset_left = float(maxi(safe.position.x, 0))
	safe_area.offset_top = float(maxi(safe.position.y, 0))
	safe_area.offset_right = -float(maxi(win.x - safe.end.x, 0))
	safe_area.offset_bottom = -float(maxi(win.y - safe.end.y, 0))

func _panel_style(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", _style(Color(0.10, 0.09, 0.08), Color(0.55, 0.45, 0.30), 3))

func _style(bg: Color, border: Color, border_w: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)

## 战斗结束 → 写 GameState.battle_result 返回探索场景。
func _finish_battle(victory: bool) -> void:
	if _battle_over:
		return
	_battle_over = true
	_victory = victory
	var pb: Dictionary = GameState.pending_battle
	GameState.battle_result = {
		"victory": victory,
		"room_id": int(pb.get("room_id", -1)),
		"is_boss": bool(pb.get("is_boss", false)),
	}
	GameState.pending_battle = {}
	_change_state(GameMain.GameState.EXPLORATION)

# ------------------------------------------------------------------
# 队伍解析 / 事件日志
# ------------------------------------------------------------------

## 根据 pending_battle 与 GameState.party 解析英雄 id 列表。
func _resolve_heroes(pb: Dictionary) -> Array:
	if pb.is_empty():
		return DEFAULT_HEROES.duplicate()
	var ids: Array = []
	for hero in GameState.party:
		var hero_class: String = String(hero.get("class", ""))
		if CLASS_TO_HERO.has(hero_class):
			ids.append(CLASS_TO_HERO[hero_class])
	if ids.is_empty():
		return DEFAULT_HEROES.duplicate()
	return ids

func _pick_seed(pb: Dictionary) -> int:
	return int(pb.get("seed", 20240812))

func _log(text: String) -> void:
	log_label.append_text(text + "\n")

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
	var round: int = int(entry.get("round", 0))
	match t:
		"skill_used":
			return "R%d [%s] 使用 %s" % [round, _un(entry.get("unit", -1)), entry.get("skill", "")]
		"damage":
			return "R%d %s → %s 造成 %d 伤害%s" % [round, _un(entry.get("attacker", -1)), _un(entry.get("target", -1)), entry.get("amount", 0), ("（暴击）" if entry.get("crit", false) else "")]
		"unit_died":
			return "R%d %s 死亡（%s）" % [round, _un(entry.get("unit", -1)), entry.get("cause", "")]
		"deathblow_stable":
			return "R%d %s 濒死挣扎稳定" % [round, _un(entry.get("unit", -1))]
		"deathblow_fail":
			return "R%d %s 濒死挣扎失败死亡" % [round, _un(entry.get("unit", -1))]
		"displace":
			return "R%d %s 位移 → %d 号位" % [round, _un(entry.get("unit", -1)), entry.get("to", 0)]
		"displace_wall":
			return "R%d %s 撞墙受 %d 伤害" % [round, _un(entry.get("unit", -1)), entry.get("dmg", 0)]
		"status_applied":
			return "R%d %s 获得 %s（%d 回合）" % [round, _un(entry.get("unit", -1)), entry.get("status", ""), entry.get("duration", 0)]
		"summon":
			return "R%d 召唤 %s" % [round, entry.get("monster", "")]
		"stress":
			return "R%d %s 压力 %+d" % [round, _un(entry.get("unit", -1)), entry.get("delta", 0)]
		"heal":
			return "R%d %s 恢复 %d" % [round, _un(entry.get("target", -1)), entry.get("amount", 0)]
		"guard_redirect":
			return "R%d %s 被守护者 %s 挡住" % [round, _un(entry.get("target", -1)), _un(entry.get("guarder", -1))]
		"skill_unavailable":
			return "R%d %s 的技能 %s 不可用" % [round, _un(entry.get("unit", -1)), entry.get("skill", "")]
		_:
			return ""

func _un(uid: int) -> String:
	var u := TurnManager.find_unit(uid)
	if u == null:
		return "?"
	return "%s" % u.display_name

# ------------------------------------------------------------------
# 单位站位格（支持点选 + 长按）
# ------------------------------------------------------------------

class UnitSlot:
	extends Button
	## 单个单位站位格：名称/HP/压力/状态，支持点选与长按（长按显示详情）。

	signal unit_pressed(uid: int)
	signal unit_long_pressed(uid: int)

	var unit_uid: int = -1
	var _press_timer: Timer
	var _long_fired := false

	func setup(unit: CombatUnit) -> void:
		unit_uid = unit.uid
		var bg := _sb(Color(0.18, 0.14, 0.10), Color(0.45, 0.36, 0.24), 2)
		add_theme_stylebox_override("normal", bg)
		add_theme_stylebox_override("hover", _sb(Color(0.22, 0.17, 0.12), Color(0.6, 0.48, 0.32), 2))
		add_theme_stylebox_override("pressed", _sb(Color(0.25, 0.20, 0.14), Color(0.7, 0.55, 0.36), 2))
		add_theme_stylebox_override("focus", StyleBoxEmpty.new())

		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", 24)
		name_label.text = unit.display_name
		name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
		name_label.offset_left = 8
		name_label.offset_top = 4
		name_label.offset_right = -8
		name_label.offset_bottom = 34
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(name_label)

		var hp_bar := ProgressBar.new()
		hp_bar.name = "HpBar"
		hp_bar.max_value = float(maxi(unit.max_hp, 1))
		hp_bar.value = float(unit.hp)
		hp_bar.show_percentage = false
		hp_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
		hp_bar.offset_left = 10
		hp_bar.offset_top = 38
		hp_bar.offset_right = -10
		hp_bar.offset_bottom = 66
		hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(hp_bar)

		var stress_bar := ProgressBar.new()
		stress_bar.name = "StressBar"
		stress_bar.max_value = float(maxi(unit.max_stress, 1))
		stress_bar.value = float(unit.stress)
		stress_bar.show_percentage = false
		stress_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
		stress_bar.offset_left = 10
		stress_bar.offset_top = 70
		stress_bar.offset_right = -10
		stress_bar.offset_bottom = 88
		stress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(stress_bar)

		var status_label := Label.new()
		status_label.name = "StatusLabel"
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		status_label.add_theme_font_size_override("font_size", 16)
		status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		status_label.offset_left = 8
		status_label.offset_top = -26
		status_label.offset_right = -8
		status_label.offset_bottom = -4
		status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(status_label)

		update_display(unit)

	func update_display(unit: CombatUnit) -> void:
		var hp_bar: ProgressBar = get_node("HpBar")
		hp_bar.max_value = float(maxi(unit.max_hp, 1))
		hp_bar.value = float(unit.hp)
		var stress_bar: ProgressBar = get_node("StressBar")
		stress_bar.max_value = float(maxi(unit.max_stress, 1))
		stress_bar.value = float(unit.stress)
		var status_label: Label = get_node("StatusLabel")
		var parts: Array[String] = []
		if unit.death_struggling:
			parts.append("濒死")
		for s in unit.statuses:
			var sname: String = String(s.get("status", ""))
			parts.append(UnitSlot._zh(sname))
		status_label.text = "、".join(parts)

	func apply_state(unit: CombatUnit, is_selected: bool, is_valid: bool, is_commanded: bool) -> void:
		update_display(unit)
		var normal: StyleBoxFlat
		var hover: StyleBoxFlat
		var pressed: StyleBoxFlat
		if is_valid:
			normal = _sb(Color(0.16, 0.30, 0.14), Color(0.5, 0.95, 0.4), 5)
			hover = _sb(Color(0.20, 0.38, 0.18), Color(0.65, 1.0, 0.5), 5)
			pressed = _sb(Color(0.24, 0.44, 0.20), Color(0.8, 1.0, 0.6), 5)
		elif is_selected:
			normal = _sb(Color(0.36, 0.30, 0.12), Color(0.95, 0.75, 0.35), 4)
			hover = _sb(Color(0.42, 0.35, 0.14), Color(1.0, 0.85, 0.45), 4)
			pressed = _sb(Color(0.46, 0.38, 0.16), Color(1.0, 0.9, 0.5), 4)
		elif not unit.alive:
			normal = _sb(Color(0.12, 0.11, 0.10), Color(0.2, 0.2, 0.2), 2)
			hover = normal
			pressed = normal
		else:
			var base := Color(0.18, 0.14, 0.10)
			var border := Color(0.45, 0.36, 0.24)
			if not unit.is_hero:
				base = Color(0.12, 0.15, 0.19)
				border = Color(0.30, 0.40, 0.50)
			normal = _sb(base, border, 2)
			hover = _sb(base.lightened(0.10), border.lightened(0.15), 2)
			pressed = _sb(base.lightened(0.16), border.lightened(0.25), 2)
		add_theme_stylebox_override("normal", normal)
		add_theme_stylebox_override("hover", hover)
		add_theme_stylebox_override("pressed", pressed)
		if is_commanded and not is_valid:
			modulate = Color(0.7, 0.7, 0.7)
		else:
			modulate = Color(1, 1, 1, 0.35 if not unit.alive else 1)

	func _ready() -> void:
		_press_timer = Timer.new()
		_press_timer.one_shot = true
		_press_timer.wait_time = LONG_PRESS_SEC
		_press_timer.timeout.connect(_on_long_timeout)
		add_child(_press_timer)
		button_down.connect(_on_button_down)
		button_up.connect(_on_button_up)
		pressed.connect(_on_pressed)

	func _on_button_down() -> void:
		_long_fired = false
		if _press_timer != null:
			_press_timer.start()

	func _on_button_up() -> void:
		if _press_timer != null:
			_press_timer.stop()

	func _on_long_timeout() -> void:
		_long_fired = true
		unit_long_pressed.emit(unit_uid)

	func _on_pressed() -> void:
		if _long_fired:
			_long_fired = false
			return
		unit_pressed.emit(unit_uid)

	static func _zh(sname: String) -> String:
		return STATUS_NAMES_ZH.get(sname, sname)

	func _sb(bg: Color, border: Color, border_w: int) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.set_border_width_all(border_w)
		sb.border_color = border
		sb.set_corner_radius_all(10)
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		return sb
