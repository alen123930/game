class_name DungeonGenerator
## 程序化网格地图生成（GDD 4.2）
## 网格 4×4~6×5；房间类型：战斗/宝箱/事件/安全/起始/关底。
## 生成结果为一个连通房间图（spanning tree + 少量回廊），起始房在边缘、关底房最深处。

const ROOM_TYPES := ["battle", "treasure", "event", "safe", "start", "boss"]
const TYPE_WEIGHT := {"battle": 5, "treasure": 2, "event": 3, "safe": 2, "start": 1, "boss": 1}

var _config: Dictionary
var _length: String


## 生成一张遗迹地图。config 来自 data/dungeons.json，length 为 short/medium/long。
## 返回：{cols, rows, rooms: Array, start_room: int, boss_room: int, length}
static func generate(config: Dictionary, length: String, rng: RandomNumberGenerator = null) -> Dictionary:
	var gen := DungeonGenerator.new()
	gen._config = config
	gen._length = length
	return gen._generate(rng)


func _generate(rng: RandomNumberGenerator) -> Dictionary:
	var r := rng if rng != null else RandomNumberGenerator.new()
	var map_cfg: Dictionary = _config.get("map", {})
	var min_cols := int(map_cfg.get("min_cols", 4))
	var max_cols := int(map_cfg.get("max_cols", 6))
	var min_rows := int(map_cfg.get("min_rows", 4))
	var max_rows := int(map_cfg.get("max_rows", 5))

	var ratios: Dictionary = map_cfg.get("room_ratios", {}).get(_length, {})
	var target_rooms := _room_count_from_ratios(ratios)
	target_rooms = maxi(target_rooms, int(map_cfg.get("min_rooms", 8)))

	# 网格必须容纳下目标房间数：从 (cols×rows >= target_rooms) 的合法组合中随机选
	var grid_choices: Array = []
	for c in range(min_cols, max_cols + 1):
		for rr in range(min_rows, max_rows + 1):
			if c * rr >= target_rooms:
				grid_choices.append(Vector2i(c, rr))
	if grid_choices.is_empty():
		grid_choices.append(Vector2i(max_cols, max_rows))
	var grid: Vector2i = grid_choices[r.randi_range(0, grid_choices.size() - 1)]
	var cols: int = grid.x
	var rows: int = grid.y
	target_rooms = mini(target_rooms, cols * rows)

	var occupied := {}
	var positions := {}
	var cell_list := []
	# 起始房放在边缘（左上角），保证入口可达
	var start_pos := Vector2i(0, r.randi_range(0, maxi(0, rows - 1)))
	positions[0] = start_pos
	occupied[start_pos] = 0
	cell_list.append(start_pos)

	# 用随机游走式生长，向四周展开出连通房间，直到达到目标数量
	var room_id := 1
	var attempts := 0
	while room_id < target_rooms and attempts < target_rooms * 40:
		attempts += 1
		var candidate := _pick_growth_cell(occupied, cols, rows, r)
		if candidate == Vector2i(-1, -1):
			break
		occupied[candidate] = room_id
		positions[room_id] = candidate
		cell_list.append(candidate)
		room_id += 1

	# 目标数量未满时用全网格兜底：任意未占用格补充（保证房间数达标）
	if room_id < target_rooms:
		for y in rows:
			for x in cols:
				if room_id >= target_rooms:
					break
				var p := Vector2i(x, y)
				if not occupied.has(p):
					occupied[p] = room_id
					positions[room_id] = p
					cell_list.append(p)
					room_id += 1
			if room_id >= target_rooms:
				break

	# 关底房放在距起始房最远的房间
	var boss_room := _farthest_room(positions, start_pos)

	# 构建邻接表（网格四邻域）
	var adjacency := _build_adjacency(positions, cols, rows)

	# 连成连通图：从起始房 BFS 生长，保证每房可达；再补少量回廊
	var spanning := _spanning_tree(positions, adjacency, 0, r)

	# 分配房间类型
	var types := _assign_types(room_id, boss_room, ratios, r)

	# 房间数据
	var rooms := []
	for i in room_id:
		rooms.append({
			"id": i,
			"pos": positions[i],
			"type": types[i],
			"connections": spanning[i],
			"revealed": false,
			"explored": false,
			"trapped": false,
			"trap_visible": false,
			"locked_door": false,
			"looted": false,
		})

	# 陷阱与门锁（GDD 4.2）
	_apply_hazards(rooms, 0, r)

	return {
		"cols": cols,
		"rows": rows,
		"rooms": rooms,
		"start_room": 0,
		"boss_room": boss_room,
		"length": _length,
		"map_type": "ruins",
		# 运行配置直接嵌入生成结果，供探索场景读取（GDD 7.2 数据驱动）
		"exploration": _config.get("exploration", {}),
		"torch": _config.get("torch", {}),
		"traps": _config.get("traps", {}),
		"doors": _config.get("doors", {}),
		"loot": _config.get("loot", {}),
		"encounters": _config.get("encounters", {}),
	}


func _room_count_from_ratios(ratios: Dictionary) -> int:
	var n := 1  # 起始房
	n += int(ratios.get("battle", 0))
	n += int(ratios.get("treasure", 0))
	n += int(ratios.get("event", 0))
	n += int(ratios.get("safe", 0))
	n += int(ratios.get("boss", 0))
	return n


func _pick_growth_cell(occupied: Dictionary, cols: int, rows: int, r: RandomNumberGenerator) -> Vector2i:
	# 从已占用格随机挑一个，向其未占用的邻格生长
	var keys := occupied.keys()
	var base: Vector2i = keys[r.randi_range(0, keys.size() - 1)]
	var neighbors := _neighbors(base, cols, rows)
	neighbors.shuffle()
	for n in neighbors:
		if not occupied.has(n):
			return n
	return Vector2i(-1, -1)


func _neighbors(pos: Vector2i, cols: int, rows: int) -> Array:
	var out := []
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d in dirs:
		var p := pos + d
		if p.x >= 0 and p.x < cols and p.y >= 0 and p.y < rows:
			out.append(p)
	return out


func _farthest_room(positions: Dictionary, start: Vector2i) -> int:
	var best_id := 0
	var best_dist := -1.0
	for id in positions:
		var p: Vector2i = positions[id]
		var d: float = p.distance_to(start)
		if d > best_dist:
			best_dist = d
			best_id = id
	return best_id


func _build_adjacency(positions: Dictionary, cols: int, rows: int) -> Dictionary:
	var adj := {}
	for id in positions:
		adj[id] = []
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	for id in positions:
		var p: Vector2i = positions[id]
		for d in dirs:
			var np := p + d
			if positions.has(np):
				var other: int = positions[np]
				adj[id].append(other)
	return adj


func _spanning_tree(positions: Dictionary, adjacency: Dictionary, start: int, r: RandomNumberGenerator) -> Dictionary:
	# 随机 BFS 生成树，保证连通；再从剩余边随机补回廊。
	# 兜底：任何未被 BFS 覆盖的房间（如网格兜底放置产生的孤岛）通过最近已连通房桥接。
	var tree := {}
	var visited := {}
	var frontier := [start]
	visited[start] = true
	while not frontier.is_empty():
		var cur: int = frontier.pop_front()
		tree[cur] = []
		var nbrs: Array = adjacency[cur].duplicate()
		nbrs.shuffle()
		for nb in nbrs:
			if not visited.has(nb):
				visited[nb] = true
				tree[cur].append(nb)
				tree[nb] = []
				tree[nb].append(cur)
				frontier.append(nb)

	# 桥接孤岛：把未覆盖房间连到最近已覆盖房间
	for room_id in positions:
		if visited.has(room_id):
			continue
		var nearest := -1
		var nearest_d := -1.0
		for other in visited:
			var d: float = (positions[room_id] as Vector2i).distance_to(positions[other] as Vector2i)
			if nearest == -1 or d < nearest_d:
				nearest = other
				nearest_d = d
		if nearest != -1:
			visited[room_id] = true
			tree[room_id] = []
			tree[nearest].append(room_id)
			tree[room_id].append(nearest)

	# 回廊：把非树边按概率加入，形成分支结构
	var extra_edges := []
	for a in adjacency:
		for b in adjacency[a]:
			if a < b and not _edge_in(tree, a, b):
				extra_edges.append([a, b])
	for e in extra_edges:
		if r.randf() < 0.35:
			var a: int = e[0]
			var b: int = e[1]
			if not _edge_in(tree, a, b):
				tree[a].append(b)
				tree[b].append(a)
	return tree


func _edge_in(tree: Dictionary, a: int, b: int) -> bool:
	if not tree.has(a):
		return false
	var arr: Array = tree[a]
	return arr.has(b)


func _assign_types(room_count: int, boss_room: int, ratios: Dictionary, r: RandomNumberGenerator) -> Array:
	# 组装类型包（去掉起始房与关底房名额后），shuffle 分配到其余房间
	var type_bag := []
	var battle_n := int(ratios.get("battle", 0))
	var treasure_n := int(ratios.get("treasure", 0))
	var event_n := int(ratios.get("event", 0))
	var safe_n := int(ratios.get("safe", 0))
	var boss_n := int(ratios.get("boss", 0))

	# 房间不足时用战斗房补齐剩余名额
	var assigned_slots := battle_n + treasure_n + event_n + safe_n + boss_n
	var free_slots := room_count - 1 - boss_n  # 除起始房外的非关底名额
	if free_slots > assigned_slots:
		battle_n += free_slots - assigned_slots

	for i in battle_n:
		type_bag.append("battle")
	for i in treasure_n:
		type_bag.append("treasure")
	for i in event_n:
		type_bag.append("event")
	for i in safe_n:
		type_bag.append("safe")

	var result := []
	result.resize(room_count)
	for i in room_count:
		result[i] = "battle"

	result[0] = "start"
	if boss_n > 0 and boss_room != 0:
		result[boss_room] = "boss"

	var candidates := []
	for i in range(1, room_count):
		if i != boss_room:
			candidates.append(i)
	candidates.shuffle()

	var idx := 0
	for t in type_bag:
		if idx >= candidates.size():
			break
		var room_id: int = candidates[idx]
		# 若候选房是关底房则跳过（关底已单独分配）
		result[room_id] = t
		idx += 1
	return result


func _apply_hazards(rooms: Array, start_id: int, r: RandomNumberGenerator) -> void:
	var trap_cfg: Dictionary = _config.get("traps", {})
	var door_cfg: Dictionary = _config.get("doors", {})
	var trap_chance := float(trap_cfg.get("chance", 0.25))
	var lock_chance := float(door_cfg.get("locked_chance", 0.2))

	for room in rooms:
		var rd: Dictionary = room
		if int(rd["id"]) == start_id:
			continue
		var type_name := String(rd["type"])
		if type_name == "start":
			continue
		if r.randf() < trap_chance and type_name != "boss":
			rd["trapped"] = true
		if r.randf() < lock_chance and type_name != "boss":
			rd["locked_door"] = true
