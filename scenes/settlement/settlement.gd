extends Control
## 结算场景（WS-5，GDD 1.2 / 4.5 子集）
## 展示本次探索的成果，返回城镇形成闭环。完整掉落/经济由 WS-10 填充。

@onready var outcome_label: Label = %OutcomeLabel
@onready var detail_label: Label = %DetailLabel


func _ready() -> void:
	var payload: Dictionary = GameState.result_payload
	var outcome := String(payload.get("outcome", "retreat"))
	var rooms := int(payload.get("rooms_cleared", 0))
	var gold := int(payload.get("gold", 0))
	var boss := bool(payload.get("boss_defeated", false))
	var torch := int(payload.get("torch", 0))

	match outcome:
		"victory":
			outcome_label.text = "探索完成"
		"boss_retreat":
			outcome_label.text = "击破关底后撤退"
		_:
			outcome_label.text = "撤退"

	detail_label.text = "已探索房间：%d\n获得金币：%d\n关底 Boss：%s\n剩余火把：%d\n\n（完整掉落与经济系统由 WS-10 填充）" % [
		rooms, gold, ("已击败" if boss else "未遭遇"), torch,
	]


func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)


func _on_back_pressed() -> void:
	GameState.end_run()
	_change_state(GameMain.GameState.TOWN)


func _on_again_pressed() -> void:
	GameState.start_run(GameState.quest_length)
	_change_state(GameMain.GameState.EXPLORATION)
