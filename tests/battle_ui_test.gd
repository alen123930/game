extends Node
## 战斗触屏 UI 测试（WS-8 完成标准）
## 运行：godot --headless --path . res://tests/battle_ui_test.tscn
##
## 覆盖（GDD 2.11 / 7.3）：
##  1. 自动选择首位可行动英雄
##  2. 技能可用性即时置灰（站位不符 → 置灰；站位正确 → 可用）
##  3. 单指流：选技能 → 高亮可攻击目标 → 点目标执行
##  4. 先选技能再选施法者：持械状态下点选其他可用英雄切换施法者
##  5. 防御（跳过行动）后自动切换选择
##  6. 结束回合推进战斗，一局完整战斗获胜（选人→选技→攻击→胜利）
##  7. 长按显示详细属性
##  8. 撤退二次确认（取消 / 确认）
##  9. 道具面板开关
##
## 全部骰子通过 debug_force_rolls 固定，结果确定。

var _failures := 0
var _battle: Node = null


func _ready() -> void:
	await get_tree().process_frame
	await _test_layout()
	await _test_interactive_battle_win()
	await _test_long_press_and_retreat()
	print("[BattleUITest] %s（失败 %d 项）" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[BattleUITest]   ok   " + msg)
	else:
		_failures += 1
		print("[BattleUITest]   FAIL " + msg)


# ------------------------------------------------------------------
# 布局：站位格不重叠/不越界，底部按钮热区达标（GDD 7.3）
# ------------------------------------------------------------------

func _test_layout() -> void:
	GameState.party = []
	GameState.pending_battle = {"room_id": 0, "is_boss": false, "monsters": ["ruins_skel_soldier"], "seed": 3}
	_battle = load("res://scenes/battle/Battle.tscn").instantiate()
	add_child(_battle)
	await get_tree().process_frame
	await get_tree().process_frame

	var field: Control = _battle.field
	var frect := field.get_rect()
	_check(frect.size.x > 1600.0 and frect.size.y > 500.0, "站位区尺寸正确（%dx%d）" % [int(frect.size.x), int(frect.size.y)])

	var slots: Array = []
	for uid in _battle._slots:
		slots.append(_battle._slots[uid])
	_check(slots.size() == 5, "生成站位格：4 英雄 + 1 怪物 = 5 个（实际 %d）" % slots.size())

	var ok_in_bounds := true
	for s in slots:
		var sr := (s as Control).get_rect()
		var global_sr := Rect2(sr.position + (s as Control).get_parent().position, sr.size)
		if global_sr.position.x < 0 or global_sr.end.x > 1920.0:
			ok_in_bounds = false
	_check(ok_in_bounds, "站位格水平不越出 1920 设计宽度")

	# 同列不重叠：按 x 分两列，列内 rect 两两不相交
	var columns := {0: [], 1: []}
	for s in slots:
		var sr := Rect2((s as Control).position, (s as Control).size)
		columns[int(sr.position.x > 1000.0)].append(sr)
	var no_overlap := true
	for col in columns:
		for i in columns[col].size():
			for j in range(i + 1, columns[col].size()):
				if (columns[col][i] as Rect2).intersects(columns[col][j]):
					no_overlap = false
	_check(no_overlap, "同侧站位格两两不重叠")

	# 底部按钮：热区 ≥150px（设计分辨率下 ≈54dp ≥44dp），间距 ≥24px（≈8dp）
	var min_size := 100000.0
	for b in _battle.get_node("SafeArea/BottomBar/BarHBox/ActionGrid").get_children():
		var btn := b as Button
		min_size = minf(min_size, btn.custom_minimum_size.x)
		min_size = minf(min_size, btn.custom_minimum_size.y)
	_check(min_size >= 150.0, "底部按钮最小热区 %dpx ≥150px（≈54dp ≥44dp）" % int(min_size))
	var hero_sep: int = _battle.hero_row.get_theme_constant("separation")
	var skill_sep: int = _battle.skill_row.get_theme_constant("separation")
	_check(hero_sep >= 24 and skill_sep >= 24, "按钮间距 ≥24px（≈8dp）：英雄栏 %d / 技能栏 %d" % [hero_sep, skill_sep])
	var bar: Control = _battle.get_node("SafeArea/BottomBar")
	_check(bar.size.y >= 400.0, "底部操作栏高度 %dpx" % int(bar.size.y))

	_battle.queue_free()
	await get_tree().process_frame
	_battle = null


# ------------------------------------------------------------------
# 场景 A：交互打完整局并胜利
# ------------------------------------------------------------------

func _test_interactive_battle_win() -> void:
	# 2 圣骑士（1/2 号位）+ 2 猎人（3/4 号位） vs 1 骷髅兵
	GameState.party = [
		{"name": "圣骑士", "class": "圣骑士"},
		{"name": "圣骑士", "class": "圣骑士"},
		{"name": "猎人", "class": "猎人"},
		{"name": "猎人", "class": "猎人"},
	]
	GameState.pending_battle = {"room_id": 5, "is_boss": false, "monsters": ["ruins_skel_soldier"], "seed": 20240812}
	GameState.battle_result = {}
	_battle = load("res://scenes/battle/Battle.tscn").instantiate()
	add_child(_battle)
	await get_tree().process_frame
	await get_tree().process_frame

	var k1 := TurnManager.heroes[0]
	var k2 := TurnManager.heroes[1]
	var skel := TurnManager.monsters[0]

	_check(TurnManager.heroes.size() == 4 and TurnManager.monsters.size() == 1, "开战：4 英雄 vs 1 怪物")
	_check(k1.position == 1 and k2.position == 2, "骑士站位 1/2 号位")
	_check(skel.position == 1, "骷髅兵站位 1 号位")

	var st: Dictionary = _battle._get_debug_state()
	_check(st["phase"] == 0, "进入指令阶段（COMMAND）")
	_check(st["selected_hero_uid"] == k1.uid, "自动选中首位可行动英雄（圣骑士①）")

	# 技能置灰：knight_heal 来源站位 [2,3,4]，骑士在 1 号位 → 置灰
	_check(_battle._is_skill_greyed("knight_heal"), "knight_heal 因站位不符即时置灰")
	_check(not _battle._is_skill_greyed("knight_smite"), "knight_smite 可用（不置灰）")

	# 自施法技能：目标 = 施法者自身
	_battle._on_skill_selected("knight_guard")
	st = _battle._get_debug_state()
	_check(st["armed_skill"] == "knight_guard", "自施法技能已持械")
	_check(st["valid_targets"] == [k1.uid], "自施法目标 = 自身")
	_battle._on_skill_selected("knight_guard")
	_check(_battle._get_debug_state()["armed_skill"] == "", "再点同技能取消持械")

	# 单指流：点选技能 → 高亮可攻击目标
	_battle._on_skill_selected("knight_smite")
	st = _battle._get_debug_state()
	_check(st["armed_skill"] == "knight_smite", "技能已持械")
	_check(st["valid_targets"] == [skel.uid], "高亮目标 = 骷髅兵")

	# 先选技能再选施法者：持械状态下点选另一名可用骑士 → 切换施法者
	_battle._on_hero_button_pressed(k2.uid)
	st = _battle._get_debug_state()
	_check(st["selected_hero_uid"] == k2.uid, "施法者切换为圣骑士②")
	_check(st["armed_skill"] == "knight_smite", "持械技能保留（先选技能再选施法者）")

	# 切回圣骑士①并防御（跳过行动）
	_battle._on_hero_button_pressed(k1.uid)
	st = _battle._get_debug_state()
	_check(st["selected_hero_uid"] == k1.uid and st["armed_skill"] == "knight_smite", "再次切换回圣骑士①（技能仍持械）")
	_battle._on_defend_pressed()
	st = _battle._get_debug_state()
	_check(k1.uid in st["commanded"], "圣骑士① 防御已下令")
	_check(st["selected_hero_uid"] == k2.uid, "防御后自动切换选中圣骑士②")

	# 圣骑士②：技能 → 目标 → 执行（一记击杀）
	_battle._on_skill_selected("knight_smite")
	skel.hp = 1
	# 掷骰序：行动顺序(5) → 圣骑士② 命中/暴击/伤害
	# WS-18：怪物 0 HP 即死留尸（无 DBR 掷骰）
	TurnManager.debug_force_rolls([1, 100, 1, 1, 1, 1, 99, 1])
	_battle._on_target_selected(skel.uid)
	st = _battle._get_debug_state()
	_check(k2.uid in st["commanded"], "圣骑士② 攻击已下令")
	_check(TurnManager.debug_pending_rolls() == 8, "掷骰队列已排好（确定性）")

	_battle._on_end_turn_pressed()
	await get_tree().process_frame

	_check(TurnManager.debug_pending_rolls() == 0, "掷骰队列全部消费")
	st = _battle._get_debug_state()
	_check(st["battle_over"], "战斗已结束")
	_check(st["victory"], "英雄获胜")
	_check(GameState.battle_result.get("victory", false), "GameState.battle_result.victory = true")
	_check(GameState.battle_result.get("room_id", -1) == 5, "battle_result.room_id 正确回写")

	_battle.queue_free()
	await get_tree().process_frame
	_battle = null


# ------------------------------------------------------------------
# 场景 B：长按详情 + 撤退二次确认 + 道具面板
# ------------------------------------------------------------------

func _test_long_press_and_retreat() -> void:
	GameState.party = []
	GameState.pending_battle = {"room_id": 7, "is_boss": false, "monsters": ["ruins_skel_soldier"], "seed": 99}
	GameState.battle_result = {}
	_battle = load("res://scenes/battle/Battle.tscn").instantiate()
	add_child(_battle)
	await get_tree().process_frame
	await get_tree().process_frame

	var knight := TurnManager.heroes[0]

	# 长按 → 详情面板
	_check(not _battle.detail_panel.visible, "初始详情面板隐藏")
	_battle._on_slot_long_pressed(knight.uid)
	_check(_battle.detail_panel.visible, "长按英雄弹出详情面板")
	_check(_battle.detail_vbox.get_child_count() >= 3, "详情面板含标题/属性/关闭按钮")
	_battle.detail_panel.visible = false

	# 道具面板开关
	_check(not _battle.item_panel.visible, "初始道具面板隐藏")
	_battle._on_item_pressed()
	_check(_battle.item_panel.visible, "道具面板打开")
	_battle._on_item_pressed()
	_check(not _battle.item_panel.visible, "道具面板关闭")

	# 撤退：先取消，再确认
	_check(not _battle.retreat_panel.visible, "初始撤退面板隐藏")
	_battle._on_retreat_pressed()
	_check(_battle.retreat_panel.visible, "点撤退弹出二次确认")
	_battle._on_cancel_retreat()
	_check(not _battle.retreat_panel.visible, "取消撤退关闭面板，战斗继续")
	_check(not _battle._get_debug_state()["battle_over"], "取消后战斗未结束")

	_battle._on_retreat_pressed()
	# WS-18 逐人撤退判定：固定全员成功 → 战斗结束（失败结算）
	TurnManager.debug_force_rolls([50, 50, 50, 50])
	_battle._on_confirm_retreat()
	var st: Dictionary = _battle._get_debug_state()
	_check(st["battle_over"], "确认撤退 → 战斗结束")
	_check(not st["victory"], "撤退按失败结算")
	_check(GameState.battle_result.get("victory", true) == false, "GameState.battle_result.victory = false")

	_battle.queue_free()
	await get_tree().process_frame
	_battle = null
