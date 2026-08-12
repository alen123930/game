class_name BattleRules
extends RefCounted
## 战斗核心纯公式层（GDD 2.3 / 2.8 / 2.9）
##
## 全部为静态纯函数，输入→输出确定，便于可复现测试：
## 命中率 / 伤害 / 治疗 / DOT / 濒死判定。
## 约定（与 skills.json 字段对应）：
##   - dmg_mult 直接作伤害总倍率（GDD 2.6「DMG 的倍率，如 ×1.2」）。
##   - heal_mult 治疗按 (1 + mult) 计算（治疗技能 mult 常见 0.3~0.6，直接乘会过低）。
##   - 暴击倍率 1.5（GDD 2.3）。

## 命中率（GDD 2.3）：技能基准命中 + 施法者 ACC − 目标 DODGE − 位置惩罚，clamp [5%,95%]。
static func hit_chance(base_acc: int, attacker_acc: int, target_dodge: int, position_penalty: int = 0) -> int:
	return clampi(base_acc + attacker_acc - target_dodge - position_penalty, 5, 95)

## 伤害（GDD 2.3）：DMG 区间随机取整 × (1 − PROT) × 倍率 × 暴击修正。
## prot 需先 clamp 到 [0, 0.8]（GDD 2.10 属性上限 80%）。
static func compute_damage(dmg_roll: int, prot: float, dmg_mult: float, crit_mult: float = 1.0, vuln_mult: float = 1.0) -> int:
	var prot_c := clampf(prot, 0.0, 0.8)
	var raw := float(dmg_roll) * (1.0 - prot_c) * dmg_mult * crit_mult * vuln_mult
	return maxi(roundi(raw), 0)

## 治疗：DMG 区间随机取整 × (1 + 治疗倍率)。
static func compute_heal(dmg_roll: int, heal_mult: float) -> int:
	return maxi(roundi(float(dmg_roll) * (1.0 + heal_mult)), 0)

## DOT 每回合结算（GDD 2.3）：按固定值，受 PROT 影响（燃烧不受）。
static func dot_damage(value: int, prot: float, ignore_prot: bool = false) -> int:
	if ignore_prot:
		return value
	return maxi(roundi(float(value) * (1.0 - clampf(prot, 0.0, 0.8))), 0)

## 濒死判定（GDD 2.4 / 2.9）：D100 ≤ 50 稳定保命，否则死亡。
static func deathblow_stable(roll_100: int) -> bool:
	return roll_100 <= 50

## 眩晕/位移失位惩罚命中减值：被击退/拉拽后下回合跳过行动（GDD 2.7），不计入公式惩罚位。
static func clamp_percent(v: int) -> int:
	return clampi(v, 5, 95)
