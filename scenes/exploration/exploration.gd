extends Control
## 地图探索场景（占位）：程序化地图与房间循环将在 WS-5 实现。

func _ready() -> void:
	$Layout/EncounterButton.pressed.connect(_on_encounter_pressed)
	$Layout/RetreatButton.pressed.connect(_on_retreat_pressed)
	print("[Exploration] 地图探索已加载")

func _on_encounter_pressed() -> void:
	_change_state(GameMain.GameState.BATTLE)

func _on_retreat_pressed() -> void:
	print("[Exploration] 撤退回城（奖励按 70% 结算，此处占位）")
	_change_state(GameMain.GameState.TOWN)

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().current_scene as GameMain
	if main != null:
		main.change_state(state)
