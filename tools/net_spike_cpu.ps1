# Секунды процессора СВОЕГО сервера спайка (tools/net_spike.sh). Ищем по уникальному порту в
# командной строке: $! у нативного exe из bash — PID обёртки msys, а не движка, а имя образа
# общее с чужими гейтами и сериями на этой машине.
# Совпадений два: Godot_*_console.exe — только обёртка консоли, сам движок — дочерний
# Godot_*.exe с той же командной строкой; суммируем оба.
param([int]$Port)
$ps = @(Get-CimInstance Win32_Process |
	Where-Object { $_.CommandLine -like "*spike_server.gd*--port $Port *" })
if ($ps.Count -eq 0) {
	'-1'
} else {
	$sum = 0.0
	foreach ($p in $ps) {
		$g = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
		if ($g) { $sum += $g.CPU }
	}
	$sum.ToString([cultureinfo]::InvariantCulture)
}
