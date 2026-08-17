extends Control
## 遗迹地图探索场景（WS-5 核心，WS-19 对齐暗黑地牢）
## 地图渲染 + 房间互动（探索）+ 走廊（陷阱/障碍）+ 进入新房间自动侦查掷骰 + 4 类任务结算 + 火把衰减 + 遇敌/返回闭环。
## 场景切换经由 GameMain 状态机（EXPLORATION ↔ BATTLE ↔ SETTLEMENT）。
## WS-19 变更：移除「侦查→探索→检查」三步流程，侦查改为进入新房间自动掷骰（受火把/技能/怪癖/饰品修正）。

const CELL_SIZE := 130.0
const MARGIN := 60.0

var _dungeon: Dictionary = {}
var _room_nodes: Dictionary = {}      # room_id -> RoomTile
var _corridor_nodes: Dictionary = {}  # corridor_id -> CorridorTile
var _current_room_id: int = 0
var _selected_room_id: int = -1
var _pending_trap_room_id: int = -1   # 待处理陷阱的房间
var _pending_corridor_id: int = -1    # 待处理走廊（障碍/陷阱）
var _pending_target_room_id: int = -1 # 走廊处理完毕后要进入的房间

@onready var map_layer: Control = %MapLayer
@onready var torch_bar: ProgressBar = %TorchBar
@onready var torch_tier_label: Label = %TorchTierLabel
@onready var log_label: RichTextLabel = %LogLabel
@onready var room_label: Label = %RoomLabel
@onready var party_label: Label = %PartyLabel
@onready var supplies_label: Label = %SuppliesLabel
@onready var hint_label: Label = %HintLabel

const ACTIONS_BOX_PATH := NodePath("BottomBar/Actions")
const ACTION_PANEL_PATH := NodePath("BottomBar/ActionPanel")
const CHOICE_PANEL_PATH := NodePath("BottomBar/ChoicePanel")


func _ready() -> void:
	_dungeon = GameState.current_dungeon
	if _dungeon.is_empty():
		_dungeon = DungeonGenerator.generate(DataLoader.get_config("exploration.json"), GameState.quest_length, GameState.quest_type)
		GameState.current_dungeon = _dungeon
		_current_room_id = int(_dungeon.get("start_room", 0))
		GameState.current_pos = _current_room_id
		# 起始房自动揭示并侦查
		var start_room: Dictionary = _dungeon["rooms"][_current_room_id]
		start_room["revealed"] = true
		start_room["scouted"] = true
		_log_narrative_open()
	else:
		_current_room_id = GameState.current_pos
	_apply_battle_result()
	_rebuild_map()
	_rebuild_actions()
	_update_ui()


## 叙事开场白（GDD 5.2 / 5.5）：首次出发先显示序章，随后每次出发显示区域开场白。
func _log_narrative_open() -> void:
	var region_id := String(_dungeon.get("map_type", "ruins"))
	if not GameState.story_prologue_shown:
		GameState.story_prologue_shown = true
		for line in Narrative.get_act("prologue").get("intro", []):
			_log(String(line))
	var intro := Narrative.region_intro(region_id)
	if intro != "":
		_log(intro)
	_log("任务：%s（%s）" % [GameState.get_quest_type_name(), _length_name(GameState.quest_length)])


func _length_name(length: String) -> String:
	return {"short": "短", "medium": "中", "long": "长"}.get(length, "短")


## 切换场景：经由 GameMain 状态机（组内查找，兼容测试与正式运行）。
func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)


# ============ 地图渲染 ============

func _rebuild_map() -> void:
	for child in map_layer.get_children():
		child.queue_free()
	_room_nodes.clear()
	_corridor_nodes.clear()
	var cols: int = _dungeon.get("cols", 4)
	var rows: int = _dungeon.get("rows", 4)
	_draw_connections(cols, rows)
	_draw_corridors()
	for room in _dungeon.get("rooms", []):
		var rd: Dictionary = room
		var tile := RoomTile.new()
		tile.room_data = rd
		tile.size = Vector2(CELL_SIZE * 0.9, CELL_SIZE * 0.8)
		tile.position = Vector2(
			MARGIN + int(rd["pos"].x) * CELL_SIZE,
			MARGIN + int(rd["pos"].y) * CELL_SIZE
		)
		tile.pressed.connect(_on_room_pressed.bind(rd))
		map_layer.add_child(tile)
		_room_nodes[int(rd["id"])] = tile


func _draw_connections(cols: int, rows: int) -> void:
	# 简单连线：相邻房间间画线段（用 Line2D）
	var rooms_by_pos := {}
	for room in _dungeon.get("rooms", []):
		rooms_by_pos[Vector2i(int(room["pos"].x), int(room["pos"].y))] = room
	var seen := {}
	for room in _dungeon.get("rooms", []):
		var p: Vector2i = room["pos"]
		var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1)]
		for d in dirs:
			var np := p + d
			if rooms_by_pos.has(np):
				var key := "%d,%d-%d,%d" % [p.x, p.y, np.x, np.y]
				if seen.has(key):
					continue
				seen[key] = true
				var line := Line2D.new()
				line.width = 8.0
				line.default_color = Color(0.48, 0.40, 0.28, 0.6)
				line.add_point(Vector2(MARGIN + p.x * CELL_SIZE + CELL_SIZE * 0.45, MARGIN + p.y * CELL_SIZE + CELL_SIZE * 0.4))
				line.add_point(Vector2(MARGIN + np.x * CELL_SIZE + CELL_SIZE * 0.45, MARGIN + np.y * CELL_SIZE + CELL_SIZE * 0.4))
				map_layer.add_child(line)


func _draw_corridors() -> void:
	# 走廊节点：在房间连线中点绘制小型瓦片，显示陷阱/障碍内容（侦查揭示后可见）。
	for corridor in _dungeon.get("corridors", []):
		var tile := CorridorTile.new()
		tile.corridor_data = corridor
		tile.size = Vector2(CELL_SIZE * 0.7, CELL_SIZE * 0.42)
		var pos: Vector2 = corridor["pos"]
		tile.position = Vector2(
			MARGIN + pos.x * CELL_SIZE + CELL_SIZE * 0.15,
			MARGIN + pos.y * CELL_SIZE + CELL_SIZE * 0.1
		)
		map_layer.add_child(tile)
		_corridor_nodes[int(corridor["id"])] = tile


func _refresh_room_tiles() -> void:
	for room_id in _room_nodes:
		var tile: RoomTile = _room_nodes[room_id]
		tile.refresh(GameState.torch, room_id == _current_room_id, room_id == _selected_room_id)
	for corridor_id in _corridor_nodes:
		var tile: CorridorTile = _corridor_nodes[corridor_id]
		tile.refresh()


# ============ 探索动作 ============

func _rebuild_actions() -> void:
	var actions_box: HBoxContainer = get_node(ACTIONS_BOX_PATH)
	for child in actions_box.get_children():
		child.queue_free()

	var btn_explore := _make_action_button("探索当前房间")
	btn_explore.pressed.connect(_on_explore_pressed)
	var btn_torch := _make_action_button("使用火把 +25")
	btn_torch.pressed.connect(_on_use_torch_pressed)
	var btn_retreat := _make_action_button("撤退返回城镇")
	btn_retreat.pressed.connect(_on_retreat_pressed)

	actions_box.add_child(btn_explore)
	actions_box.add_child(btn_torch)
	actions_box.add_child(btn_retreat)


func _make_action_button(text: String) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(220, 72)
	btn.text = text
	return btn


## 探索：触发房间内容（战斗/奇物/宝箱/目标/安全/关底）。陷阱未处理时先处理陷阱。
## WS-19：侦查已改为进入房间自动掷骰，此处只负责房间互动。
func _on_explore_pressed() -> void:
	if not _can_act():
		return
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	if room.get("explored", false):
		_log("这个房间已经探索过了。")
		return
	if room.get("trapped", false) and not room.get("trap_disarmed", false):
		_open_trap_choice()
		return
	match String(room["type"]):
		"battle":
			_start_encounter(false)
		"boss":
			_start_encounter(true)
		"treasure":
			_open_treasure()
		"curio":
			_interact_curio()
		"goal":
			_complete_goal_room()
		"safe":
			_open_safe()
		"start":
			_log("这里是出发的房间，没有可探索的东西。")
		_:
			_log("房间里空无一物。")


## 奇物房互动（WS-19 节点类型对齐；完整奇物系统由 WS-23 独立任务实现）。
func _interact_curio() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	var loot_cfg: Dictionary = _dungeon.get("loot", {})
	var r := randf()
	if r < 0.3:
		var gold := randi_range(int(loot_cfg.get("event_gold_min", 60)), int(loot_cfg.get("event_gold_max", 200)))
		GameState.run_gold += gold
		var line := Narrative.event_line("loot")
		if line != "":
			_log(line)
		_log("你在奇物残骸中发现了一袋遗物，获得金币 %d。" % gold)
	elif r < 0.5:
		GameState.add_supply("torch", 1)
		GameState.add_torch(10)
		var line := Narrative.event_line("altar")
		if line != "":
			_log(line)
		_log("你点燃了祭坛上的蜡烛，火把 +10。")
	elif r < 0.7:
		var stress_roll := randi_range(0, 100)
		if stress_roll > 30:
			var line := Narrative.event_line("whisper")
			if line != "":
				_log(line)
			_log("奇物低语渗入你的意识……（压力略升）")
			for hero in GameState.party:
				hero["stress"] = mini(200, int(hero["stress"]) + randi_range(3, 8))
		else:
			var resist := Narrative.event_line("whisper_resist")
			_log(resist if resist != "" else "你抵住了耳边的低语。")
	else:
		GameState.damage_party(1, 3)
		var line := Narrative.event_line("collapse")
		if line != "":
			_log(line)
		_log("奇物突然爆发，队伍擦伤（少量伤害）。")
	# 收集任务：奇物也计入收集物
	if GameState.quest_type == "collect":
		GameState.collect_count += 1
		_log("收集进度：%d/%d" % [GameState.collect_count, GameState.get_collect_target()])
	_roll_event_afflictions()
	room["explored"] = true
	GameState.rooms_cleared += 1
	_refresh_room_tiles()
	_update_ui()


func _on_use_torch_pressed() -> void:
	if GameState.consume_supply("torch", 1):
		var restore: int = int(GameState.get_torch_config().get("item_restore", 25))
		GameState.add_torch(restore)
		_log("你点燃了一支火把，火光 +%d。" % restore)
	else:
		_log("没有火把了。")
	_update_ui()


func _on_retreat_pressed() -> void:
	_end_run(false)


func _can_act() -> bool:
	return GameState.run_active and _current_room_id >= 0


# ============ 陷阱 / 障碍（房间 + 走廊）============

func _open_trap_choice() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	_pending_trap_room_id = _current_room_id
	_open_choice("发现陷阱！如何处理？", [
		{"text": "使用铲子拆除", "disabled": not GameState.has_supply("shovel"), "cb": _on_shovel_disarm},
		{"text": "冒险徒手拆除", "cb": _on_risky_disarm},
		{"text": "直接触发（承受伤害）", "cb": _on_force_trigger_trap},
		{"text": "先不管", "cb": _on_ignore_trap},
	])


## 走廊陷阱处理：可拆除或触发，处理完毕后继续进入目标房间。
func _open_corridor_trap_choice(corridor: Dictionary, target_room_id: int) -> void:
	_pending_corridor_id = int(corridor["id"])
	_pending_target_room_id = target_room_id
	_open_choice("走廊中发现陷阱！如何处理？", [
		{"text": "使用铲子拆除", "disabled": not GameState.has_supply("shovel"), "cb": _on_shovel_disarm},
		{"text": "冒险徒手拆除", "cb": _on_risky_disarm},
		{"text": "直接触发（承受伤害）", "cb": _on_force_trigger_trap},
		{"text": "先不管，返回", "cb": _on_ignore_trap},
	])


## 走廊障碍处理：碎石/藤蔓需铲子清除，清除后继续进入目标房间。
func _open_obstacle_choice(corridor: Dictionary, target_room_id: int) -> void:
	_pending_corridor_id = int(corridor["id"])
	_pending_target_room_id = target_room_id
	var obstacle_cfg: Dictionary = _dungeon.get("obstacles", {})
	var kind: String = String(corridor.get("obstacle_kind", "debris"))
	var name := String(obstacle_cfg.get(kind + "_name", "障碍"))
	_open_choice("前方被%s挡住了去路！" % name, [
		{"text": "使用铲子清除", "disabled": not GameState.has_supply("shovel"), "cb": _on_clear_obstacle_shovel},
		{"text": "徒手尝试清除", "cb": _on_clear_obstacle_hand},
		{"text": "先返回", "cb": _on_ignore_trap},
	])


func _open_choice(title: String, options: Array) -> void:
	var choice_panel: VBoxContainer = get_node(CHOICE_PANEL_PATH)
	for child in choice_panel.get_children():
		child.queue_free()
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 26)
	choice_panel.add_child(t)
	for opt in options:
		var btn := _make_action_button(String(opt.get("text", "")))
		btn.disabled = bool(opt.get("disabled", false))
		btn.pressed.connect(opt["cb"])
		choice_panel.add_child(btn)
	get_node(ACTION_PANEL_PATH).visible = false
	choice_panel.visible = true


func _close_choice_panel() -> void:
	get_node(CHOICE_PANEL_PATH).visible = false
	get_node(ACTION_PANEL_PATH).visible = true
	_pending_trap_room_id = -1
	_pending_corridor_id = -1
	_pending_target_room_id = -1


func _on_shovel_disarm() -> void:
	if _pending_corridor_id >= 0:
		if not GameState.consume_supply("shovel", 1):
			_log("没有铲子。")
			return
		var trap_cfg: Dictionary = _dungeon.get("traps", {})
		var chance := float(trap_cfg.get("disarm_base_chance", 0.6)) + float(trap_cfg.get("shovel_bonus", 0.35))
		if randf() < chance:
			_dungeon["corridors"][_pending_corridor_id]["disarmed"] = true
			_log("你用铲子撬开了陷阱机关——陷阱被安全拆除。")
			_finish_corridor_pass()
		else:
			_trigger_corridor_trap()
		_close_choice_panel()
		_refresh_room_tiles()
		_update_ui()
		return
	if not _pending_trap_room_id >= 0:
		return
	if not GameState.consume_supply("shovel", 1):
		_log("没有铲子。")
		return
	var trap_cfg2: Dictionary = _dungeon.get("traps", {})
	var chance2 := float(trap_cfg2.get("disarm_base_chance", 0.6)) + float(trap_cfg2.get("shovel_bonus", 0.35))
	if randf() < chance2:
		_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
		_log("你用铲子撬开了陷阱机关——陷阱被安全解除。")
	else:
		_trigger_trap()
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()


func _on_risky_disarm() -> void:
	if _pending_corridor_id >= 0:
		var trap_cfg: Dictionary = _dungeon.get("traps", {})
		var chance := float(trap_cfg.get("disarm_base_chance", 0.6))
		if randf() < chance:
			_dungeon["corridors"][_pending_corridor_id]["disarmed"] = true
			_log("你屏息拆除了机关，走廊陷阱被解除。")
			_finish_corridor_pass()
		else:
			_trigger_corridor_trap()
		_close_choice_panel()
		_refresh_room_tiles()
		_update_ui()
		return
	if not _pending_trap_room_id >= 0:
		return
	var trap_cfg2: Dictionary = _dungeon.get("traps", {})
	var chance2 := float(trap_cfg2.get("disarm_base_chance", 0.6))
	if randf() < chance2:
		_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
		_log("你屏息拆除了机关，陷阱被解除。")
	else:
		_trigger_trap()
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()


## 直接触发陷阱：承受伤害后继续（WS-19 对齐「可拆除或触发」）。
func _on_force_trigger_trap() -> void:
	if _pending_corridor_id >= 0:
		_trigger_corridor_trap()
		_dungeon["corridors"][_pending_corridor_id]["disarmed"] = true
		_log("陷阱被触发，但队伍硬闯了过去。")
		_finish_corridor_pass()
		_close_choice_panel()
		_refresh_room_tiles()
		_update_ui()
		return
	if not _pending_trap_room_id >= 0:
		return
	_trigger_trap()
	_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()


func _on_ignore_trap() -> void:
	_log("你决定先不去动它。")
	_close_choice_panel()


func _on_clear_obstacle_shovel() -> void:
	if _pending_corridor_id < 0:
		return
	if not GameState.consume_supply("shovel", 1):
		_log("没有铲子。")
		return
	_dungeon["corridors"][_pending_corridor_id]["cleared"] = true
	_log("你用铲子清开了障碍，道路畅通。")
	_finish_corridor_pass()
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()


func _on_clear_obstacle_hand() -> void:
	if _pending_corridor_id < 0:
		return
	var obstacle_cfg: Dictionary = _dungeon.get("obstacles", {})
	var chance := float(obstacle_cfg.get("hand_clear_chance", 0.4))
	if randf() < chance:
		_dungeon["corridors"][_pending_corridor_id]["cleared"] = true
		_log("你徒手搬开了障碍，道路畅通。")
		_finish_corridor_pass()
	else:
		var stress := int(obstacle_cfg.get("hand_clear_stress", 4))
		_log("障碍纹丝不动，徒手尝试徒增疲惫（全队压力 +%d）。" % stress)
		for hero in GameState.party:
			hero["stress"] = mini(200, int(hero["stress"]) + stress)
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()


## 走廊处理完毕：进入目标房间（若仍有未清除障碍则阻断）。
func _finish_corridor_pass() -> void:
	if _pending_target_room_id < 0:
		return
	var target := _pending_target_room_id
	_pending_target_room_id = -1
	_move_to(target)


func _trigger_trap() -> void:
	var trap_cfg: Dictionary = _dungeon.get("traps", {})
	var dmg_min := int(trap_cfg.get("damage_min", 2))
	var dmg_max := int(trap_cfg.get("damage_max", 6))
	var res := GameState.damage_party(dmg_min, dmg_max)
	var stress_min := int(trap_cfg.get("stress_min", 5))
	var stress_max := int(trap_cfg.get("stress_max", 12))
	for hero in GameState.party:
		hero["stress"] = mini(200, int(hero["stress"]) + randi_range(stress_min, stress_max))
	if _pending_trap_room_id >= 0:
		_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
	var line := Narrative.event_line("trap")
	if line != "":
		_log(line)
	_log("陷阱被触发了！全队受到 %d 点伤害，压力上升。" % res["total_damage"])
	_check_party_dead()


func _trigger_corridor_trap() -> void:
	var trap_cfg: Dictionary = _dungeon.get("traps", {})
	var dmg_min := int(trap_cfg.get("damage_min", 2))
	var dmg_max := int(trap_cfg.get("damage_max", 6))
	var res := GameState.damage_party(dmg_min, dmg_max)
	var stress_min := int(trap_cfg.get("stress_min", 5))
	var stress_max := int(trap_cfg.get("stress_max", 12))
	for hero in GameState.party:
		hero["stress"] = mini(200, int(hero["stress"]) + randi_range(stress_min, stress_max))
	var line := Narrative.event_line("trap")
	if line != "":
		_log(line)
	_log("走廊陷阱被触发了！全队受到 %d 点伤害，压力上升。" % res["total_damage"])
	_check_party_dead()


func _check_party_dead() -> void:
	if not GameState.party_alive():
		_log("队伍全灭……")
		_end_run(false)


# ============ 房间内容 ============

func _start_encounter(is_boss: bool) -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	var enc_cfg: Dictionary = _dungeon.get("encounters", {})
	var monsters: Array = enc_cfg.get("ruins_monsters", [])
	var group := []
	if is_boss:
		group.append(enc_cfg.get("boss_id", "石颅"))
	else:
		# 遇敌规模随火把档位缩放（GDD 2.5：明亮 0.8 / 昏暗 1.0 / 黑暗 1.3）
		var tier: Dictionary = GameState.get_torch_tier()
		var factor := float(tier.get("encounter_factor", 1.0))
		var base := randi_range(int(enc_cfg.get("group_min", 1)), int(enc_cfg.get("group_max", 3)))
		var count := maxi(1, int(round(float(base) * factor)))
		for i in count:
			group.append(monsters[randi() % monsters.size()])
	room["explored"] = true
	GameState.current_pos = _current_room_id
	GameState.pending_battle = {
		"room_id": _current_room_id,
		"is_boss": is_boss,
		"monsters": group,
		"torch_tier": GameState.get_torch_tier().get("name", "昏暗"),
		"torch_value": GameState.torch,
	}
	var line := Narrative.event_line("boss" if is_boss else "encounter")
	if line != "":
		_log(line)
	_change_state(GameMain.GameState.BATTLE)


func _open_treasure() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	var loot_cfg: Dictionary = _dungeon.get("loot", {})
	var gold_min := int(loot_cfg.get("treasure_gold_min", 120))
	var gold_max := int(loot_cfg.get("treasure_gold_max", 400))
	var tier: Dictionary = GameState.get_torch_tier()
	var factor := float(tier.get("loot_factor", 1.0))
	var gold := int(round(randi_range(gold_min, gold_max) * factor))
	GameState.run_gold += gold
	room["looted"] = true
	room["explored"] = true
	GameState.rooms_cleared += 1
	var msg := "打开宝箱，获得金币 %d（火把档位奖励 ×%.2f）。" % [gold, factor]
	# 几率掉落补给
	var got := ""
	if randf() < float(loot_cfg.get("treasure_key_chance", 0.2)):
		GameState.add_supply("key", 1)
		got = "，还有一把钥匙"
	elif randf() < float(loot_cfg.get("treasure_shovel_chance", 0.2)):
		GameState.add_supply("shovel", 1)
		got = "，还有一把铲子"
	elif randf() < float(loot_cfg.get("treasure_torch_chance", 0.25)):
		GameState.add_supply("torch", 1)
		got = "，还有一支火把"
	var line := Narrative.event_line("treasure")
	if line != "":
		_log(line)
	_log(msg + got)
	# 收集任务：宝箱也计入收集物
	if GameState.quest_type == "collect":
		GameState.collect_count += 1
		_log("收集进度：%d/%d" % [GameState.collect_count, GameState.get_collect_target()])
	_refresh_room_tiles()
	_update_ui()


## 目标房：完成任务（探索任务到达目标房即完成；收集任务需收集物达标）。
func _complete_goal_room() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	match GameState.quest_type:
		"collect":
			var target := GameState.get_collect_target()
			if GameState.collect_count >= target:
				room["explored"] = true
				GameState.rooms_cleared += 1
				_log("你带着收集的遗物抵达目标房——任务完成！")
				_end_run(true)
			else:
				_log("目标房已到，但还缺 %d 件收集物（当前 %d/%d）。" % [target - GameState.collect_count, GameState.collect_count, target])
		_:
			room["explored"] = true
			GameState.rooms_cleared += 1
			_log("你抵达了目标房——任务完成！")
			_end_run(true)


func _roll_event_afflictions() -> void:
	# 1) 怪癖改变：先尝试替换一个已有怪癖，否则新获取
	if randf() < TownManager.get_event_quirk_chance():
		var hero := _random_party_hero()
		if not hero.is_empty():
			var res := TownManager.change_quirk(hero)
			if not res.get("ok", false):
				res = TownManager.gain_quirk(hero,
					"positive" if randf() < TownManager.get_event_quirk_positive_chance() else "negative")
			if res.get("ok", false):
				var q: Dictionary = res.get("quirk", {})
				var removed := String(res.get("removed", ""))
				if removed != "":
					var old_name: String = String(ConfigManager.get_entry("quirks", removed).get("name", removed))
					_log("异象改变心境：「%s」→「%s」。" % [old_name, q.get("name", "")])
				else:
					_log("异象赋予你新的感悟——获得怪癖「%s」。" % q.get("name", ""))
	# 2) 疾病感染：特定区域/事件
	if randf() < TownManager.get_event_disease_chance():
		var region := String(_dungeon.get("map_type", "ruins"))
		var hero2 := _random_party_hero()
		if not hero2.is_empty():
			var d := TownManager.apply_random_disease(hero2, region)
			if not d.is_empty():
				_log("污浊之气侵入「%s」——感染了疾病「%s」。" % [hero2.get("name", ""), d.get("name", "")])

func _random_party_hero() -> Dictionary:
	var alive: Array = []
	for h in GameState.party:
		if int(h.get("hp", 0)) > 0:
			alive.append(h)
	if alive.is_empty():
		return {}
	return alive[randi() % alive.size()]


func _open_safe() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	for hero in GameState.party:
		var heal := int(ceil(hero["max_hp"] * 0.1))
		hero["hp"] = mini(int(hero["max_hp"]), int(hero["hp"]) + heal)
		hero["stress"] = maxi(0, int(hero["stress"]) - 10)
	room["explored"] = true
	GameState.rooms_cleared += 1
	var line := Narrative.event_line("safe")
	if line != "":
		_log(line)
	_log("安全房：队伍在此喘息，回复少量生命并缓解压力。")
	_refresh_room_tiles()
	_update_ui()


# ============ 移动 / 门锁 / 走廊 ============

func _on_room_pressed(room: Dictionary) -> void:
	var room_id: int = room["id"]
	if room_id == _current_room_id:
		return
	if not _adjacent(room_id):
		_log("那个房间不在相邻位置。")
		return
	# 门锁：进入被锁房间需钥匙/铲子/盗贼撬锁（GDD 4.2）
	if room.get("locked_door", false):
		_try_unlock_door(room)
		return
	# 走廊检查：寻找当前房与目标房之间的走廊
	var corridor := _find_corridor(_current_room_id, room_id)
	if not corridor.is_empty():
		match String(corridor.get("type", "normal")):
			"obstacle":
				if not corridor.get("cleared", false):
					_open_obstacle_choice(corridor, room_id)
					return
			"trap":
				if not corridor.get("disarmed", false):
					_open_corridor_trap_choice(corridor, room_id)
					return
	_move_to(room_id)


func _find_corridor(a: int, b: int) -> Dictionary:
	for corridor in _dungeon.get("corridors", []):
		var ca := int(corridor["from"])
		var cb := int(corridor["to"])
		if (ca == a and cb == b) or (ca == b and cb == a):
			return corridor
	return {}


func _adjacent(room_id: int) -> bool:
	var conns: Array = _dungeon["rooms"][_current_room_id]["connections"]
	return conns.has(room_id)


func _try_unlock_door(room: Dictionary) -> void:
	var door_cfg: Dictionary = _dungeon.get("doors", {})
	# 优先自动尝试：钥匙 → 铲子 → 盗贼撬锁
	if door_cfg.get("key_opens", true) and GameState.consume_supply("key", 1):
		room["locked_door"] = false
		_log("你用钥匙打开了锁住的房门。")
		_move_to(int(room["id"]))
	elif door_cfg.get("shovel_breaks", true) and GameState.has_supply("shovel"):
		GameState.consume_supply("shovel", 1)
		if randf() < float(door_cfg.get("shovel_break_chance", 0.7)):
			room["locked_door"] = false
			_log("你用铲子硬生生砸开了门锁！")
			_move_to(int(room["id"]))
		else:
			_log("铲子没能砸开门锁（铲子已损坏）。")
	elif GameState.party_has_class("盗贼"):
		if randf() < float(door_cfg.get("rogue_unlock_chance", 0.6)):
			room["locked_door"] = false
			_log("盗贼轻松撬开了门锁。")
			_move_to(int(room["id"]))
		else:
			_log("盗贼撬锁失败了。")
	else:
		_log("门锁着。需要钥匙或铲子（或一名盗贼）。")
	_update_ui()


func _move_to(room_id: int) -> void:
	var prev_id := _current_room_id
	_current_room_id = room_id
	GameState.current_pos = room_id
	_apply_torch_decay_on_entry()
	_selected_room_id = room_id
	# WS-19：进入新房间自动侦查掷骰（受火把/技能/怪癖/饰品修正），成功揭示地图
	if room_id != prev_id:
		_roll_scout_on_entry(room_id)
	_show_room_info()
	_refresh_room_tiles()
	_update_ui()


## 进入新房间侦查掷骰（GDD 4.2 对齐暗黑地牢）。
## 成功：揭示当前房间类型，并揭示与相邻房间的走廊内容。
func _roll_scout_on_entry(room_id: int) -> void:
	var room: Dictionary = _dungeon["rooms"][room_id]
	if room.get("scouted", false):
		return
	if GameState.roll_scout():
		room["revealed"] = true
		room["scouted"] = true
		# 揭示相邻走廊
		for nb in room.get("connections", []):
			var corridor := _find_corridor(room_id, int(nb))
			if not corridor.is_empty():
				corridor["revealed"] = true
		var type_cfg: Dictionary = DataLoader.get_config("exploration.json").get("dungeon_types", {})
		var label := "未知"
		if type_cfg.has(String(room["type"])):
			label = type_cfg[String(room["type"])]["name"]
		var tier: Dictionary = GameState.get_torch_tier()
		_log("侦查成功：此房间是「%s」。（%s）" % [label, tier.get("desc", "")])
		if room.get("trapped", false):
			room["trap_visible"] = true
			_log("你注意到地面有机关的痕迹……")
	else:
		_log("侦查失败：黑暗中难以辨明，只看到模糊的轮廓。")
	_refresh_room_tiles()


## 战斗外每进入一个房间火把 −5（GDD 2.5）。
func _apply_torch_decay_on_entry() -> void:
	var decay: int = int(GameState.get_torch_config().get("decay_per_room", 5))
	GameState.add_torch(-decay)


func _apply_battle_result() -> void:
	var result: Dictionary = GameState.battle_result
	if result.is_empty():
		return
	GameState.battle_result = {}
	var room_id: int = int(result.get("room_id", -1))
	if room_id < 0 or room_id >= _dungeon.get("rooms", []).size():
		return
	var room: Dictionary = _dungeon["rooms"][room_id]
	if result.get("victory", false):
		_log("战斗胜利！敌人被清剿。")
		if result.get("is_boss", false):
			GameState.boss_defeated = true
			_log("关底 Boss 已被击败——任务核心威胁被打破。")
			# 关底有更高概率感染疾病（GDD 3.5：特定区域/事件感染）
			if randf() < TownManager.get_boss_disease_chance():
				var region := String(_dungeon.get("map_type", "ruins"))
				var hero := _random_party_hero()
				if not hero.is_empty():
					var d := TownManager.apply_random_disease(hero, region)
					if not d.is_empty():
						_log("关底瘴气弥漫——「%s」感染了疾病「%s」。" % [hero.get("name", ""), d.get("name", "")])
			_end_run(true)
		else:
			var gold := randi_range(50, 120)
			GameState.run_gold += gold
			_log("打扫战场，获得金币 %d。" % gold)
			GameState.rooms_cleared += 1
	else:
		_log("队伍撤退回了房间。")
	_update_ui()


# ============ 结算 ============

func _end_run(victory: bool) -> void:
	GameState.result_payload = {
		"outcome": "victory" if victory else ("boss_retreat" if GameState.boss_defeated else "retreat"),
		"rooms_cleared": GameState.rooms_cleared,
		"gold": GameState.run_gold,
		"boss_defeated": GameState.boss_defeated,
		"torch": GameState.torch,
		"party": GameState.party,
	}
	_change_state(GameMain.GameState.SETTLEMENT)


# ============ UI 更新 ============

func _show_room_info() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	var type_cfg: Dictionary = DataLoader.get_config("exploration.json").get("dungeon_types", {})
	var label := "未知"
	if room.get("revealed", false) and type_cfg.has(String(room["type"])):
		label = type_cfg[String(room["type"])]["name"]
	var pos: Vector2i = room["pos"]
	room_label.text = "当前位置：%s（%d,%d）" % [label, pos.x, pos.y]
	var hints := []
	if room.get("trapped", false) and room.get("trap_visible", false):
		hints.append("⚠ 有陷阱")
	if room.get("locked_door", false):
		hints.append("🔒 门被锁住")
	if room.get("scouted", false):
		hints.append("已侦查")
	if room.get("explored", false):
		hints.append("已探索")
	if GameState.quest_type == "collect":
		hints.append("收集 %d/%d" % [GameState.collect_count, GameState.get_collect_target()])
	hint_label.text = "线索：" + ("，".join(hints) if not hints.is_empty() else "暂无")


func _update_ui() -> void:
	torch_bar.value = GameState.torch
	torch_bar.max_value = float(GameState.get_torch_config().get("max", 100))
	var tier: Dictionary = GameState.get_torch_tier()
	torch_tier_label.text = "火把 %d ｜ %s" % [GameState.torch, tier.get("name", "昏暗")]
	party_label.text = "队伍：" + "  ".join(_party_summary())
	supplies_label.text = "补给：火把×%d  钥匙×%d  铲子×%d" % [
		int(GameState.supplies.get("torch", 0)),
		int(GameState.supplies.get("key", 0)),
		int(GameState.supplies.get("shovel", 0)),
	]
	_show_room_info()
	_refresh_room_tiles()


func _party_summary() -> PackedStringArray:
	var parts := PackedStringArray()
	for h in GameState.party:
		var s := "%s HP%d/%d 压力%d" % [h["name"], h["hp"], h["max_hp"], h["stress"]]
		parts.append(s)
	return parts


func _log(text: String) -> void:
	log_label.append_text(text + "\n")


# ============ 房间瓦片（地图上的房间节点）============

class RoomTile:
	extends Button
	## 单个房间瓦片：显示类型/未知状态，高亮当前房与选中房。

	var room_data: Dictionary = {}
	var _base_color := Color(0.16, 0.13, 0.10)

	func refresh(torch_value: int, is_current: bool, is_selected: bool) -> void:
		var revealed: bool = room_data.get("revealed", false)
		var explored: bool = room_data.get("explored", false)
		var type_cfg: Dictionary = DataLoader.get_config("exploration.json").get("dungeon_types", {})
		var type_name := String(room_data.get("type", "battle"))
		if revealed and type_cfg.has(type_name):
			text = type_cfg[type_name]["name"]
		else:
			text = "？？？"
		if explored:
			text += "\n✓"
		var col := _type_color(type_name)
		if not revealed:
			col = Color(0.15, 0.13, 0.11)
		if is_current:
			col = col.lightened(0.35)
		if is_selected:
			col = col.lightened(0.18)
		add_theme_stylebox_override("normal", _style(col))
		add_theme_stylebox_override("hover", _style(col.lightened(0.12)))
		add_theme_stylebox_override("pressed", _style(col.lightened(0.22)))
		add_theme_font_size_override("font_size", 20)

	func _type_color(type_name: String) -> Color:
		match type_name:
			"battle":
				return Color(0.35, 0.13, 0.13)
			"treasure":
				return Color(0.45, 0.35, 0.10)
			"curio":
				return Color(0.30, 0.20, 0.42)
			"goal":
				return Color(0.20, 0.32, 0.45)
			"boss":
				return Color(0.48, 0.10, 0.30)
			"safe":
				return Color(0.12, 0.28, 0.22)
			_:
				return Color(0.20, 0.18, 0.15)

	func _style(col: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_border_width_all(2)
		sb.border_color = Color(0.9, 0.78, 0.5, 0.5)
		sb.set_corner_radius_all(6)
		return sb


# ============ 走廊瓦片（地图上的走廊节点）============

class CorridorTile:
	extends Button
	## 走廊瓦片：显示陷阱/障碍内容（侦查揭示后可见），已清除的障碍标绿。

	var corridor_data: Dictionary = {}
	var _base_color := Color(0.20, 0.18, 0.15)

	func refresh() -> void:
		var revealed: bool = corridor_data.get("revealed", false)
		var ctype := String(corridor_data.get("type", "normal"))
		var obstacle_cfg: Dictionary = DataLoader.get_config("exploration.json").get("obstacles", {})
		match ctype:
			"trap":
				if corridor_data.get("disarmed", false):
					text = "陷阱(已拆)"
				elif revealed:
					text = "⚠ 陷阱"
				else:
					text = "···"
			"obstacle":
				if corridor_data.get("cleared", false):
					text = "已清"
				elif revealed:
					var kind := String(corridor_data.get("obstacle_kind", "debris"))
					text = "▣ %s" % String(obstacle_cfg.get(kind + "_name", "障碍"))
				else:
					text = "···"
			_:
				text = "···"
		var col := _corridor_color(ctype)
		if not revealed:
			col = Color(0.17, 0.15, 0.12)
		add_theme_stylebox_override("normal", _style(col))
		add_theme_stylebox_override("hover", _style(col.lightened(0.12)))
		add_theme_stylebox_override("pressed", _style(col.lightened(0.22)))
		add_theme_font_size_override("font_size", 14)

	func _corridor_color(ctype: String) -> Color:
		match ctype:
			"trap":
				return Color(0.45, 0.22, 0.12)
			"obstacle":
				return Color(0.35, 0.28, 0.15)
			_:
				return Color(0.22, 0.20, 0.16)

	func _style(col: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_border_width_all(2)
		sb.border_color = Color(0.6, 0.55, 0.45, 0.6)
		sb.set_corner_radius_all(6)
		return sb