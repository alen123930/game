class_name BattleRules
extends RefCounted
## 战斗核心纯公式层（WS-18 按《暗黑地牢》对齐：WS-17 第 2 节）
##
## 全部为静态纯函数，输入→输出确定，便于可复现测试：
## 命中率 / 伤害 / 治疗 / DOT / 死亡抵抗。
## 约定（与 skills.json 字段对应）：
##   - dmg_mult 直接作伤害总倍率（GDD 2.6「DMG 的倍率，如 ×1.2」）。
##   - heal_mult 治疗按 (1 + mult) 计算（治疗技能 mult 常见 0.3~0.6，直接乘会过低）。
##   - 暴击倍率 1.5（GDD 2.3）。
##   - acc_mod 为技能命中修正（相对 95% 基准，可正可负）。

## 命中率（DD 对齐）：基础 95% + 施法者 ACC − 目标 DODGE + 技能命中修正 acc_mod。
## clamp 按 DD 实际约 [0%,100%]（WS-17 待确认值按文档实现）。
static func hit_chance(acc_mod: int, attacker_acc: int, target_dodge: int) -> int:
	return clampi(95 + acc_mod + attacker_acc - target_dodge, 0, 100)

## 伤害（GDD 2.3）：DMG 区间随机取整 × (1 − PROT) × 倍率 × 暴击修正。
## prot 需先 clamp 到 [0, 0.8]（GDD 2.10 属性上限 80%）。
static func compute_damage(dmg_roll: int, prot: float, dmg_mult: float, crit_mult: float = 1.0, vuln_mult: float = 1.0) -> int:
	var prot_c := clampf(prot, 0.0, 0.8)
	var raw := float(dmg_roll) * (1.0 - prot_c) * dmg_mult * crit_mult * vuln_mult
	return maxi(roundi(raw), 0)

## 治疗：DMG 区间随机取整 × (1 + 治疗倍率)。
static func compute_heal(dmg_roll: int, heal_mult: float) -> int:
	return maxi(roundi(float(dmg_roll) * (1.0 + heal_mult)), 0)

## DOT 每回合结算：按固定值，受 PROT 影响。
static func dot_damage(value: int, prot: float) -> int:
	return maxi(roundi(float(value) * (1.0 - clampf(prot, 0.0, 0.8))), 0)

## 死亡抵抗（DD 对齐）：掷 D100 ≤ DBR（英雄基础约 67，可被怪癖/饰品修正）则稳保命，
## 否则即死。移除 GDD 的 D100≤50 判定。
static func deathblow_resist(dbr: int, roll_100: int) -> bool:
	return roll_100 <= dbr
