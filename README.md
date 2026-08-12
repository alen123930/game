# 晨昏之下（Into the Dusk）

类《暗黑地牢》的手机游戏（经营 + 回合制战斗）。Godot 4.x（GDScript，2D），Android 平台，横屏锁定。

> 依据：GDD v1.0（WS-2）。本文档与 `data/` 下 JSON 配置共同构成开发的唯一依据。

## 技术栈与平台

- 引擎：Godot 4.7.x（GL Compatibility 渲染，兼顾低端机）
- 平台：Android 8.0+（API 26+），横屏锁定
- 设计分辨率：1920×1080 横屏（`display/window/stretch` canvas_items + keep）

## 当前进度（V0.1 / WS-3 + WS-5）

已实现：

- **工程脚手架 + 数据驱动配置层（WS-3）**：`ConfigManager` 加载 `data/` 下 8 个 JSON 实体配置并校验；`SaveManager` 提供 JSON 存档（槽位 1~3）+ ConfigFile 设置；`Main`（GameMain）状态机驱动 主菜单/城镇/探索/战斗/结算 五态闭环。
- **遗迹地图 + 探索循环（WS-5）**：程序化网格地图生成（4×4~6×5，战斗/宝箱/事件/安全/起始/关底房），房间探索动作（侦查→探索→检查）、陷阱（铲子/徒手解除）与门锁（钥匙/铲子/盗贼撬锁）、团队火把（0~100，三档效果曲线）、遇敌切战斗、撤退/击破后结算回城。
- 探索相关运行时配置在 `data/exploration.json`，由 `DataLoader` 加载；`GameState` 承载运行期状态（地图/火把/队伍/补给/战斗衔接）。

> 待办：WS-4 回合制战斗核心（in_progress，尚未并入）；WS-6 美术素材已交付（见 issue）。

## 工程结构

```
autoload/
  ConfigManager.gd   数据驱动配置层：启动加载 data/*.json 实体配置为字典缓存，运行期只读
  SaveManager.gd     存档骨架：JSON 存档（槽位 1~3）+ ConfigFile 设置封装
  DataLoader.gd      探索运行时配置加载器：启动加载 data/exploration.json
  GameState.gd       全局运行状态：当前地图/火把/队伍/补给/战斗衔接/结算载荷
scenes/
  main/Main.tscn     Main 状态机（主菜单/城镇/探索/战斗/结算），class_name GameMain
  main_menu/         主菜单（新游戏/继续/设置/退出）
  town/              城镇：任务长度选择 + 队伍展示 + 出发（WS-9 补全经营）
  exploration/       地图探索（WS-5 核心：遗迹地图 + 探索循环 + dungeon_generator）
  battle/            战斗（占位，WS-4 替换为真实回合制）
  settlement/        结算（掉落/经济展示，WS-10 补全）
data/                全部数值配置（JSON，改动数值不改代码）
  heroes.json        英雄职业基础数值与成长（GDD 2.10）
  skills.json        技能定义（GDD 2.6）
  monsters.json      怪物与 Boss（GDD 4.4）
  dungeons.json      区域与关卡结构（GDD 4.1 / 4.2）
  buildings.json     城镇建筑（GDD 3.2）
  loot_tables.json   掉落与经济（GDD 4.5 / 4.6）
  quirks.json        怪癖（GDD 3.5）
  items.json         补给品商店（GDD 3.7）
  exploration.json   遗迹探索运行时配置（地图尺寸/火把档位/陷阱/门锁/掉落/遇敌）
theme/main_theme.tres  全局主题（CJK 字体回退）
tests/               无头自检（WS-3 冒烟 + WS-5 生成器/全流程/场景流转）
export_presets.cfg   Android 导出预设（minSdk 26 / targetSdk 35，arm64-v8a + armeabi-v7a）
```

## 运行

用 Godot 4.7.x 打开工程根目录即可运行。启动流程：

1. `ConfigManager` 加载 `data/` 全部 8 个 JSON 到内存字典并打印校验日志（缺字段仅告警不阻断）。
2. `DataLoader` 加载 `data/exploration.json`；`GameState` 初始化火把/队伍。
3. `Main` 状态机进入主菜单 → 新游戏建槽位 1 存档进入城镇 → 选择任务长度出发 → 遗迹探索 → 战斗（占位）→ 结算回城。

## 无头自检

```bash
# WS-3 冒烟（配置加载 + 状态机闭环 + 存档）
godot --headless --path . res://tests/smoke_test.tscn

# WS-5 生成器 + 火把档位 + 全流程（以 test_main.tscn 为主场景）
godot --headless --path . res://tests/test_main.tscn

# WS-5 场景流转（城镇→地城→战斗→结算→城镇）
godot --headless --path . res://tests/test_scene_flow.tscn
```

## 数据驱动约定

- 所有数值均在 `data/*.json` 中，引擎启动时加载为字典、运行期只读缓存；改数值只改 JSON。
- 实体配置每个 JSON 顶层为对象（key = 实体 id）；以 `_` 开头的键为节级元数据（如 `_meta`），不参与实体校验。
- 运行期只读接口：`ConfigManager.get_section(section)` / `get_entry(section, id)` / `has_entry(section, id)`。
- 探索运行时配置（`exploration.json`）为扁平结构，读取走 `DataLoader.get_config("exploration.json")`，`GameState` 缓存 torch/陷阱/门锁/掉落/遇敌等小节。

## 存档

- JSON 存档：`user://saves/slot_<n>.json`（版本号校验，损坏/版本不符降级为空档）。
- 设置：`user://settings.cfg`（ConfigFile 封装，`SaveManager.get/set_setting`）。

## 版本规划（GDD 7.5）

- V0.1 原型：遗迹区域 + 战斗系统 + 触屏操作（当前：脚手架 + 探索循环；WS-4 战斗进行中）
- V0.2 垂直切片：城镇经营 + 掉落经济
- V0.3 完整 MVP：4 区域全量内容 + 压力/怪癖/疾病 + 剧情 + 存档
