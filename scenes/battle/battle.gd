extends Control
## 战斗场景（占位）：回合制战斗核心将在 WS-4 实现（TurnManager 单例 + 站位/技能结算）。

func _ready() -> void:
	$Layout/VictoryButton.pressed.connect(_on_victory_pressed)
	$Layout/RetreatButton.pressed.connect(_on_retreat_pressed)
	var sample_monster := ConfigManager.get_entry("monsters", "ruins_skel_soldier")
	print("[Battle] 战斗已加载，示例怪物配置 = %s" % sample_monster.get("name", "（未找到）"))

func _on_victory_pressed() -> void:
	print("[Battle] 战斗胜利 → 结算")
	_change_state(GameMain.GameState.SETTLEMENT)

func _on_retreat_pressed() -> void:
	print("[Battle] 战斗撤退 → 回城")
	_change_state(GameMain.GameState.TOWN)

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().current_scene as GameMain
	if main != null:
		main.change_state(state)
