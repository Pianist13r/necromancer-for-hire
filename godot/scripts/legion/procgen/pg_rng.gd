class_name PgRng
extends RefCounted
##
## Случайность процгена: у каждого шага свой RandomNumberGenerator, сид которого — FNV-1a 64
## от строки «сид|шаг|попытка» (BOOK §2 п.4, §12.4). Правка одного шага не сдвигает
## последовательность остальных, и ничего не берётся от времени, порядка файлов или кадров.
## Сам генератор Godot — PCG32: одна последовательность при одном сиде.
##

## 0xcbf29ce484222325 — смещение FNV-1a 64 в знаковой записи (литерал больше int64 не влезет).
const FNV_OFFSET := -3750763034362895579
const FNV_PRIME := 1099511628211


## FNV-1a 64 по байтам UTF-8. Умножение int64 в Godot переполняется по модулю 2^64 — ровно то,
## что нужно хэшу.
static func hash64(s: String) -> int:
	var h := FNV_OFFSET
	for b in s.to_utf8_buffer():
		h = (h ^ b) * FNV_PRIME
	return h


static func make(run_seed: int, step: String, attempt := 0) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash64("%d|%s|%d" % [run_seed, step, attempt])
	return rng


## Индекс по весам (веса не обязаны давать в сумме 1); все нули — -1.
static func pick_weighted(rng: RandomNumberGenerator, weights: Array) -> int:
	var total := 0.0
	for w: float in weights:
		total += maxf(w, 0.0)
	if total <= 0.0:
		return -1
	var roll := rng.randf() * total
	var upto := 0.0
	for i in weights.size():
		upto += maxf(float(weights[i]), 0.0)
		if roll < upto:
			return i
	for i in range(weights.size() - 1, -1, -1):
		if float(weights[i]) > 0.0:
			return i
	return -1


## Случайное целое на сетке step в [lo, hi] (оба конца — кратные step, если такими заданы).
static func grid(rng: RandomNumberGenerator, lo: int, hi: int, step := 16) -> int:
	if hi <= lo:
		return lo
	return lo + rng.randi_range(0, (hi - lo) / step) * step


## Перемешать копию массива (Фишер — Йетс на своём rng, а не Array.shuffle на глобальном).
static func shuffled(rng: RandomNumberGenerator, src: Array) -> Array:
	var out := src.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = out[i]
		out[i] = out[j]
		out[j] = t
	return out
