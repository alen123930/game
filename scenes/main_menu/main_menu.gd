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
	GameState.reset_run()
	if SaveManager.save_slot(1):
		print("[MainMenu] 已建立新存档（槽位 1）")
	_change_state(GameMain.GameState.TOWN)

func _on_continue_pressed() -> void:
	# 优先恢复自动存档（最近的进度），否则回退到槽位 1。
	var loaded := SaveManager.load_autosave()
	if not loaded and SaveManager.has_save(1):
		loaded = SaveManager.load_slot(1)
	if not loaded:
		print("[MainMenu] 无有效存档，请先开始新游戏")
		return
	print("[MainMenu] 已读档，继续游戏")
	_change_state(_continue_scene())

## 读档后进入的场景：若任务进行中（地图存在）则回探索，否则回城镇。
func _continue_scene() -> int:
	if GameState.run_active and not GameState.current_dungeon.is_empty():
		return GameMain.GameState.EXPLORATION
	return GameMain.GameState.TOWN

func _on_settings_pressed() -> void:
	print("[MainMenu] 设置（占位）：当前音量 = %s" % SaveManager.get_setting("master_volume", 0.8))

func _on_quit_pressed() -> void:
	get_tree().quit()

func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)
