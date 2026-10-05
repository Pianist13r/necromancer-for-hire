class_name SnapField
extends RefCounted
##
## К2 снимка (NetSnap): поле договоров каждой стороны (ContractField), договоры (Contract),
## фигуры (LegionFigures, одна на мир). Интерфейс куска — докстринг SnapWorld.
##
## Договоры адресуются «k:<side>,<id>» (Contract.id стабилен в поле стороны). Загрузка на месте
## переиспользует договор с тем же id (клиент не теряет вид линии: _vis поля — по объекту),
## остальные создаются заново; договоров, которых в снимке нет, в поле не остаётся.
## Места строя (posts) — новые словари; боец получает своё место в link К3 по номеру в posts.
##
## Каждое поле класса — либо в *_PROPS/*_REFS (в снимке), либо в *_SKIP с причиной: тест
## (legion_snapshot_test) сверяет это со списком переменных скрипта, новое поле без решения
## роняет гейт.
##

const READY := true

const FIELD_PROPS: Array[String] = [
	"mana", "mana_max", "mana_regen", "mana_cost_mult",
	# вид следующего договора: match_refresh подрисовывает только договоры этого вида
	"current_kind",
	"now", "delay", "_next_id", "_package_t", "_pair_times",
]
const FIELD_REFS: Array[String] = ["contracts", "_package_pairs"]
const FIELD_SKIP: Array[String] = [
	# структура и конфиг — ставят _build/start_map/setup/_setup_pvp_bots тем же кодом, что у
	# сервера (сверка конфига — К1); у клиента human_input свой
	"world", "owner_side", "delay_enabled", "active", "human_input", "overlay",
	"press_consumer", "recruit_r", "unlocked", "shapes", "aim_unlocked", "settlement_mult",
	"base_cost_mult", "aura_enabled", "scheme",
	# кэши: чистая функция рельефа (A* по клеткам, кольца смещений) и счётчик замера
	"_paths", "_rings", "_path_terrain", "path_queries",
	# ввод человека этого клиента (черновик, прицел, рогатка, превью) — не состояние боя
	"_draft", "_draft_len", "_drawing", "_draft_dir", "_draft_ring", "_draft_fig", "_space",
	"_aim_held", "_wheel_quiet_ms", "_hover", "_hover_dirty", "_pen_wait", "_aim_contract",
	"_preview", "_preview_plan", "_preview_t", "_pointer", "_draft_cost", "_pressing",
	"_press_pos", "_press_pts", "_press_eaten", "_grab", "_grab_pos", "_pull", "_slinging",
	"_aim", "_tick_t", "_begin_raw",
	# сетевой ввод этого клиента (D-1001-22): черновик-превью без маны, частота отправки прицела
	"_draft_net", "_aim_sent_ms", "_aim_unsent",
	# вид и звук, счётчики отрисовки
	"_rite_fx", "_cross_fx", "_ring_fx", "_popups", "_hits", "_vis", "_vis_frame", "_fading",
	"_strokes", "_sfx", "_wall_fx", "_wall_ms", "drawn_lines", "drawn_flow", "wall_bumps",
	# ContractRenderer (выделен из поля 05.10): только отрисовка, состояния боя не держит
	"_renderer",
	# рабочие буферы одного вызова (strike_clear, разбор полос)
	"_lanes", "_lanes_a", "_lp_pos", "_lp_speed", "_lp_rad", "_lp_ghost", "_ls_a", "_ls_lat",
	"_ls_r", "_ls_v", "_ls_sig",
]

const CONTRACT_PROPS: Array[String] = [
	"points", "cum", "length", "seg_age", "seg_dead", "seg_renewed", "seg_bend", "seg_bend_dir",
	# однокадровые (пишет grid.press_scan в шаге), но дёшевы — храним, чтобы не доказывать
	"press_mass", "press_sum",
	"ttl", "side", "owner_side", "kind", "mana_cost_mult", "dir", "ring", "center", "ring_out",
	"figure", "lobes", "lobe_span", "tips", "id", "release_causes", "seg_polys",
	"seg_press_box", "_seg_centers",
	# D-1002: мини-размер (числа и места), заряд подготовки, «места только на углах» и флаг
	# выданного пассива «Комиссии» — состояние боя, а не вид
	"size_mini", "charge_t", "corners_only", "ult_armed",
]
const CONTRACT_REFS: Array[String] = ["posts"]
const CONTRACT_SKIP: Array[String] = [
	# угол, вставший в воду или скалу: у ЗАКЛЮЧЁННОГО договора всегда пуст — фигура с таким
	# углом не заключается вовсе (ContractField._create возвращает null)
	"blocked_tips",
]

const FIG_PROPS: Array[String] = [
	# счётчик id групп залпа: по нему «Комиссия» узнаёт СВОЮ метку на враге — id не должен
	# повториться после загрузки снимка
	"_ult_serial",
]
const FIG_REFS: Array[String] = ["_overtime", "_buffs"]
const FIG_SKIP: Array[String] = [
	"world",
	"last_rite",   # подписи и тесты; бой не читает
	"_rite",       # ставится и снимается внутри melt/release — между шагами null
]


## Сверка полей классов (тест): [скрипт, учтённые имена].
static func coverage() -> Array:
	return [
		[ContractField, FIELD_PROPS + FIELD_REFS + FIELD_SKIP],
		[Contract, CONTRACT_PROPS + CONTRACT_REFS + CONTRACT_SKIP],
		[LegionFigures, FIG_PROPS + FIG_REFS + FIG_SKIP],
	]


static func save(w: LegionWorld, reg: NetSnap.Reg) -> Dictionary:
	var fields := []
	for s in w.sides:
		var f := s.contracts
		var d := NetSnap.props_save(f, FIELD_PROPS)
		var list := []
		for c in f.contracts:
			var cd := NetSnap.props_save(c, CONTRACT_PROPS)
			cd["posts"] = reg.enc(c.posts)
			list.append(cd)
		d["contracts"] = list
		d["_package_pairs"] = reg.enc(f._package_pairs)
		fields.append(d)
	var fig := w.figures
	if fig._rite != null:
		push_warning("SnapField: снимок посреди melt — _rite не пуст")
	# жест «Сверхурочных» — тот же словарь, что group у залпов участников (К3): общий
	for job in fig._overtime:
		if job.has("group"):
			reg.share(job["group"])
	return {
		"fields": fields,
		"figures": {
			"_overtime": reg.enc(fig._overtime), "_buffs": reg.enc(fig._buffs),
			"_ult_serial": fig._ult_serial,
		},
	}


static func build(w: LegionWorld, data: Dictionary, _reg: NetSnap.Reg) -> void:
	var figd: Dictionary = data.get("figures", {})
	w.figures._ult_serial = int(figd.get("_ult_serial", 0))
	var fields: Array = data.get("fields", [])
	for i in mini(fields.size(), w.sides.size()):
		var f := w.sides[i].contracts
		var fd: Dictionary = fields[i]
		var by_id := {}
		for c in f.contracts:
			by_id[c.id] = c
		var list: Array[Contract] = []
		for cd: Dictionary in fd["contracts"]:
			var c: Contract = by_id.get(int(cd["id"]))
			if c == null:
				c = Contract.new()
			var plain := cd.duplicate()
			plain.erase("posts")
			NetSnap.props_load(c, plain)
			c.posts = [] as Array[Dictionary]   # места — в link: в них ссылки на бойцов
			list.append(c)
		f.contracts = list
		var plain_f := fd.duplicate()
		plain_f.erase("contracts")
		plain_f.erase("_package_pairs")
		NetSnap.props_load(f, plain_f)


static func link(w: LegionWorld, data: Dictionary, reg: NetSnap.Reg) -> void:
	var fields: Array = data.get("fields", [])
	for i in mini(fields.size(), w.sides.size()):
		var f := w.sides[i].contracts
		var fd: Dictionary = fields[i]
		var saved: Array = fd["contracts"]
		for j in mini(saved.size(), f.contracts.size()):
			var posts: Array[Dictionary] = []
			posts.assign(reg.dec((saved[j] as Dictionary)["posts"]))
			f.contracts[j].posts = posts
		var pairs: Array[Dictionary] = []
		pairs.assign(reg.dec(fd["_package_pairs"]))
		f._package_pairs = pairs
	var figd: Dictionary = data.get("figures", {})
	if figd.is_empty():
		return
	var fig := w.figures
	var overtime: Array[Dictionary] = []
	for job: Dictionary in reg.dec(figd["_overtime"]):
		job["units"] = _units(job["units"])
		var homes: Array[Vector2] = []
		homes.assign(job["homes"])
		job["homes"] = homes
		overtime.append(job)
	fig._overtime = overtime
	var buffs: Array[Dictionary] = []
	for b: Dictionary in reg.dec(figd["_buffs"]):
		b["units"] = _units(b["units"])
		buffs.append(b)
	fig._buffs = buffs
	fig._rite = null


static func finish(_w: LegionWorld, _data: Dictionary, _reg: NetSnap.Reg) -> void:
	pass


## Массив бойцов из декодированного (null — боец, которого уже нет, как и в исходном мире).
static func _units(v: Variant) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u: Variant in v:
		out.append(u as Legionnaire)
	return out
