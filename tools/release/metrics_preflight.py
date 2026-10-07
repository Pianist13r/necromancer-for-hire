"""Сервер статистики раньше клиента (METRICS_AUDIT_1007, риск 2).

Клиент с версией вне ACCEPTED_VERSIONS сервера получает 400 и повторяет пакет раз в минуту
без конца, а его запуски молча пропадают. Перед выпуском проверяются:
  1) тег выпуска совпадает с ReleaseInfo.VERSION клиента;
  2) версия есть в ACCEPTED_VERSIONS кода сервера (tools/server/metrics_service.py);
  3) рабочий сервер уже принимает её: пакет seq=1 с новым случайным кодом сеанса ничего не
     записывает (неизвестный сеанс → 409, откат транзакции), а непринятая версия → 400.

    python -X utf8 tools/release/metrics_preflight.py <версия> [--skip-live-metrics]

Вызывается из make_github_release.py; отдельный запуск — чтобы проверить заранее.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import secrets
import urllib.error
import urllib.request

REPO = Path(__file__).resolve().parents[2]


def constant(path: Path, name: str) -> str:
    found = re.findall(rf'(?m)^const {name} := "([^"]+)"', path.read_text(encoding="utf-8"))
    if len(found) != 1:
        raise SystemExit(f"не найдено const {name} в {path}")
    return found[0]


def accepted_versions(server: Path) -> frozenset:
    spec = importlib.util.spec_from_file_location("_release_metrics_service", server)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return frozenset(module.ACCEPTED_VERSIONS)


def probe_live(version: str, url: str) -> int:
    body = json.dumps({"schema": 1, "session": secrets.token_hex(16), "seq": 1, "version": version,
                       "platform": "Windows", "play_seconds": 1}).encode()
    request = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as reply:
            return reply.status
    except urllib.error.HTTPError as error:
        return error.code
    except (urllib.error.URLError, OSError) as error:
        raise SystemExit(f"сервер статистики {url} недоступен ({error}); "
                         "без сети — --skip-live-metrics и проверить позже") from None


def check(release: str, live: bool = True, repo: Path = REPO) -> None:
    version = constant(repo / "godot/scripts/common/release_info.gd", "VERSION")
    if release != version:
        raise SystemExit(f"тег выпуска {release} не равен ReleaseInfo.VERSION {version}")
    server = repo / "tools/server/metrics_service.py"
    if not server.is_file():
        # Публичный снимок не содержит tools/server: там выпуск не сверяется с сервером автора.
        print("ВНИМАНИЕ: нет tools/server/metrics_service.py — проверка статистики пропущена")
        return
    accepted = accepted_versions(server)
    if version not in accepted:
        raise SystemExit(f"{version} нет в ACCEPTED_VERSIONS {server} ({', '.join(sorted(accepted))}): "
                         "дополнить код сервера и выкатить его ДО выпуска клиента (tools/server/METRICS.md)")
    print(f"статистика: код сервера принимает {version}")
    if not live:
        print("ВНИМАНИЕ: рабочий сервер статистики не проверен (--skip-live-metrics) — "
              "проверить до публикации: python -X utf8 tools/release/metrics_preflight.py " + version)
        return
    url = constant(repo / "godot/scripts/common/play_metrics.gd", "ENDPOINT")
    status = probe_live(version, url)
    if status == 400:
        raise SystemExit(f"рабочий сервер статистики отвечает 400 на {version}: он ещё не обновлён — "
                         "выкатить tools/server по METRICS.md до выпуска клиента")
    if status != 409:
        raise SystemExit(f"рабочий сервер статистики: неожиданный ответ {status} на пробу {version}")
    print(f"статистика: рабочий сервер принимает {version}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version")
    parser.add_argument("--skip-live-metrics", action="store_true")
    args = parser.parse_args()
    check(args.version, live=not args.skip_live_metrics)


if __name__ == "__main__":
    main()
