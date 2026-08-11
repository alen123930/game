extends Control
## 城镇场景（占位）：经营阶段入口。后续 WS-9 在此实现建筑交互/招募/养成。

func _ready() -> void:
	$Layout/ExploreButton.pressed.connect(_on_explore_pressed)
	$Layout/RecruitButton.pressed.connect(_on_recruit_pressed)
	var gold: Variant = _load_gold()
	print("[Town] 城镇已加载，当前金币 = %s" % gold)

func _on_explore_pressed() -> void:
	_change_state(GameMain.GameState.EXPLORATION)

func _on_recruit_pressed() -> void:
	print("[Town] 招募（占位）：雇佣厅功能将在城镇经营任务中实现")

func _load_gold() -> Variant:
	var data := SaveManager.load_game(1)
	return data.get("gold", 0)

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().current_scene as GameMain
	if main != null:
		main.change_state(state)
