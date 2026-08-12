extends Node
## Main 状态机（GDD 7.1 场景组织）
##
## 负责加载并切换各玩法场景：主菜单 → 城镇 ↔ 地图探索 ↔ 战斗 ↔ 结算。
## 场景分离：每个状态对应 scenes/<state>/ 下独立场景，切换时实例化/释放。

class_name GameMain

enum GameState {
	MAIN_MENU,
	TOWN,
	EXPLORATION,
	BATTLE,
	SETTLEMENT,
}

const STATE_SCENES := {
	GameState.MAIN_MENU: "res://scenes/main_menu/MainMenu.tscn",
	GameState.TOWN: "res://scenes/town/Town.tscn",
	GameState.EXPLORATION: "res://scenes/exploration/Exploration.tscn",
	GameState.BATTLE: "res://scenes/battle/Battle.tscn",
	GameState.SETTLEMENT: "res://scenes/settlement/Settlement.tscn",
}

const STATE_NAMES := {
	GameState.MAIN_MENU: "主菜单",
	GameState.TOWN: "城镇",
	GameState.EXPLORATION: "地图探索",
	GameState.BATTLE: "战斗",
	GameState.SETTLEMENT: "结算",
}

const MAIN_GROUP := "game_main"

var _current_state: int = -1
var _current_scene: Node = null

func _ready() -> void:
	# 注册到组，供各场景通过 get_first_node_in_group 查找本状态机（兼容测试与正式运行）。
	add_to_group(MAIN_GROUP)
	change_state(GameState.MAIN_MENU)

func get_current_state() -> int:
	return _current_state

func change_state(state: int) -> void:
	if not STATE_SCENES.has(state):
		push_error("Main: 未知游戏状态 %d" % state)
		return
	if state == _current_state:
		return

	if _current_scene != null:
		_current_scene.queue_free()
		_current_scene = null

	_current_state = state
	var scene: PackedScene = load(STATE_SCENES[state])
	if scene == null:
		push_error("Main: 无法加载场景 %s" % STATE_SCENES[state])
		return
	_current_scene = scene.instantiate()
	add_child(_current_scene)
	print("[Main] 状态切换 → %s" % STATE_NAMES[state])
