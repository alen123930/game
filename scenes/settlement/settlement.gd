extends Control
## 结算场景（WS-5 + WS-9，GDD 1.2 / 4.5 子集）
## 展示本次探索成果，调用 TownManager.settle_run 把金币/经验/伤病写回城镇，返回城镇形成闭环。

@onready var outcome_label: Label = %OutcomeLabel
@onready var detail_label: Label = %DetailLabel


func _ready() -> void:
	var payload: Dictionary = GameState.result_payload
	var outcome := String(payload.get("outcome", "retreat"))
	var rooms := int(payload.get("rooms_cleared", 0))
	var boss := bool(payload.get("boss_defeated", false))
	var torch := int(payload.get("torch", 0))

	var settle := TownManager.settle_run(payload)
	var gold := int(settle.get("gold_awarded", 0))
	var exp := int(settle.get("exp_awarded", 0))

	match outcome:
		"victory":
			outcome_label.text = "探索完成"
		"boss_retreat":
			outcome_label.text = "击破关底后撤退"
		_:
			outcome_label.text = "撤退"

	var narrative := Narrative.settlement_line(outcome)
	if narrative != "":
		outcome_label.text += "\n%s" % narrative

	detail_label.text = "任务类型：%s（%s）\n已探索房间：%d\n任务金币：%d（已入城镇，撤退无惩罚）\n经验：%d（按任务长度）\n关底 Boss：%s\n剩余火把：%d\n\n英雄状态（HP/压力）、伤病/疾病与怪癖已回写城镇。" % [
		GameState.get_quest_type_name(), GameState.quest_length, rooms, gold, exp, ("已击败" if boss else "未遭遇"), torch,
	]
	_append_affliction_report(settle)


func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)


## 结算页附加伤病/疾病/怪癖变化清单（GDD 3.5）。
func _append_affliction_report(settle: Dictionary) -> void:
	var lines: PackedStringArray = []
	for entry in settle.get("injuries", []):
		var names := PackedStringArray()
		for id in entry.get("ids", []):
			names.append(String(ConfigManager.get_entry("injuries", String(id)).get("name", id)))
		lines.append("【伤病】%s 受伤过重：%s" % [entry.get("name", ""), "、".join(names)])
	for entry in settle.get("diseases", []):
		lines.append("【疾病】%s 感染：%s" % [entry.get("name", ""), ConfigManager.get_entry("injuries", String(entry.get("id", ""))).get("name", entry.get("id", ""))])
	for entry in settle.get("quirks", []):
		var q: Dictionary = entry.get("quirk", {})
		var msg := "获得怪癖「%s」" % q.get("name", "")
		if entry.get("replaced", "") != "":
			msg += "（替换原「%s」）" % ConfigManager.get_entry("quirks", String(entry["replaced"])).get("name", entry["replaced"])
		lines.append("【怪癖】%s %s" % [entry.get("name", ""), msg])
	if not lines.is_empty():
		detail_label.text += "\n" + "\n".join(lines)


func _on_back_pressed() -> void:
	GameState.end_run()
	_change_state(GameMain.GameState.TOWN)


func _on_again_pressed() -> void:
	GameState.start_run(GameState.quest_length, GameState.quest_type)
	_change_state(GameMain.GameState.EXPLORATION)
