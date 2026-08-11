# 晨昏之下（Into the Dusk）

类《暗黑地牢》的手机游戏（经营 + 回合制战斗）。Godot 4.x（GDScript，2D），Android 平台，横屏锁定。

> 依据：GDD v1.0（WS-2）。本文档与 `data/` 下 JSON 配置共同构成开发的唯一依据。

## 技术栈与平台

- 引擎：Godot 4.7.x（GL Compatibility 渲染，兼顾低端机）
- 平台：Android 8.0+（API 26+），横屏锁定
- 设计分辨率：1920×1080 横屏（`display/window/stretch` canvas_items + keep）

## 工程结构

```
autoload/
  ConfigManager.gd   数据驱动配置层：启动加载 data/*.json 为字典缓存，运行期只读
  SaveManager.gd     存档骨架：JSON 存档（槽位 1~3）+ ConfigFile 设置封装
scenes/
  main/              Main 状态机（主菜单/城镇/地图探索/战斗/结算）
  main_menu/         主菜单（新游戏/继续/设置/退出）
  town/              城镇（经营阶段占位）
  exploration/       地图探索（占位）
  battle/            战斗（占位）
  settlement/        结算（占位）
data/                全部数值配置（JSON，改动数值不改代码）
  heroes.json        英雄职业基础数值与成长（GDD 2.10）
  skills.json        技能定义（GDD 2.6）
  monsters.json      怪物与 Boss（GDD 4.4）
  dungeons.json      区域与关卡结构（GDD 4.1 / 4.2）
  buildings.json     城镇建筑（GDD 3.2）
  loot_tables.json   掉落与经济（GDD 4.5 / 4.6）
  quirks.json        怪癖（GDD 3.5）
  items.json         补给品商店（GDD 3.7）
export_presets.cfg   Android 导出预设（minSdk 26 / targetSdk 35，arm64-v8a + armeabi-v7a）
```

## 运行

用 Godot 4.7.x 打开工程根目录即可运行。启动流程：

1. `ConfigManager` 加载 `data/` 全部 8 个 JSON 到内存字典并打印校验日志（缺字段仅告警不阻断）。
2. `SaveManager` 初始化设置文件（`user://settings.cfg`）。
3. `Main` 状态机进入主菜单。新游戏会建立槽位 1 存档并进入城镇；城镇 → 地图探索 → 战斗 → 结算 的闭环为占位演示。

## 数据驱动约定

- 所有数值均在 `data/*.json` 中，引擎启动时加载为字典、运行期只读缓存；改数值只改 JSON。
- 每个 JSON 顶层为对象（key = 实体 id）；以 `_` 开头的键为节级元数据（如 `_meta`），不参与实体校验。
- 运行期只读接口：`ConfigManager.get_section(section)` / `get_entry(section, id)` / `has_entry(section, id)`。

## 存档

- JSON 存档：`user://saves/slot_<n>.json`（版本号校验，损坏/版本不符降级为空档）。
- 设置：`user://settings.cfg`（ConfigFile 封装，`SaveManager.get/set_setting`）。

## 版本规划（GDD 7.5）

- V0.1 原型：遗迹区域 + 战斗系统 + 触屏操作（本骨架为其基础）
- V0.2 垂直切片：城镇经营 + 掉落经济
- V0.3 完整 MVP：4 区域全量内容 + 压力/怪癖/疾病 + 剧情 + 存档
