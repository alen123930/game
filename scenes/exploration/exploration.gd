extends Control
## 遗迹地图探索场景（WS-5 核心，GDD 4.2）
## 地图渲染 + 探索动作（侦查→探索→检查）+ 陷阱/门锁 + 火把衰减 + 遇敌/返回闭环。
## 场景切换经由 GameMain 状态机（EXPLORATION ↔ BATTLE ↔ SETTLEMENT）。

const CELL_SIZE := 130.0
const MARGIN := 60.0

var _dungeon: Dictionary = {}
var _room_nodes: Dictionary = {}      # room_id -> RoomTile
var _current_room_id: int = 0
var _selected_room_id: int = -1
var _pending_trap_room_id: int = -1   # 待处理陷阱的房间

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
		_dungeon = DungeonGenerator.generate(DataLoader.get_config("exploration.json"), GameState.quest_length)
		GameState.current_dungeon = _dungeon
		_current_room_id = int(_dungeon.get("start_room", 0))
		GameState.current_pos = _current_room_id
		# 起始房自动侦查
		var start_room: Dictionary = _dungeon["rooms"][_current_room_id]
		start_room["revealed"] = true
		start_room["scouted"] = true
	else:
		_current_room_id = GameState.current_pos
	_apply_battle_result()
	_rebuild_map()
	_rebuild_actions()
	_update_ui()


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
	var cols: int = _dungeon.get("cols", 4)
	var rows: int = _dungeon.get("rows", 4)
	_draw_connections(cols, rows)
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


func _refresh_room_tiles() -> void:
	for room_id in _room_nodes:
		var tile: RoomTile = _room_nodes[room_id]
		tile.refresh(GameState.torch, room_id == _current_room_id, room_id == _selected_room_id)


# ============ 探索动作 ============

func _rebuild_actions() -> void:
	var actions_box: HBoxContainer = get_node(ACTIONS_BOX_PATH)
	for child in actions_box.get_children():
		child.queue_free()

	var btn_scout := _make_action_button("侦查")
	btn_scout.pressed.connect(_on_scout_pressed)
	var btn_explore := _make_action_button("探索")
	btn_explore.pressed.connect(_on_explore_pressed)
	var btn_inspect := _make_action_button("检查")
	btn_inspect.pressed.connect(_on_inspect_pressed)
	var btn_torch := _make_action_button("使用火把 +25")
	btn_torch.pressed.connect(_on_use_torch_pressed)
	var btn_retreat := _make_action_button("撤退返回城镇")
	btn_retreat.pressed.connect(_on_retreat_pressed)

	actions_box.add_child(btn_scout)
	actions_box.add_child(btn_explore)
	actions_box.add_child(btn_inspect)
	actions_box.add_child(btn_torch)
	actions_box.add_child(btn_retreat)


func _make_action_button(text: String) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(180, 72)
	btn.text = text
	return btn


## 侦查：受火把档位影响的成功率，成功则揭示房间类型与陷阱痕迹（GDD 4.2）。
func _on_scout_pressed() -> void:
	if not _can_act():
		return
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	var expl: Dictionary = _dungeon.get("exploration", {})
	var cost := int(expl.get("scout_cost_torch", 1))
	if GameState.torch <= 0:
		_log("火把已熄灭，黑暗中什么也看不清。")
		return
	GameState.add_torch(-cost)
	var tier: Dictionary = GameState.get_torch_tier()
	var tier_key := _tier_key(String(tier.get("name", "昏暗")))
	var scout_chance := float(expl.get("scout_success_" + tier_key, 0.6))
	if randf() < scout_chance:
		room["revealed"] = true
		room["scouted"] = true
		var type_cfg: Dictionary = DataLoader.get_config("exploration.json").get("dungeon_types", {})
		var type_name: String = String(room["type"])
		var label := "未知"
		if type_cfg.has(type_name):
			label = type_cfg[type_name]["name"]
		_log("侦查成功：此房间是「%s」。（%s）" % [label, tier.get("desc", "")])
		if room.get("trapped", false):
			room["trap_visible"] = true
			_log("你注意到地面有机关的痕迹……")
	else:
		_log("侦查失败：黑暗中难以辨明，只看到模糊的轮廓。")
	_refresh_room_tiles()
	_update_ui()
	_autosave()


## 探索：触发房间内容（战斗/宝箱/事件/安全/关底）。陷阱未处理时先处理陷阱。
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
		"event":
			_trigger_event()
		"safe":
			_open_safe()
		"start":
			_log("这里是出发的房间，没有可探索的东西。")
		_:
			_log("房间里空无一物。")


## 检查：不消耗火把，进一步观察陷阱与门锁，可收集线索（GDD 4.2「可检查后决定进或退」）。
func _on_inspect_pressed() -> void:
	if not _can_act():
		return
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	if room.get("trapped", false) and not room.get("trap_visible", false):
		if randf() < 0.7:
			room["trap_visible"] = true
			_log("仔细检查后发现：地面上有陷阱的痕迹！")
		else:
			_log("你检查了一圈，没有明显异样。")
	elif room.get("trapped", false):
		_log("陷阱仍在原处。你可以用铲子解除它。")
	elif room.get("locked_door", false):
		_log("通往此房间的门被锁住了。需要钥匙，或用铲子破开（盗贼也可尝试撬锁）。")
	else:
		_log("没有更多线索。")
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
	_autosave()


func _on_retreat_pressed() -> void:
	_end_run(false)


func _can_act() -> bool:
	return GameState.run_active and _current_room_id >= 0


# ============ 陷阱 ============

func _open_trap_choice() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	_pending_trap_room_id = _current_room_id
	var choice_panel: VBoxContainer = get_node(CHOICE_PANEL_PATH)
	for child in choice_panel.get_children():
		child.queue_free()
	var title := Label.new()
	title.text = "发现陷阱！如何处理？"
	title.add_theme_font_size_override("font_size", 26)
	choice_panel.add_child(title)

	var btn_shovel := _make_action_button("使用铲子解除")
	btn_shovel.disabled = not GameState.has_supply("shovel")
	btn_shovel.pressed.connect(_on_shovel_disarm)
	var btn_risky := _make_action_button("冒险徒手解除")
	btn_risky.pressed.connect(_on_risky_disarm)
	var btn_ignore := _make_action_button("先不管，探索房间")
	btn_ignore.pressed.connect(_on_ignore_trap)
	choice_panel.add_child(btn_shovel)
	choice_panel.add_child(btn_risky)
	choice_panel.add_child(btn_ignore)
	get_node(ACTION_PANEL_PATH).visible = false
	choice_panel.visible = true


func _close_choice_panel() -> void:
	get_node(CHOICE_PANEL_PATH).visible = false
	get_node(ACTION_PANEL_PATH).visible = true
	_pending_trap_room_id = -1


func _on_shovel_disarm() -> void:
	if not _pending_trap_room_id >= 0:
		return
	if not GameState.consume_supply("shovel", 1):
		_log("没有铲子。")
		return
	var trap_cfg: Dictionary = _dungeon.get("traps", {})
	var chance := float(trap_cfg.get("disarm_base_chance", 0.6)) + float(trap_cfg.get("shovel_bonus", 0.35))
	if randf() < chance:
		_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
		_log("你用铲子撬开了陷阱机关——陷阱被安全解除。")
	else:
		_trigger_trap()
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()
	_autosave()


func _on_risky_disarm() -> void:
	if not _pending_trap_room_id >= 0:
		return
	var trap_cfg: Dictionary = _dungeon.get("traps", {})
	var chance := float(trap_cfg.get("disarm_base_chance", 0.6))
	if randf() < chance:
		_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
		_log("你屏息拆除了机关，陷阱被解除。")
	else:
		_trigger_trap()
	_close_choice_panel()
	_refresh_room_tiles()
	_update_ui()
	_autosave()


func _on_ignore_trap() -> void:
	_log("你决定先不去动它。")
	_close_choice_panel()


func _trigger_trap() -> void:
	var trap_cfg: Dictionary = _dungeon.get("traps", {})
	var dmg_min := int(trap_cfg.get("damage_min", 2))
	var dmg_max := int(trap_cfg.get("damage_max", 6))
	var res := GameState.damage_party(dmg_min, dmg_max)
	var stress_min := int(trap_cfg.get("stress_min", 5))
	var stress_max := int(trap_cfg.get("stress_max", 12))
	for hero in GameState.party:
		hero["stress"] = mini(200, int(hero["stress"]) + randi_range(stress_min, stress_max))
	_dungeon["rooms"][_pending_trap_room_id]["trap_disarmed"] = true
	_log("陷阱被触发了！全队受到 %d 点伤害，压力上升。" % res["total_damage"])
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
	_change_state(GameMain.GameState.BATTLE)


func _autosave() -> void:
	# 自动存档：每节点/每次行动后写入 autosave.json（GDD 7.1）
	if GameState.run_active:
		SaveManager.autosave()


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
	var loot_cfg2: Dictionary = loot_cfg
	var got := ""
	if randf() < float(loot_cfg2.get("treasure_key_chance", 0.2)):
		GameState.add_supply("key", 1)
		got = "，还有一把钥匙"
	elif randf() < float(loot_cfg2.get("treasure_shovel_chance", 0.2)):
		GameState.add_supply("shovel", 1)
		got = "，还有一把铲子"
	elif randf() < float(loot_cfg2.get("treasure_torch_chance", 0.25)):
		GameState.add_supply("torch", 1)
		got = "，还有一支火把"
	_log(msg + got)
	_refresh_room_tiles()
	_update_ui()
	_autosave()


func _trigger_event() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	var loot_cfg: Dictionary = _dungeon.get("loot", {})
	var r := randf()
	if r < 0.3:
		var gold := randi_range(int(loot_cfg.get("event_gold_min", 60)), int(loot_cfg.get("event_gold_max", 200)))
		GameState.run_gold += gold
		_log("你在残骸中发现了一袋遗物，获得金币 %d。" % gold)
	elif r < 0.5:
		GameState.add_supply("torch", 1)
		GameState.add_torch(10)
		_log("你点燃了祭坛上的蜡烛，火把 +10。")
	elif r < 0.7:
		var stress_roll := randi_range(0, 100)
		if stress_roll > 30:
			_log("墙壁的低语渗入你的意识……（占位：压力略升）")
			for hero in GameState.party:
				hero["stress"] = mini(200, int(hero["stress"]) + randi_range(3, 8))
		else:
			_log("你抵住了耳边的低语。")
	else:
		GameState.damage_party(1, 3)
		_log("地板突然塌陷，队伍擦伤（少量伤害）。")
	room["explored"] = true
	GameState.rooms_cleared += 1
	_refresh_room_tiles()
	_update_ui()
	_autosave()


func _open_safe() -> void:
	var room: Dictionary = _dungeon["rooms"][_current_room_id]
	for hero in GameState.party:
		var heal := int(ceil(hero["max_hp"] * 0.1))
		hero["hp"] = mini(int(hero["max_hp"]), int(hero["hp"]) + heal)
		hero["stress"] = maxi(0, int(hero["stress"]) - 10)
	room["explored"] = true
	GameState.rooms_cleared += 1
	_log("安全房：队伍在此喘息，回复少量生命并缓解压力。")
	_refresh_room_tiles()
	_update_ui()
	_autosave()


# ============ 移动 / 门锁 ============

func _on_room_pressed(room: Dictionary) -> void:
	var room_id: int = room["id"]
	if room_id == _current_room_id:
		return
	if not room.get("revealed", false) and not _adjacent(room_id):
		_log("那个房间尚未被侦查，且不在相邻位置。")
		return
	# 门锁：进入被锁房间需钥匙/铲子/盗贼撬锁（GDD 4.2）
	if room.get("locked_door", false):
		_try_unlock_door(room)
		return
	_move_to(room_id)


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
	_current_room_id = room_id
	GameState.current_pos = room_id
	_apply_torch_decay_on_entry()
	_selected_room_id = room_id
	_show_room_info()
	_refresh_room_tiles()
	_update_ui()
	_autosave()


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
			_log("关底 Boss 已被击败——遗迹的黑暗核心被打破。")
			_end_run(true)
		else:
			var gold := randi_range(50, 120)
			GameState.run_gold += gold
			_log("打扫战场，获得金币 %d。" % gold)
			GameState.rooms_cleared += 1
	else:
		_log("队伍撤退回了房间。")
	_update_ui()
	_autosave()


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
	_autosave()
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


## 火把档位名 → 配置键名（明亮/昏暗/黑暗）。
func _tier_key(name: String) -> String:
	match name:
		"明亮":
			return "bright"
		"黑暗":
			return "dark"
		_:
			return "dim"


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
			"event":
				return Color(0.30, 0.20, 0.42)
			"safe":
				return Color(0.12, 0.28, 0.22)
			"boss":
				return Color(0.48, 0.10, 0.30)
			_:
				return Color(0.20, 0.18, 0.15)

	func _style(col: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_border_width_all(2)
		sb.border_color = Color(0.9, 0.78, 0.5, 0.5)
		sb.set_corner_radius_all(6)
		return sb
