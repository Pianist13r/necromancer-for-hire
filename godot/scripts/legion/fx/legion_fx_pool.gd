class_name LegionFxPool
extends RefCounted
##
## Частицы одного вида для слоя LegionFx: структура массивов (упакованные массивы на поле),
## удаление — перестановкой последней на место, без аллокаций в кадре. Слой держит по пулу на
## текстуру и рисует пул подряд — соседние прямоугольники одной текстуры сливаются в один вызов.
##

var tex: Texture2D = null
var rotates := false
var ambient := false
var n := 0
var px := PackedFloat32Array()
var py := PackedFloat32Array()
var vx := PackedFloat32Array()
var vy := PackedFloat32Array()
var grav := PackedFloat32Array()
var drag := PackedFloat32Array()
var age := PackedFloat32Array()
var life := PackedFloat32Array()
var s0 := PackedFloat32Array()
var s1 := PackedFloat32Array()
var asp := PackedFloat32Array()
var a0 := PackedFloat32Array()
var fin := PackedFloat32Array()
var fout := PackedFloat32Array()
var rot := PackedFloat32Array()
var spin := PackedFloat32Array()
var wax := PackedFloat32Array()
var way := PackedFloat32Array()
var wf := PackedFloat32Array()
var wph := PackedFloat32Array()
var gy := PackedFloat32Array()      ## уровень земли для отскока; <0 — земли нет
var bn := PackedInt32Array()        ## отскоков осталось
var col := PackedColorArray()

func _init(t: Texture2D, rotating: bool, is_ambient: bool) -> void:
	tex = t
	rotates = rotating
	ambient = is_ambient

func _grow() -> void:
	var m := maxi(16, px.size() * 2)
	px.resize(m)
	py.resize(m)
	vx.resize(m)
	vy.resize(m)
	grav.resize(m)
	drag.resize(m)
	age.resize(m)
	life.resize(m)
	s0.resize(m)
	s1.resize(m)
	asp.resize(m)
	a0.resize(m)
	fin.resize(m)
	fout.resize(m)
	rot.resize(m)
	spin.resize(m)
	wax.resize(m)
	way.resize(m)
	wf.resize(m)
	wph.resize(m)
	gy.resize(m)
	bn.resize(m)
	col.resize(m)

func add(x: float, y: float, life_s: float, size_a: float, size_b: float, alpha: float,
		c: Color) -> int:
	if n == px.size():
		_grow()
	var i := n
	n += 1
	px[i] = x
	py[i] = y
	vx[i] = 0.0
	vy[i] = 0.0
	grav[i] = 0.0
	drag[i] = 0.0
	age[i] = 0.0
	life[i] = maxf(life_s, 0.01)
	s0[i] = size_a
	s1[i] = size_b
	asp[i] = 1.0
	a0[i] = alpha
	fin[i] = 0.1
	fout[i] = 0.5
	rot[i] = 0.0
	spin[i] = 0.0
	wax[i] = 0.0
	way[i] = 0.0
	wf[i] = 0.0
	wph[i] = 0.0
	gy[i] = -1.0
	bn[i] = 0
	col[i] = c
	return i

func _kill(i: int) -> void:
	n -= 1
	if i == n:
		return
	px[i] = px[n]
	py[i] = py[n]
	vx[i] = vx[n]
	vy[i] = vy[n]
	grav[i] = grav[n]
	drag[i] = drag[n]
	age[i] = age[n]
	life[i] = life[n]
	s0[i] = s0[n]
	s1[i] = s1[n]
	asp[i] = asp[n]
	a0[i] = a0[n]
	fin[i] = fin[n]
	fout[i] = fout[n]
	rot[i] = rot[n]
	spin[i] = spin[n]
	wax[i] = wax[n]
	way[i] = way[n]
	wf[i] = wf[n]
	wph[i] = wph[n]
	gy[i] = gy[n]
	bn[i] = bn[n]
	col[i] = col[n]

## Движение и огибающая частицы i → j (двойник: ядро поверх ореола).
func copy_motion(i: int, j: int) -> void:
	vx[j] = vx[i]
	vy[j] = vy[i]
	grav[j] = grav[i]
	drag[j] = drag[i]
	age[j] = age[i]
	wax[j] = wax[i]
	way[j] = way[i]
	wf[j] = wf[i]
	wph[j] = wph[i]
	fin[j] = fin[i]
	fout[j] = fout[i]


func clear() -> void:
	n = 0

func step(dt: float) -> void:
	for i in range(n - 1, -1, -1):
		var a := age[i] + dt
		if a >= life[i]:
			_kill(i)
			continue
		age[i] = a
		var k := maxf(0.0, 1.0 - drag[i] * dt)
		var x_v := vx[i] * k
		var y_v := vy[i] * k + grav[i] * dt
		var y := py[i] + y_v * dt
		if gy[i] >= 0.0 and y > gy[i] and y_v > 0.0:
			# один отскок о землю у ступней, потом частица ложится и тает
			y = gy[i]
			if bn[i] > 0:
				bn[i] -= 1
				y_v = -y_v * CfgFx.BONE_BOUNCE
				x_v *= CfgFx.BONE_FRICTION
				spin[i] *= 0.5
			else:
				y_v = 0.0
				x_v = 0.0
				grav[i] = 0.0
				spin[i] = 0.0
		vx[i] = x_v
		vy[i] = y_v
		px[i] += x_v * dt
		py[i] = y
		rot[i] += spin[i] * dt

func draw(ci: CanvasItem) -> void:
	for i in n:
		var t := age[i] / life[i]
		var a := a0[i]
		if t < fin[i]:
			a *= t / fin[i]
		var rest := 1.0 - t
		if rest < fout[i]:
			a *= rest / fout[i]
		if a <= 0.004:
			continue
		var e := 1.0 - rest * rest
		var s := s0[i] + (s1[i] - s0[i]) * e
		var x := px[i]
		var y := py[i]
		if wf[i] != 0.0:
			var ph := wf[i] * age[i] + wph[i]
			x += wax[i] * sin(ph)
			y += way[i] * sin(ph * 0.71 + wph[i])
		var c := col[i]
		c.a *= a
		var sz := Vector2(s, s * asp[i])
		if rotates:
			ci.draw_set_transform(Vector2(x, y), rot[i])
			ci.draw_texture_rect(tex, Rect2(sz * -0.5, sz), false, c)
		else:
			ci.draw_texture_rect(tex, Rect2(Vector2(x - sz.x * 0.5, y - sz.y * 0.5), sz),
				false, c)
	if rotates:
		ci.draw_set_transform(Vector2.ZERO)
