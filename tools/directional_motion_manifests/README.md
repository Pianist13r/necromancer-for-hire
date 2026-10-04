# Извлечение направленных клипов из AI motion video

`tools/directional_motion_extract.py` принимает JSON manifest и создаёт **новую** папку
с `spr_NN.png`, `clip.json`, `extraction.json`, keyed standing reference, GIF и contact sheet.
Существующую папку не перезаписывает. Требуются Python 3.11+, NumPy, OpenCV, SciPy и Pillow.
Исходные видео остаются вне Git. Подключение в CfgAnim и визуальная приёмка — отдельный этап.

```powershell
$rawVideo = "<path-to-reviewed-raw-video.mp4>"
$outRoot = Join-Path $env:TEMP "necro-motion"
python -X utf8 tools/directional_motion_extract.py tools/directional_motion_manifests/zombie_death_e_pilot.json --source $rawVideo --out "$outRoot/full-192"
python -X utf8 tools/directional_motion_extract.py tools/directional_motion_manifests/zombie_death_e_pilot.json --source $rawVideo --runtime-scale .5 --out "$outRoot/half-96"
python -X utf8 tools/test_directional_motion_extract.py
```

Manifest задаёт точные целочисленные `samples[].frame` и `seconds` (проверяются по FPS видео),
`duration_weight` каждого кадра, `fps`, `total_seconds` и `contact_frame` в индексах **выбранных
samples**, либо -1. Без схлопывания это финальные PNG; при схлопывании exporter сохраняет
момент контакта и записывает пересчитанный финальный индекс в `clip.json`.
Список по умолчанию должен идти по порядку, кадры — внутри видео. Только явный boolean
`allow_reverse_samples=true` разрешает иной порядок для просмотренного reverse-recovery;
строка "true" не является разрешением. Номера frame/time и границы видео проверяются как раньше.
`source_sha256` защищает
от случайной подмены просмотренного источника. `--source` разрешает перенести raw video
на другой компьютер, сохраняя эту проверку. `source_video` может быть абсолютным либо
относительным к manifest. Конкретный пилот: frames 45,48,…,114 (1,5…3,8 с из 30 fps),
24 PNG / 0,4 с / fps15. Каждый duration равен .25; сумма 6/15 = .4 с.

В tracked manifest хранится переносимый `raw-video/<basename>` без локального абсолютного
пути; при воспроизведении raw источник явно передаётся через `--source`. Он должен совпасть
по SHA256. Папка `raw-video` здесь обозначает внешний архив источников и не содержит видео
в Git. SHA256 и исходные номера кадров сохраняют связь с проверенным видео.

Фон определяется по фактическому hue и saturation границы **каждого** кадра, включая
тёмную тень того же chroma. `key.hue_tolerance_degrees`, `min_saturation` и
`border_saturation_ratio` (default .8) управляют диапазоном. Менее насыщенный тёмный purple
ink того же hue сохраняется; замкнутые тёмные детали лица/шлема остаются непрозрачными,
а яркий key-фон внутри отверстия пропа остаётся прозрачным. Solid dark edge рядом с opaque
core не считается смесью BG→FG; иначе alpha projection делал дырки в контуре. Удалённый
от opaque core key-hue JPEG edge noise убирается. Отделённые пропы сохраняются;
largest-component фильтра нет. Остальная полупрозрачная кромка очищается от spill через
ближайший непрозрачный foreground. `key_algorithm=border-hsv-opaque-ink-v2` в clip/record
отличает исправленный matte от первого hue-only варианта. Содержимое у края исходного
видео или отсутствие однородного key-фона отвергается: exporter не восстанавливает обрезанные
моделью части тела. Если персонаж содержит тот же hue, нужен другой фон или специальная маска;
автоматическая проверка не может отличить материал от одинакового key-цвета.

Стоячая высота и feet bottom-center измеряются на **первом source frame 0**, а не первом
отобранном кадре. Один affine применяется ко всем кадрам: никаких per-frame bbox-center,
нормализаций роста или растягивания лежащего тела. `normalization.source_standing_bbox`
и `source_pivot_px` позволяют явно задать просмотренную фигуру/ступни, например если оружие
выходит выше головы или ниже ног. Все пропы всё равно входят в union и сохраняются.

Базовый `standing_height_px` — 192; `--runtime-scale .5` даёт 96, не изменяя raw source.
Union включает исходную стоячую фигуру и все выбранные позы. Из `canvas_sizes` выбирается
достаточный квадрат; при runtime-scale список размеров тоже масштабируется. Прозрачный
`padding_px` сохраняется даже у меньшего варианта. Если допустимых размеров недостаточно,
извлечение завершается ошибкой вместо автоматического уменьшения фигуры.

`pivot_px` переносит исходные ступни на единую землю. `figure_fill=standing_height_px/canvas`
позволяет CharView сохранить прежний body_h при любом размере canvas. Первое сравнение давало
half192 / standing96 / fill.5. Compact manifests используют master canvas_sizes [256,320,384],
`--runtime-scale .5` выбирает из [128,160,192], padding8. Zombie motions помещаются в128² /
standing96 / fill.75. Размером фигуры не становится bbox смерти. Raw RGBA 24 кадров128² —
1.5 MiB вместо3.375 MiB192²; mipmaps прибавляют примерно1/3.
Это оценка данных текстур, без накладных расходов движка и возможных копий CPU/GPU.

`clip.json` содержит durations, explicit final contact_frame, pivot/figure_fill и source
samples. `direction_name` — короткое имя e/se/s/ne/n; `direction` — единичный Vector2
в координатах экрана (+Y вниз). Это диагностические поля; runtime выбирает variant по CfgAnim.
`extraction.json` сохраняет исходный manifest, SHA256, измерения key, единую matrix,
padding/alpha QA и оценку памяти. `src_index` не записывается: video frame numbers не являются
старым mapping игровых кадров. Runtime loader должен читать explicit contact_frame, сохраняя
legacy mapping при отсутствии нового поля.

`collapse_exact_duplicates=true` объединяет только соседние byte-identical RGBA после
общего transform. Durations складываются; начало контактного кадра остаётся отдельной
границей, explicit `contact_frame` пересчитывается. `source_sample_groups` сохраняет все
входные samples каждого PNG; `source_frames` — первый sample группы. Никакого приблизительного
слияния похожих поз нет. Например dense смерть SE выбирает24 samples из15 исходных кадров;
повторы сокращаются до15 PNG без изменения полного времени .4 с.

GIF: `preview_runtime.gif` использует тот же retiming с квантованием до 10 мс формата GIF;
`preview_slow.gif` показывает позы по 100 мс. `preview_game44.gif` и `preview_game88.gif`
показывают одинаковый игровой рост full/half вариантов. Contact sheet содержит индекс
финального PNG, source frame и время. Более короткие чем 10 мс интервалы GIF непредставимы;
для такого retiming нужен видео-preview вместо GIF.

QA проверяет одинаковый canvas, отсутствие обрезания, прозрачный padding, остаток key-цвета,
согласованность frame/time/SHA256, единый scale/pivot и sum(durations)/fps. Автоматические
проверки не подтверждают правильную анатомию, позу контакта, камеру, объём или естественность;
финальный клип нужно смотреть на игровом фоне при реальном размере и в движении.

## Zombie attack pilot: пять направлений

`zombie_attack_{e,s,se,ne,n}_pilot.json` фиксируют 24 выбранных PNG, fps20 и полный визуальный
цикл .5 с. PNG5 — контакт: первые пять duration дают .1 с, PNG5…23 — .4 с. Во всех manifest
source frame0 определяет standing scale/feet. Запускать с `--runtime-scale .5`: получаются
canvas128 / standing96 / figure_fill.75. Это одинаковый body_h для всех ракурсов и прежней ходьбы.

| Ракурс | Source contact (30 fps) | Source finish | Примечание |
|---|---|---|---|
| E | frame27 / .900 с | frame54 / 1.800 с | Wan2.7 attack_e_single, один синхронный двуручный толчок |
| SE | frame37 / 1.233 с | frame57 / 1.900 с | Один замах; 1.4 с уже удерживает вытянутые руки |
| NE | frame17 / .567 с | frame57 / 1.900 с | Полное вытяжение руки |
| N | frame21 / .700 с | frame57 / 1.900 с | Полное вытяжение руки |
| S | frame20 / .667 с | frame57 / 1.900 с | Первая левая тычка; повторные удары пропущены |

Фронтальный исходник чередует несколько тычков. Для одного runtime удара точный список
пропускает source frames25…38 и соединяет похожие позы frame24→39, затем идёт возврат.
На стыке alpha-IoU ≈.9045, смещение центра силуэта ≈.938 px при игровом росте44; это помогает
найти менее заметный стык, но не заменяет просмотр GIF. Manifest помечает стык как требующий
визуальной приёмки (root просмотрел и принял стык S). Клип не подключается в CfgAnim автоматически. Full192-вариант смерти
сохраняется для сравнения; принятый root для runtime-пробы deathE — half96.

Оба `zombie_attack_e_*_candidate.json` сохраняют отклонённые монтажные варианты старого видео:
скачок anticipation либо recovery не соответствует плавной атаке. В runtime они не входят.
Текущий E manifest использует отдельный принятый source с одним толчком.

## Zombie death pilot

Все смерти имеют .4 с / fps15 / contact-1 и один исходный standing scale. Точные списки
кадров находятся в manifest: E45…114, S36…90, SE18…32 (dense repeats), NE12…66, N5…35.
Source frame0 всегда задаёт стоячую фигуру и землю. Более ранние отвергнутые SE/NE/N
источники с изменением внешности не извлекаются и не используются.

## Пилоты skeleton, guard, clerk, signer

Manifest `<character>_<state>_<dir>_pilot.json` содержит выбранные delivery исходные frames,
source SHA256 и contact. Первый принятый batch: skeleton attack E/SE/N и death E/SE/N,
guard attack E/SE и death E/SE/N, clerk attack E/SE и death E/NE,
signer attack E/SE и death E/SE. Raw source motion/identity просмотрены root;
финальный показ через CharView остаётся отдельной проверкой. Старый обрезанный Skeleton E
attack заменён padded retry; нарушение source border не разрешается обходить.

Компактный canvas выбирается для каждого whole-motion union отдельно, при прежнем standing96.
В этом batch достаточно 128 либо160; guard death N требует192 из-за ширины падения/щита.
Поэтому `figure_fill` бывает .75/.6/.5, а прежний игровой body_h остаётся одинаковым.
Все эти attack .5 с / fps20 / contact PNG5 на .1 с, death .4 с / fps15 / contact-1.
Manifest хранится с переносимым raw-video basename; локальный source передаётся через --source.

## Явные reverse-recovery пилоты Mimic/Boss E

Исходники содержат только prep→impact. `allow_reverse_samples=true` означает сознательное
воспроизведение отобранных исходных поз назад для recovery: это не естественный recovery
из source video. Mimic закрывает рот на source33/1.1 с, затем открывает обратно;
Boss E использует headfoot retry: первый полный вынос ключа source28/.933 с, затем обратный возврат. Старый endpoint937 с уменьшением тела исключён.
Exact samples и веса записаны в manifest, PNG5 contact на .1 с, полный цикл .5 с.
Пилот Mimic запускать с `--runtime-scale .5` (standing96), Boss с `--runtime-scale .75`
(standing144); `runtime_scale` в manifest — provenance, CLI scale выбирается явно.
Boss144/canvas288 принят root по сравнению с standing192/canvas384 при actual body106,
включая 2x enlargement: base RGBA7.59375 MiB вместо13.5 MiB за24 PNG. Gait masters не меняются.
Mimic E reverse принят по движению, contact anchor проходит отдельную проверку.
Остальные ракурсы требуют собственного просмотра перед подключением.

Delivery batch completion: 62 curated clips (20 attacks + 42 deaths) are reproducible from portable manifests and raw SHA256. Ordinary clips use standing96; all five boss deaths use standing144, total_seconds=1.0 and fps=24. Attack contact remains final PNG5 at0.1s; ordinary deaths remain0.4s. All runtime PNGs use the corrected border-hsv-opaque-ink-v2 matte. Final CharView acceptance is separate from source/bounds and import QA.


Root batch completion: ghost, beetle and lawyer have five accepted attacks and the missing E death. Mimic and boss use five explicit reverse-recovery attacks. Mimic PNG foot anchor review passed for all five views; first and last recovery images match exactly. Boss contacts were refined using dense source frames (E28, SE31, S32, NE24, N31); prep ends before the final strike pose. All characters retain one source0 scale and one affine across each clip. Source sampling, SHA and exact retime weights are recorded in individual portable manifests. Boss144 is retained for all actions, ordinary96 elsewhere. Final CharView/battle motion review belongs to the integration stage.
