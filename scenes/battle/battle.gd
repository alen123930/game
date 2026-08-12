extends Control
## 占位战斗场景（WS-5，WS-4 未就绪时保证闭环可走通）
## 展示遇敌信息，提供「战斗胜利（占位）」与「撤退」两个按钮。
## WS-4 落地后此场景将被真实战斗场景替换，衔接接口保留在 GameState.pending_battle / battle_result。

@onready var info_label: Label = %InfoLabel
@onready var status_label: Label = %StatusLabel


func _ready() -> void:
	var pb: Dictionary = GameState.pending_battle
	if pb.is_empty():
		info_label.text = "（无战斗数据）"
		return
	var monsters: Array = pb.get("monsters", [])
	var names := PackedStringArray()
	for m in monsters:
		names.append(String(m))
	var is_boss := bool(pb.get("is_boss", false))
	var tier := String(pb.get("torch_tier", "昏暗"))
	info_label.text = "%s！\n敌人：%s\n火把档位：%s（战斗逻辑待 WS-4 填充）" % [
		("关底战斗" if is_boss else "遭遇战"),
		"、".join(names),
		tier,
	]
	status_label.text = "这是占位战斗场景：点击下方按钮直接结算结果，真实回合制战斗由 WS-4 提供。"


func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)


func _on_win_pressed() -> void:
	var pb: Dictionary = GameState.pending_battle
	GameState.battle_result = {
		"victory": true,
		"room_id": int(pb.get("room_id", -1)),
		"is_boss": bool(pb.get("is_boss", false)),
	}
	GameState.pending_battle = {}
	_change_state(GameMain.GameState.EXPLORATION)


func _on_retreat_pressed() -> void:
	var pb: Dictionary = GameState.pending_battle
	GameState.battle_result = {
		"victory": false,
		"room_id": int(pb.get("room_id", -1)),
		"is_boss": bool(pb.get("is_boss", false)),
	}
	GameState.pending_battle = {}
	_change_state(GameMain.GameState.EXPLORATION)
