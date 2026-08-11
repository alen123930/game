extends Node
## Main 状态机（GDD 7.1）：城镇 ↔ 地图探索 ↔ 战斗 ↔ 结算
## 以单一宿主节点切换子场景，GameState.scene_requested 驱动状态转移。

enum State { TOWN, DUNGEON, BATTLE, RESULT }

const SCENE_PATHS := {
	"town": "res://scenes/town/town.tscn",
	"dungeon": "res://scenes/dungeon/dungeon_explore.tscn",
	"battle": "res://scenes/battle/battle_placeholder.tscn",
	"result": "res://scenes/result/result.tscn",
}

var current_state: State = State.TOWN
var current_scene: Node = null

@onready var host: Node = $SceneHost


func _ready() -> void:
	GameState.scene_requested.connect(_on_scene_requested)
	_switch("town")


func _on_scene_requested(scene_path: String) -> void:
	_switch_path(scene_path)


## 切换到指定场景（先卸载旧的，加载新的）。
func _switch(scene_id: String) -> void:
	if not SCENE_PATHS.has(scene_id):
		push_warning("[Main] 未知场景: %s" % scene_id)
		return
	_switch_path(SCENE_PATHS[scene_id])


func _switch_path(scene_path: String) -> void:
	if current_scene != null:
		current_scene.queue_free()
		current_scene = null
	var scene := ResourceLoader.load(scene_path)
	if scene == null:
		push_warning("[Main] 场景加载失败: %s" % scene_path)
		return
	current_scene = scene.instantiate()
	host.add_child(current_scene)
	match scene_path:
		SCENE_PATHS["town"]:
			current_state = State.TOWN
		SCENE_PATHS["dungeon"]:
			current_state = State.DUNGEON
		SCENE_PATHS["battle"]:
			current_state = State.BATTLE
		SCENE_PATHS["result"]:
			current_state = State.RESULT
