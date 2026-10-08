extends SceneTree
##
## Оснастка звука (аудит 08.10, SND-17): синтезирует каждый эффект SfxGen (все дубли) в WAV и
## печатает таблицу «id → длительность, пик, RMS, время синтеза». Колонки не нужны — проверка
## числами и файлами; послушать WAV владелец может сам.
##
##   "$GODOT" --headless --path godot --script res://tests/audio_render_sfx.gd -- --mute \
##       --out C:/AI/necro/batches/audio-1008/sfx
##
## Не гейт (имя не legion_*_test): пишет файлы вне репозитория. Итог — строка «SFX RENDER: N»,
## таблица — ещё и в <out>/sfx_table.tsv.
##


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "user://sfx_render"
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out)
	var rows := PackedStringArray(["id\tдубль\tдлительность_с\tпик\tпик_dBFS\tRMS_dBFS\tсинтез_мс"])
	var total_ms := 0.0
	var count := 0
	print("%-15s %2s %6s %6s %8s %8s %7s" % ["id", "v", "сек", "пик", "пик dB", "RMS dB", "мс"])
	for id in SfxGen.ids():
		for v in SfxGen.variant_count(id):
			var t0 := Time.get_ticks_usec()
			var stream := SfxGen.synth(id, v)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			total_ms += ms
			var m := _measure(stream)
			var path := "%s/%s_%d.wav" % [out, id, v]
			var err := stream.save_to_wav(path)
			if err != OK:
				push_error("не записан %s (%d)" % [path, err])
			var peak_db := linear_to_db(maxf(float(m["peak"]), 0.000001))
			var rms_db := linear_to_db(maxf(float(m["rms"]), 0.000001))
			print("%-15s %2d %6.3f %6.3f %8.1f %8.1f %7.1f"
				% [id, v, float(m["sec"]), float(m["peak"]), peak_db, rms_db, ms])
			rows.append("%s\t%d\t%.3f\t%.3f\t%.1f\t%.1f\t%.1f"
				% [id, v, float(m["sec"]), float(m["peak"]), peak_db, rms_db, ms])
			count += 1
	var f := FileAccess.open(out + "/sfx_table.tsv", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(rows) + "\n")
		f.close()
	print("SFX RENDER: %d файлов, синтез всего %.0f мс (%s)" % [count, total_ms, out])
	SfxGen.clear_cache()
	quit(0)


## Пик и RMS звучащей части (громче 1 % пика), длительность — по всем сэмплам.
func _measure(stream: AudioStreamWAV) -> Dictionary:
	@warning_ignore("integer_division")
	var n := stream.data.size() / 2
	var peak := 0.0
	for k in n:
		peak = maxf(peak, absf(stream.data.decode_s16(k * 2) / SfxGen.INT16_MAX))
	var sum_sq := 0.0
	var cnt := 0
	for k in n:
		var x := stream.data.decode_s16(k * 2) / SfxGen.INT16_MAX
		if absf(x) >= peak * 0.01:
			sum_sq += x * x
			cnt += 1
	return {"sec": float(n) / stream.mix_rate, "peak": peak, "rms": sqrt(sum_sq / maxi(cnt, 1))}
