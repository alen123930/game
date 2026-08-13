# 晨昏之下（Into the Dusk）

类《暗黑地牢》的手机游戏（经营 + 回合制战斗）。Godot 4.x（GDScript，2D），Android 平台，横屏锁定。

> 依据：GDD v1.0（WS-2）。本文档与 `data/` 下 JSON 配置共同构成开发的唯一依据。

## 技术栈与平台

- 引擎：Godot 4.7.x（GL Compatibility 渲染，兼顾低端机）
- 平台：Android 8.0+（API 26+），横屏锁定
- 设计分辨率：1920×1080 横屏（`display/window/stretch` canvas_items + keep）

## 当前进度（V0.1 / WS-3 + WS-5 + WS-4 + WS-7 + WS-8 + WS-9）

已实现：

- **工程脚手架 + 数据驱动配置层（WS-3）**：`ConfigManager` 加载 `data/` 下 10 个 JSON 实体配置并校验；`SaveManager` 提供 JSON 存档（槽位 1~3）+ ConfigFile 设置；`Main`（GameMain）状态机驱动 主菜单/城镇/探索/战斗/结算 五态闭环。
- **遗迹地图 + 探索循环（WS-5）**：程序化网格地图生成（4×4~6×5，战斗/宝箱/事件/安全/起始/关底房），房间探索动作（侦查→探索→检查）、陷阱（铲子/徒手解除）与门锁（钥匙/铲子/盗贼撬锁）、团队火把（0~100，三档效果曲线）、遇敌切战斗、撤退/击破后结算回城。
- **回合制战斗核心（WS-4）**：`TurnManager` 单例驱动回合流程（回合开始结算持续效果 → SPD+D100 行动顺序 → 依次行动 → 回合结束检查）、站位系统（1~4 号位、空缺自动前移）、技能结算（命中/伤害/PROT/暴击×1.5/治疗/DOT/状态/位移/召唤/冷却）、濒死判定与死亡结算、AI 与脚本化行动。
- **压力 + 火把系统（WS-7）**：压力 0~200（来源/减压、100 触发精神判定：美德/受难随机分支、崩溃行为、>200 立即死亡）；火把 0~100 三档效果曲线（明亮/昏暗/黑暗），战斗外每房间 −5、战斗每回合 −1。
- **战斗触屏 UI（WS-8，GDD 2.11 / 7.3）**：单指流交互（点英雄→底部技能栏→选技能→高亮可攻击目标→点目标执行；支持先选技能再选施法者）；技能不可用即时置灰；撤退/防御/道具/结束回合固定底部大热区（≥150px ≈ 54dp ≥44dp，间距 ≥24px ≈ 8dp）；长按任意单位显示详细属性；撤退二次确认；SafeArea 刘海/圆角避让 + Control anchors 自适应。`TurnManager` 负责回合推进，玩家指令经 `script_action` 入队。
- **城镇经营系统（WS-9）**：`TownManager` 单例承载城镇经营（GDD 第三章）——资源管理（金币/传承物 4 种/补给/饰品）、8 栋建筑各 3 级升级（等级门控功能上限：候选人数、技能/武器/护甲上限、治疗折扣、减压活动、墓地永久增益）、每日英雄招募（4~8 名、白/蓝/紫/金稀有度与费用、2~4 怪癖）、养成（经验升级、技能装备与训练场升级、武器/护甲 5 级、饰品 2 槽）、伤病/疾病/怪癖处理与压力处理（教堂/酒馆/派遣休息）、补给商店（9 种物品）；结算把金币/经验/伤病回写城镇，完成「招募→培养→出发→返回→结算→治疗/减压」闭环。新增数据：`data/trinkets.json`、`data/injuries.json`。
- 探索相关运行时配置在 `data/exploration.json`，由 `DataLoader` 加载；`GameState` 承载运行期状态（地图/火把/队伍/补给/战斗衔接）。

> 待办：WS-8 战斗触屏 UI；WS-10 掉落与经济；WS-11 存档。WS-6 美术 V0.1 / WS-12 美术 V0.2 素材已入库（`assets/art/`，供 V0.2 城镇经营等任务按 GDD 6.3 引用）。

## 工程结构

```
autoload/
  ConfigManager.gd   数据驱动配置层：启动加载 data/*.json 实体配置为字典缓存，运行期只读
  SaveManager.gd     存档骨架：JSON 存档（槽位 1~3）+ ConfigFile 设置封装
  DataLoader.gd      探索运行时配置加载器：启动加载 data/exploration.json
  GameState.gd       全局运行状态：当前地图/火把/队伍/补给/战斗衔接/结算载荷
  TurnManager.gd     回合制战斗核心（WS-4）：回合流程/站位/技能结算/濒死/胜负
  TownManager.gd     城镇经营核心（WS-9）：资源/建筑/招募/养成/治疗减压/结算
scenes/
  main/Main.tscn     Main 状态机（主菜单/城镇/探索/战斗/结算），class_name GameMain
  main_menu/         主菜单（新游戏/继续/设置/退出）
  town/              城镇：建筑/招募/英雄养成/商店/治疗减压 + 队伍与出发（WS-9）
  exploration/       地图探索（WS-5 核心：遗迹地图 + 探索循环 + dungeon_generator）
  battle/            战斗（占位，WS-8 接入真实回合制交互）
  settlement/        结算（掉落/经济展示，WS-10 补全；WS-9 已回写金币/经验/伤病）
data/                全部数值配置（JSON，改动数值不改代码）
  heroes.json        英雄职业基础数值与成长（GDD 2.10）
  skills.json        技能定义（GDD 2.6）
  monsters.json      怪物与 Boss（GDD 4.4）
  dungeons.json      区域与关卡结构（GDD 4.1 / 4.2）
  buildings.json     城镇建筑（GDD 3.2）
  loot_tables.json   掉落与经济（GDD 4.5 / 4.6）
  quirks.json        怪癖（GDD 3.5）
  items.json         补给品商店（GDD 3.7）
  trinkets.json      饰品（GDD 3.4，白/蓝/紫/金）
  injuries.json      伤病与疾病（GDD 3.5）
  exploration.json   遗迹探索运行时配置（地图尺寸/火把档位/陷阱/门锁/掉落/遇敌）
assets/art/          美术素材（GDD 6.3 分类目录，WS-12 美术 V0.2 落地）
  buildings/           8 建筑外景 ×3 级 + 交互面板背景 + 建筑图标（1024×768 / 256×256）
  town/                城镇全貌背景（1920×1080）
  ui/                  面板九宫格/按钮三态/HP/压力/火把条/站位格/技能栏/加载页/结算页
  items/               物品图标：补给 9 + 战利品 20 + 饰品 30（256×256）
  fx/                  特效：挥砍/箭矢/法阵/治疗/暴击/粒子/黑雾/净化光环
  manifest.json        素材清单与规格（GDD 6.4）
  SOURCES_AND_LICENSES.md  来源与许可证（game-icons.net CC-BY 3.0 + 程序化合成）
theme/main_theme.tres  全局主题（CJK 字体回退）
tests/               无头自检（WS-3 冒烟 + WS-5 生成器/全流程/场景流转 + WS-4 战斗 + WS-7 压力火把 + WS-8 战斗触屏 UI + WS-9 城镇经营）
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

# WS-4 回合制战斗（站位/命中/伤害/状态/位移/冷却/濒死/可复现）
godot --headless --path . res://tests/combat_test.tscn

# WS-7 压力 + 火把（精神判定/美德受难分支/崩溃行为/>200死亡/火把衰减与三档效果）
godot --headless --path . res://tests/stress_test.tscn

# WS-8 战斗触屏 UI（单指流/置灰/高亮/先选技能/长按/撤退确认/完整战斗胜利+撤退）
godot --headless --path . res://tests/battle_ui_test.tscn

# WS-9 城镇经营（资源/8建筑三级/招募/养成/治疗减压/全闭环 + 城镇 UI 集成）
godot --headless --path . res://tests/test_ws9.tscn
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
