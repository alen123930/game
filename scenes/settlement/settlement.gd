extends Control
## 结算场景（占位）：经验/金币/掉落结算将在 WS-10 实现（EXP 公式见 GDD 4.5）。

func _ready() -> void:
	$Layout/BackButton.pressed.connect(_on_back_pressed)
	var loot := ConfigManager.get_entry("loot_tables", "1")
	print("[Settlement] 结算已加载，1 星掉落 = 金币 %s~%s，传承物 %s~%s" % [
		loot.get("gold_min", "?"), loot.get("gold_max", "?"),
		loot.get("heirloom_min", "?"), loot.get("heirloom_max", "?"),
	])

func _on_back_pressed() -> void:
	print("[Settlement] 返回城镇")
	_change_state(GameMain.GameState.TOWN)

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().current_scene as GameMain
	if main != null:
		main.change_state(state)
