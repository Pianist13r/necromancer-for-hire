# Contributing

Pull requests, bug reports, balance notes and ideas are welcome — in Russian or English.

1. **Sign the CLA.** Before your first pull request is merged, comment on it:
   "I have read the CLA v1.0 and I hereby sign it." ([CLA.md](CLA.md)). Without it we cannot merge.
2. **Bugs:** open an issue with OS, build version (Settings → «О игре»), steps and, if possible,
   a screenshot. Saves live in `%APPDATA%/Godot/app_userdata/…` (Windows),
   `~/Library/Application Support/Godot/app_userdata/…` (macOS), `~/.local/share/godot/app_userdata/…` (Linux).
3. **Code:** Godot 4.7, GDScript, static typing. Before a pull request run the gate:
   `tools/legion_gate.sh` — the last line must be `GATE OK`.
4. **Art, music, voice:** say where it came from and under which license. AI-generated content —
   name the tool/service; services whose terms forbid commercial use cannot be accepted.
5. Keep pull requests small and focused; one topic per PR.

По-русски: присылайте правки, баги, заметки по балансу. Перед первым PR — подпись CLA комментарием.
Код — через гейт `tools/legion_gate.sh`. Для арта и звука укажите источник и лицензию.
