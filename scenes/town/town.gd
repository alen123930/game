extends Control
## 城镇场景（WS-9，GDD 第三章）：经营核心 UI。
## 五个标签页：建筑 / 招募 / 英雄养成 / 商店 / 治疗减压；底部选择任务长度与出发。
## 所有状态读写 TownManager；建筑页展示 WS-12 外景美术（assets/art/buildings/）。

var _selected_length := "short"
var _selected_hero_id := ""
var _detail_hero_id := ""

const ART_BUILDINGS_DIR := "res://assets/art/buildings/"
const TAB_TITLES := ["建筑", "招募", "英雄养成", "商店", "治疗减压"]

@onready var resource_label: Label = %ResourceLabel
@onready var buildings_list: VBoxContainer = %BuildingsList
@onready var candidates_list: VBoxContainer = %CandidatesList
@onready var refresh_btn: Button = %RefreshBtn
@onready var roster_list_v: VBoxContainer = %RosterListV
@onready var roster_detail_v: VBoxContainer = %RosterDetailV
@onready var shop_list: VBoxContainer = %ShopList
@onready var treat_list: VBoxContainer = %TreatList
@onready var length_label: Label = %LengthLabel
@onready var party_label: Label = %PartyLabel
@onready var party_list: HBoxContainer = %PartyList
@onready var save_slot_btns: Array[Button] = [%SaveSlot1, %SaveSlot2, %SaveSlot3]
@onready var save_hint: Label = %SaveHint


func _ready() -> void:
	_set_tab_titles()
	for i in save_slot_btns.size():
		save_slot_btns[i].pressed.connect(_on_manual_save_slot.bind(i + 1))
	_rebuild_all()


## 手动存档槽位状态刷新（GDD 7.1：3 个手动存档槽）。
func _rebuild_save_slots() -> void:
	for i in save_slot_btns.size():
		var slot := i + 1
		var info := SaveManager.slot_info(slot)
		if info["exists"]:
			var tag := "进行中" if info["run_active"] else "城镇"
			save_slot_btns[i].text = "槽位%d（%s，金%d，名册%d，%s）" % [slot, info["saved_at"], int(info["gold"]), int(info["roster_count"]), tag]
		else:
			save_slot_btns[i].text = "槽位%d（空）" % slot
	# 自动存档状态提示（GDD 7.1：每节点/每战斗后自动存档）
	if SaveManager.has_autosave():
		var info := SaveManager.autosave_info()
		save_hint.text = "自动存档：%s（金%d，名册%d%s）" % [
			info["saved_at"], int(info["gold"]), int(info["roster_count"]),
			"，任务进行中" if info["run_active"] else "",
		]
	else:
		save_hint.text = ""


func _on_manual_save_slot(slot: int) -> void:
	if SaveManager.save_slot(slot):
		save_hint.text = "已保存到槽位 %d。" % slot
		print("[Town] 手动存档 → 槽位 %d" % slot)
	else:
		save_hint.text = "保存失败（槽位 %d）。" % slot
	_rebuild_save_slots()


## 页签标题改为中文（默认显示节点名：BuildingsTab/RecruitTab/…）。
func _set_tab_titles() -> void:
	var tabs: TabContainer = get_node_or_null("Margin/VBox/Tabs")
	if tabs == null:
		return
	for i in mini(TAB_TITLES.size(), tabs.get_tab_count()):
		tabs.set_tab_title(i, TAB_TITLES[i])
	tabs.current_tab = 0


# ------------------------------------------------------------------
# 主刷新
# ------------------------------------------------------------------

func _rebuild_all() -> void:
	_update_resource_label()
	_rebuild_buildings()
	_rebuild_candidates()
	_rebuild_roster()
	_rebuild_shop()
	_rebuild_treatment()
	_update_party()
	_rebuild_save_slots()
	length_label.text = "任务长度：%s" % _length_name(_selected_length)


func _update_resource_label() -> void:
	resource_label.text = "金币 %d ｜ 雕像 %d 卷轴 %d 徽章 %d 铭牌 %d" % [
		TownManager.gold,
		int(TownManager.heirlooms.get("statue", 0)),
		int(TownManager.heirlooms.get("scroll", 0)),
		int(TownManager.heirlooms.get("badge", 0)),
		int(TownManager.heirlooms.get("tablet", 0)),
	]


func _length_name(length: String) -> String:
	return {"short": "短", "medium": "中", "long": "长"}.get(length, "短")


# ------------------------------------------------------------------
# 建筑
# ------------------------------------------------------------------

## 建筑页：每栋建筑渲染为可见卡片（外景图 + 图标 + 名称/等级/功能 + 升级按钮）。
func _rebuild_buildings() -> void:
	for child in buildings_list.get_children():
		child.queue_free()
	for bid in TownManager.BUILDING_IDS:
		var cfg: Dictionary = ConfigManager.get_entry("buildings", bid)
		var lvl := TownManager.get_building_level(bid)
		var lvl_cfg: Dictionary = TownManager._building_cfg(bid)

		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(0, 150)
		var card_hb := HBoxContainer.new()
		card_hb.add_theme_constant_override("separation", 20)
		card.add_child(card_hb)
		buildings_list.add_child(card)

		# 外景缩略图（按当前等级显示对应 Lv 外景，1024×768 → 240×180 展示）
		var ext_tex := load("%sbuilding_%s_ext_lv%d.png" % [ART_BUILDINGS_DIR, bid, lvl])
		var thumb := TextureRect.new()
		thumb.name = "ExtThumb"
		thumb.custom_minimum_size = Vector2(300, 168)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if ext_tex is Texture2D:
			thumb.texture = ext_tex
		else:
			# 美术缺失时回退纯色占位块，保证卡片结构可见
			thumb.texture = null
			var fallback := ColorRect.new()
			fallback.custom_minimum_size = Vector2(300, 168)
			fallback.color = Color(0.22, 0.17, 0.12, 0.6)
			card_hb.add_child(fallback)
		if ext_tex is Texture2D:
			card_hb.add_child(thumb)

		# 图标 + 名称/等级/功能
		var info_box := VBoxContainer.new()
		info_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var icon_tex := load("%sbuilding_%s_icon.png" % [ART_BUILDINGS_DIR, bid])
		if icon_tex is Texture2D:
			var icon := TextureRect.new()
			icon.custom_minimum_size = Vector2(72, 72)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.texture = icon_tex
			info_box.add_child(icon)
		var name_label := _label("%s（%s）" % [cfg.get("name", bid), _level_desc(lvl)], 24)
		info_box.add_child(name_label)
		var desc := _label(String(lvl_cfg.get("desc", "")), 18)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_box.add_child(desc)
		card_hb.add_child(info_box)

		# 升级按钮（消耗传承物）
		var up_btn := Button.new()
		up_btn.custom_minimum_size = Vector2(300, 64)
		up_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if lvl >= 3:
			up_btn.text = "已满级"
			up_btn.disabled = true
		else:
			var cost := TownManager.get_upgrade_cost(bid)
			up_btn.text = "升级（雕像%d 卷轴%d 徽章%d 铭牌%d）" % [
				int(cost.get("statue", 0)), int(cost.get("scroll", 0)),
				int(cost.get("badge", 0)), int(cost.get("tablet", 0)),
			]
			up_btn.disabled = not TownManager.can_upgrade(bid)
			up_btn.pressed.connect(_on_upgrade_building.bind(bid))
		card_hb.add_child(up_btn)


func _level_desc(lvl: int) -> String:
	return "Lv.%d" % lvl


func _on_upgrade_building(bid: String) -> void:
	var res := TownManager.upgrade_building(bid)
	if res.get("ok", false):
		print("[Town] %s 升级到 Lv.%d" % [bid, res.get("level", 0)])
	_rebuild_all()


# ------------------------------------------------------------------
# 招募
# ------------------------------------------------------------------

func _rebuild_candidates() -> void:
	for child in candidates_list.get_children():
		child.queue_free()
	refresh_btn.text = "刷新（%d）" % TownManager.refresh_left
	refresh_btn.disabled = TownManager.refresh_left <= 0
	for cand in TownManager.candidates:
		var row := HBoxContainer.new()
		var cfg: Dictionary = ConfigManager.get_entry("heroes", String(cand["class_id"]))
		var info := _label("【%s】%s  %s  %d 金币" % [
			_rarity_name(String(cand["rarity"])),
			cfg.get("name", cand["class_id"]),
			_quirk_names(cand["quirks"]),
			int(cand["cost"]),
		], 20)
		info.custom_minimum_size = Vector2(1100, 0)
		var btn := Button.new()
		btn.text = "招募"
		btn.custom_minimum_size = Vector2(160, 52)
		btn.disabled = TownManager.gold < int(cand["cost"])
		btn.pressed.connect(_on_recruit.bind(cand))
		row.add_child(info)
		row.add_child(btn)
		candidates_list.add_child(row)
	if TownManager.candidates.is_empty():
		candidates_list.add_child(_label("今日候选已空。", 18))


func _on_recruit(cand: Dictionary) -> void:
	var hero := TownManager.recruit(TownManager.candidates.find(cand))
	if not hero.is_empty():
		print("[Town] 招募 %s（%s）" % [hero["name"], _rarity_name(hero["rarity"])])
	_rebuild_all()


func _on_refresh_pressed() -> void:
	if TownManager.refresh_left > 0:
		TownManager.refresh_left -= 1
		TownManager.candidates.clear()
		for i in TownManager.get_recruit_count():
			TownManager.candidates.append(TownManager._generate_candidate())
		_rebuild_all()


# ------------------------------------------------------------------
# 英雄 / 养成
# ------------------------------------------------------------------

func _rebuild_roster() -> void:
	for child in roster_list_v.get_children():
		child.queue_free()
	if TownManager.roster.is_empty():
		roster_list_v.add_child(_label("名册为空，请到「招募」页招募英雄。", 20))
		roster_detail_v.add_child(_label("选择左侧英雄查看详情。", 20))
		return
	for hero in TownManager.roster:
		var btn := Button.new()
		var quirk_mark := _quirk_names(hero["quirks"])
		var rest_mark := "（休息中）" if hero.get("resting", false) else ""
		btn.text = "%s Lv.%d  %s  HP %d 压力 %d%s" % [
			hero["name"], int(hero["level"]), _rarity_name(hero["rarity"]),
			int(hero["hp"]), int(hero["stress"]), rest_mark,
		]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_select_hero.bind(hero))
		roster_list_v.add_child(btn)
	_detail_hero_id = _selected_hero_id
	_rebuild_roster_detail()


func _on_select_hero(hero: Dictionary) -> void:
	_selected_hero_id = String(hero["id"])
	_rebuild_roster()


func _rebuild_roster_detail() -> void:
	for child in roster_detail_v.get_children():
		child.queue_free()
	var hero := TownManager._find_hero(_selected_hero_id)
	if hero.is_empty():
		roster_detail_v.add_child(_label("选择左侧英雄查看详情。", 20))
		return
	var stats := TownManager.get_hero_stats(hero)
	roster_detail_v.add_child(_label("%s  Lv.%d  %s（%s）" % [hero["name"], hero["level"], _rarity_name(hero["rarity"]), hero["class"]], 26))
	roster_detail_v.add_child(_label("属性：HP %d/%d  SPD %d  ACC %d  DODGE %d  CRIT %d%%  DMG %d-%d  PROT %d%%" % [
		int(hero["hp"]), stats["max_hp"], stats["spd"], stats["acc"], stats["dodge"],
		roundi(float(stats["crit"]) * 100.0), stats["dmg_min"], stats["dmg_max"],
		roundi(float(stats["prot"]) * 100.0),
	], 18))
	var bg := Narrative.get_class_background(String(hero["class_id"]))
	if bg != "":
		roster_detail_v.add_child(_label("背景：%s" % bg, 18))
	roster_detail_v.add_child(_label("经验：%d / %d" % [hero["exp"], TownManager.get_exp_needed(hero["level"])], 18))
	roster_detail_v.add_child(_label("怪癖：%s" % _quirk_names(hero["quirks"]), 18))
	if not hero["injuries"].is_empty():
		roster_detail_v.add_child(_label("伤病：%s" % _name_list("injuries", hero["injuries"]), 18))
	if not hero["diseases"].is_empty():
		roster_detail_v.add_child(_label("疾病：%s（需诊疗室 2 级）" % _name_list("injuries", hero["diseases"]), 18))
	roster_detail_v.add_child(_label("武器 Lv.%d（上限 %d）  护甲 Lv.%d（上限 %d）" % [
		hero["weapon_level"], TownManager.get_max_weapon_level(),
		hero["armor_level"], TownManager.get_max_armor_level(),
	], 18))
	roster_detail_v.add_child(_label("饰品：%s" % _trinket_names(hero["trinkets"]), 18))

	# 养成按钮区
	var train_row := HBoxContainer.new()
	var wpn := Button.new()
	wpn.text = "升级武器（%d 金）" % (600 * int(hero["weapon_level"]))
	wpn.disabled = int(hero["weapon_level"]) >= TownManager.get_max_weapon_level()
	wpn.pressed.connect(_on_upgrade_weapon.bind(hero))
	var arm := Button.new()
	arm.text = "升级护甲（%d 金）" % (600 * int(hero["armor_level"]))
	arm.disabled = int(hero["armor_level"]) >= TownManager.get_max_armor_level()
	arm.pressed.connect(_on_upgrade_armor.bind(hero))
	var rest_btn := Button.new()
	rest_btn.text = "派遣休息（-10 压力，下任务不可参战）"
	rest_btn.disabled = hero.get("resting", false)
	rest_btn.pressed.connect(_on_dispatch_rest.bind(hero))
	train_row.add_child(wpn)
	train_row.add_child(arm)
	train_row.add_child(rest_btn)
	roster_detail_v.add_child(train_row)

	# 技能
	roster_detail_v.add_child(_label("已装备技能（%d/%d）：" % [hero["skills"].size(), TownManager.MAX_EQUIPPED_SKILLS], 18))
	var skill_row := HBoxContainer.new()
	for skill_id in hero["skills"].keys():
		var scfg: Dictionary = ConfigManager.get_entry("skills", String(skill_id))
		var lvl := int(hero["skills"][skill_id])
		var sbtn := Button.new()
		sbtn.text = "%s Lv.%d" % [scfg.get("name", skill_id), lvl]
		sbtn.disabled = lvl >= TownManager.get_max_skill_level()
		sbtn.pressed.connect(_on_upgrade_skill.bind(hero, String(skill_id)))
		skill_row.add_child(sbtn)
	if hero["skills"].is_empty():
		skill_row.add_child(_label("无", 18))
	roster_detail_v.add_child(skill_row)
	var pool_row := HBoxContainer.new()
	var pool: Array = ConfigManager.get_entry("heroes", String(hero["class_id"])).get("skill_ids", [])
	for skill_id in pool:
		if hero["skills"].has(skill_id):
			continue
		var scfg: Dictionary = ConfigManager.get_entry("skills", String(skill_id))
		var ebtn := Button.new()
		ebtn.text = "装备 %s" % scfg.get("name", skill_id)
		ebtn.pressed.connect(_on_equip_skill.bind(hero, String(skill_id)))
		pool_row.add_child(ebtn)
	if pool_row.get_child_count() > 0:
		roster_detail_v.add_child(pool_row)

	# 饰品装备
	var trinket_row := HBoxContainer.new()
	for slot in 2:
		var eq_btn := Button.new()
		var cur: Variant = hero["trinkets"][slot]
		if cur == null or cur == "":
			eq_btn.text = "槽%d：空" % (slot + 1)
			eq_btn.pressed.connect(_on_equip_trinket.bind(hero, slot))
		else:
			var tcfg: Dictionary = ConfigManager.get_entry("trinkets", String(cur))
			eq_btn.text = "槽%d：%s（卸下）" % [slot + 1, tcfg.get("name", String(cur))]
			eq_btn.pressed.connect(_on_unequip_trinket.bind(hero, slot))
		trinket_row.add_child(eq_btn)
	roster_detail_v.add_child(trinket_row)

	# 加入/移出队伍
	var party_btn := Button.new()
	if TownManager.get_selected_party().has(hero) or String(hero["id"]) in TownManager._selected_party_ids:
		party_btn.text = "移出队伍"
		party_btn.pressed.connect(_on_remove_from_party.bind(hero))
	else:
		party_btn.text = "加入队伍"
		party_btn.pressed.connect(_on_add_to_party.bind(hero))
	roster_detail_v.add_child(party_btn)


func _on_upgrade_skill(hero: Dictionary, skill_id: String) -> void:
	var res := TownManager.upgrade_skill(hero, skill_id)
	if res.get("ok", false):
		print("[Town] 技能 %s → Lv.%d" % [skill_id, res.get("level", 0)])
	_rebuild_all()


func _on_equip_skill(hero: Dictionary, skill_id: String) -> void:
	TownManager.equip_skill(hero, skill_id)
	_rebuild_all()


func _on_upgrade_weapon(hero: Dictionary) -> void:
	TownManager.upgrade_weapon(hero)
	_rebuild_all()


func _on_upgrade_armor(hero: Dictionary) -> void:
	TownManager.upgrade_armor(hero)
	_rebuild_all()


func _on_dispatch_rest(hero: Dictionary) -> void:
	TownManager.dispatch_rest(hero)
	_rebuild_all()


func _on_equip_trinket(hero: Dictionary, slot: int) -> void:
	if TownManager.trinkets.is_empty():
		return
	var t := String(TownManager.trinkets[0])
	TownManager.equip_trinket(hero, slot, t)
	_rebuild_all()


func _on_unequip_trinket(hero: Dictionary, slot: int) -> void:
	TownManager.unequip_trinket(hero, slot)
	_rebuild_all()


# ------------------------------------------------------------------
# 商店
# ------------------------------------------------------------------

func _rebuild_shop() -> void:
	for child in shop_list.get_children():
		child.queue_free()
	for item in TownManager.shop_items():
		var row := HBoxContainer.new()
		var info := _label("%s  %d 金币/个（已有 %d）" % [
			item["name"], int(item["price"]), int(TownManager.supplies.get(item["id"], 0)),
		], 20)
		info.custom_minimum_size = Vector2(700, 0)
		var btn := Button.new()
		btn.text = "购买 ×1"
		btn.custom_minimum_size = Vector2(160, 52)
		btn.disabled = TownManager.gold < int(item["price"])
		btn.pressed.connect(_on_buy_supply.bind(String(item["id"])))
		row.add_child(info)
		row.add_child(btn)
		shop_list.add_child(row)


func _on_buy_supply(item_id: String) -> void:
	var res := TownManager.buy_supply(item_id, 1)
	if res.get("ok", false):
		print("[Town] 购买补给 %s" % item_id)
	_rebuild_all()


# ------------------------------------------------------------------
# 治疗 / 减压
# ------------------------------------------------------------------

func _rebuild_treatment() -> void:
	for child in treat_list.get_children():
		child.queue_free()
	if TownManager.roster.is_empty():
		treat_list.add_child(_label("名册为空，先招募英雄。", 20))
		return
	# 目标英雄选择
	var pick := OptionButton.new()
	pick.add_item("— 选择治疗目标 —")
	for hero in TownManager.roster:
		pick.add_item("%s（HP %d 压力 %d）" % [hero["name"], int(hero["hp"]), int(hero["stress"])])
		if String(hero["id"]) == _detail_hero_id:
			pick.select(pick.item_count - 1)
	pick.item_selected.connect(_on_pick_target)
	treat_list.add_child(pick)
	var hero := TownManager._find_hero(_detail_hero_id)
	if hero.is_empty():
		return

	var clinic_row := HBoxContainer.new()
	for inj_id in hero["injuries"]:
		var cfg: Dictionary = ConfigManager.get_entry("injuries", String(inj_id))
		var btn := Button.new()
		btn.text = "治疗「%s」（%d 金）" % [cfg.get("name", inj_id), roundi(int(cfg.get("cure_cost", 300)) * TownManager.get_clinic_fee_mult())]
		btn.pressed.connect(_on_cure.bind(hero, String(inj_id), true))
		clinic_row.add_child(btn)
	for dis_id in hero["diseases"]:
		var cfg: Dictionary = ConfigManager.get_entry("injuries", String(dis_id))
		var btn := Button.new()
		btn.text = "治疗「%s」（%d 金，需 2 级）" % [cfg.get("name", dis_id), roundi(int(cfg.get("cure_cost", 800)) * TownManager.get_clinic_fee_mult())]
		btn.disabled = TownManager.get_building_level("clinic") < 2
		btn.pressed.connect(_on_cure.bind(hero, String(dis_id), false))
		clinic_row.add_child(btn)
	if clinic_row.get_child_count() == 0:
		clinic_row.add_child(_label("诊疗室：无伤病/疾病可治疗。", 18))
	treat_list.add_child(clinic_row)

	var church_row := HBoxContainer.new()
	for a in TownManager.get_church_actions():
		var btn := Button.new()
		btn.text = "%s（%d 金）" % [a.get("name", a.get("action", "")), int(a.get("cost", 0))]
		btn.pressed.connect(_on_church.bind(hero, String(a.get("action", ""))))
		church_row.add_child(btn)
	if church_row.get_child_count() > 0:
		treat_list.add_child(_label("教堂：", 20))
		treat_list.add_child(church_row)

	var tavern_row := HBoxContainer.new()
	for a in TownManager.get_tavern_actions():
		var btn := Button.new()
		btn.text = "%s（%d 金）" % [a.get("name", a.get("action", "")), int(a.get("cost", 0))]
		btn.pressed.connect(_on_tavern.bind(hero, String(a.get("action", ""))))
		tavern_row.add_child(btn)
	if tavern_row.get_child_count() > 0:
		treat_list.add_child(_label("酒馆：", 20))
		treat_list.add_child(tavern_row)

	var quirk_row := HBoxContainer.new()
	for q in hero["quirks"]:
		if String(q.get("type", "")) != "negative":
			continue
		var btn := Button.new()
		btn.text = "净化「%s」（%d 金）" % [q.get("name", q.get("id", "")), TownManager.get_purge_cost()]
		btn.pressed.connect(_on_purge_quirk.bind(hero, String(q.get("id", ""))))
		quirk_row.add_child(btn)
	if quirk_row.get_child_count() > 0:
		treat_list.add_child(_label("教堂净化负面怪癖：", 20))
		treat_list.add_child(quirk_row)


func _on_pick_target(index: int) -> void:
	if index <= 0:
		_detail_hero_id = ""
		_rebuild_all()
		return
	var hero: Dictionary = TownManager.roster[index - 1]
	_detail_hero_id = String(hero["id"])
	_rebuild_all()


func _on_cure(hero: Dictionary, aff_id: String, is_injury: bool) -> void:
	var res := TownManager.cure_injury(hero, aff_id) if is_injury else TownManager.cure_disease(hero, aff_id)
	if res.get("ok", false):
		print("[Town] 治疗完成 %s" % aff_id)
	_rebuild_all()


func _on_church(hero: Dictionary, action_id: String) -> void:
	TownManager.church_relieve(hero, action_id)
	_rebuild_all()


func _on_tavern(hero: Dictionary, action_id: String) -> void:
	var res := TownManager.tavern_activity(hero, action_id)
	if res.get("ok", false) and res.get("new_quirk", false):
		print("[Town] 酒馆活动后获得了新怪癖……")
	_rebuild_all()


func _on_purge_quirk(hero: Dictionary, quirk_id: String) -> void:
	TownManager.purge_quirk(hero, quirk_id)
	_rebuild_all()


# ------------------------------------------------------------------
# 队伍 / 出发
# ------------------------------------------------------------------

func _on_add_to_party(hero: Dictionary) -> void:
	var ids: Array = TownManager._selected_party_ids.duplicate()
	if String(hero["id"]) in ids:
		return
	if ids.size() >= 4:
		return
	ids.append(String(hero["id"]))
	TownManager.select_party(ids)
	_rebuild_all()


func _on_remove_from_party(hero: Dictionary) -> void:
	var ids: Array = TownManager._selected_party_ids.duplicate()
	ids.erase(String(hero["id"]))
	TownManager.select_party(ids)
	_rebuild_all()


func _update_party() -> void:
	for child in party_list.get_children():
		child.queue_free()
	var party := TownManager.get_selected_party()
	if party.is_empty():
		party_label.text = "队伍：未选择"
		return
	party_label.text = "队伍：%d/4" % party.size()
	for hero in party:
		var chip := _label("%s HP%d 压%d" % [hero["name"], int(hero["hp"]), int(hero["stress"])], 20)
		party_list.add_child(chip)


func _on_short_pressed() -> void:
	_selected_length = "short"
	length_label.text = "任务长度：%s" % _length_name(_selected_length)


func _on_medium_pressed() -> void:
	_selected_length = "medium"
	length_label.text = "任务长度：%s" % _length_name(_selected_length)


func _on_long_pressed() -> void:
	_selected_length = "long"
	length_label.text = "任务长度：%s" % _length_name(_selected_length)


func _on_start_pressed() -> void:
	if TownManager.has_selected_party():
		var res := TownManager.prepare_run(_selected_length)
		if not res.get("ok", false):
			return
	else:
		GameState.start_run(_selected_length)
	_change_state(GameMain.GameState.EXPLORATION)


func _change_state(state: int) -> void:
	var main: GameMain = get_tree().get_first_node_in_group("game_main")
	if main != null:
		main.change_state(state)


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _rarity_name(rarity: String) -> String:
	return {"white": "白", "blue": "蓝", "purple": "紫", "gold": "金"}.get(rarity, rarity)


func _quirk_names(quirks: Array) -> String:
	var parts := PackedStringArray()
	for q in quirks:
		parts.append(q.get("name", q.get("id", "")))
	return "，".join(parts)


func _name_list(section: String, ids: Array) -> String:
	var parts := PackedStringArray()
	for id in ids:
		parts.append(String(ConfigManager.get_entry(section, String(id)).get("name", id)))
	return "，".join(parts)


func _trinket_names(trinkets: Array) -> String:
	var parts := PackedStringArray()
	for t in trinkets:
		if t == null or String(t) == "":
			parts.append("空")
		else:
			parts.append(String(ConfigManager.get_entry("trinkets", String(t)).get("name", t)))
	return "，".join(parts)
