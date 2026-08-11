extends Control
## 城镇占位场景（WS-5 阶段仅作出发/返回闭环用；完整城镇经营由 WS-9 填充）。
## 选择任务长度（短/中/长）后出发进入遗迹探索。

var _selected_length := "short"

@onready var length_label: Label = %LengthLabel
@onready var torch_label: Label = %TorchLabel
@onready var party_list: VBoxContainer = %PartyList


func _ready() -> void:
	_update_ui()


func _on_short_pressed() -> void:
	_selected_length = "short"
	_update_ui()


func _on_medium_pressed() -> void:
	_selected_length = "medium"
	_update_ui()


func _on_long_pressed() -> void:
	_selected_length = "long"
	_update_ui()


func _on_start_pressed() -> void:
	GameState.start_run(_selected_length)
	GameState.request_scene(GameState.SCENE_DUNGEON)


func _update_ui() -> void:
	if length_label == null:
		return
	var names := {"short": "短（3战/1宝/2事件）", "medium": "中（5战/2宝/3事件）", "long": "长（7战/3宝/4事件/Boss）"}
	length_label.text = "任务长度：%s" % names[_selected_length]
	torch_label.text = "火把初始：%d" % GameState.get_torch_config().get("start", 75)
	for child in party_list.get_children():
		child.queue_free()
	for hero in GameState.PLACEHOLDER_PARTY:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = "%s（%s）" % [hero["name"], hero["class"]]
		var hp_label := Label.new()
		hp_label.text = "HP %d/%d" % [hero["hp"], hero["max_hp"]]
		row.add_child(name_label)
		row.add_child(hp_label)
		party_list.add_child(row)
