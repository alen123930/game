extends Control
## 主菜单场景：新游戏 / 继续 / 设置 / 退出。
## 新游戏：通过 SaveManager 建立初始存档后进入城镇；继续：读取槽位 1 存档。

func _ready() -> void:
	$Layout/NewGameButton.pressed.connect(_on_new_game_pressed)
	$Layout/ContinueButton.pressed.connect(_on_continue_pressed)
	$Layout/SettingsButton.pressed.connect(_on_settings_pressed)
	$Layout/QuitButton.pressed.connect(_on_quit_pressed)
	print("[MainMenu] 主菜单已加载")

func _on_new_game_pressed() -> void:
	TownManager.reset_game()
	var data := {
		"gold": TownManager.gold,
		"heirlooms": TownManager.heirlooms,
		"roster": TownManager.roster,
		"buildings": TownManager.building_levels,
		"quest_progress": {},
	}
	if SaveManager.save_game(1, data):
		print("[MainMenu] 已建立新存档（槽位 1）")
	_change_state(GameMain.GameState.TOWN)

func _on_continue_pressed() -> void:
	if SaveManager.has_save(1):
		var data := SaveManager.load_game(1)
		if data.is_empty():
			print("[MainMenu] 槽位 1 无有效存档，请先开始新游戏")
		else:
			print("[MainMenu] 已读槽位 1 存档，继续游戏")
			_change_state(GameMain.GameState.TOWN)
	else:
		print("[MainMenu] 槽位 1 无存档，请先开始新游戏")

func _on_settings_pressed() -> void:
	print("[MainMenu] 设置（占位）：当前音量 = %s" % SaveManager.get_setting("master_volume", 0.8))

func _on_quit_pressed() -> void:
	get_tree().quit()

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().current_scene as GameMain
	if main != null:
		main.change_state(state)
