"""B-403: localhost integration, owned PIDs and scratch APPDATA only. Requires websockets."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import socket
import subprocess
import time

import websockets


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Relay:
    def __init__(self, args, name, extra=(), wait=True):
        self.port = free_port()
        self.judge_port = free_port()
        while self.judge_port == self.port:
            self.judge_port = free_port()
        self.out = args.out / name
        self.out.mkdir(parents=True, exist_ok=True)
        self.log_path = self.out / "relay.log"
        self.log = self.log_path.open("w", encoding="utf-8")
        env = dict(os.environ, APPDATA=str(args.out / "appdata"), NECRO_NO_DEV_BRIDGE="1")
        self.proc = subprocess.Popen(
            [args.godot, "--headless", "--path", str(args.project / "godot"),
             "--script", args.relay_script, "--", "--mute", "--port", str(self.port),
             "--judge-port", str(self.judge_port), *extra],
            env=env, stdout=self.log, stderr=subprocess.STDOUT,
        )
        if wait:
            try:
                end = time.monotonic() + 15
                while time.monotonic() < end:
                    if self.proc.poll() is not None:
                        raise AssertionError(self.text())
                    if "ретранслятор слушает" in self.text():
                        return
                    time.sleep(0.05)
                raise AssertionError("relay startup timed out")
            except BaseException:
                self.close()
                raise

    def text(self):
        return self.log_path.read_text(encoding="utf-8", errors="replace")

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        self.log.close()


async def packet(ws, kind, timeout=3):
    async with asyncio.timeout(timeout):
        while True:
            value = json.loads(await ws.recv())
            if value.get("t") == kind:
                return value


async def send(ws, **value):
    await ws.send(json.dumps(value))


async def player(port, name="Test", build="security"):
    ws = await websockets.connect(f"ws://127.0.0.1:{port}", proxy=None, ping_interval=None,
                                  close_timeout=0.2)
    await send(ws, t="hello", v=2, build=build, name=name)
    await packet(ws, "welcome")
    return ws


async def idle_and_build(args):
    relay = Relay(args, "idle", ("--judges", "0", "--lobby-idle", "700"))
    ws = None
    try:
        ws = await player(relay.port, build="ok\nFORGED\r\x1b[31m\u202etest")
        # Application ping and WebSocket pong must not keep an abandoned lobby alive.
        for _ in range(3):
            await send(ws, t="ping", ms=1)
            await asyncio.sleep(0.25)
        error = await packet(ws, "error", timeout=3)
        assert error["code"] == "idle_timeout", error
        assert "\nFORGED" not in relay.text() and "\x1b[31m" not in relay.text(), relay.text()
    finally:
        if ws:
            await ws.close()
        relay.close()


async def reserve_and_roles(args):
    relay = Relay(args, "reserve", ("--judges", "1"))
    peers = []
    try:
        # Fill all 48 public slots BEFORE the judge connects.
        for i in range(48):
            peers.append(await player(relay.port, f"P{i}"))
        await send(peers[0], t="create", map="pvp:duel")
        room = await packet(peers[0], "room")
        await send(peers[1], t="join", code=room["code"])
        await packet(peers[0], "start")
        await packet(peers[1], "start")
        end = time.monotonic() + 15
        while "судья на месте" not in relay.text() and time.monotonic() < end:
            await asyncio.sleep(0.1)
        assert "судья на месте" in relay.text(), "full public quota blocked judge\n" + relay.text()
        assert "SCRIPT ERROR" not in relay.text(), relay.text()
        # Close the match, and thereby its OWN child, before stopping this relay.
        await send(peers[1], t="leave")
        await packet(peers[0], "left")
        await peers[2].close()
        await asyncio.sleep(0.1)
        async with websockets.connect(f"ws://127.0.0.1:{relay.port}", proxy=None,
                                      close_timeout=0.2) as ws:
            await send(ws, t="judge", v=2, room=room["code"], key="unknown")
            try:
                await packet(ws, "start", timeout=2)
            except websockets.ConnectionClosed:
                pass
            else:
                raise AssertionError("public entry accepted judge")
        assert "судья на публичном входе" in relay.text(), relay.text()
    finally:
        # On failure, disconnect players first so relay closes their room and child PID.
        await asyncio.gather(*(ws.close() for ws in peers), return_exceptions=True)
        await asyncio.sleep(0.2)
        relay.close()


def slow_receiver(args):
    relay = Relay(args, "slow-receiver", ("--judges", "0"))
    try:
        env = dict(os.environ, APPDATA=str(args.out / "appdata"), NECRO_NO_DEV_BRIDGE="1")
        result = subprocess.run(
            [args.godot, "--headless", "--path", str(args.project / "godot"),
             "--script", "res://tests/net_attack_probe.gd", "--", "--mute", "--port",
             str(relay.port), "--which", "458"],
            env=env, capture_output=True, encoding="utf-8", errors="replace", timeout=180,
        )
        (relay.out / "probe.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        assert result.returncode == 0 and "SCRIPT ERROR" not in relay.text(), result.stdout
        print(" | ".join(line for line in result.stdout.splitlines() if "ATTACK" in line))
    finally:
        relay.close()


def busy_listener(args, internal):
    with socket.socket() as held:
        held.bind(("127.0.0.1", 0))
        held.listen()
        occupied = held.getsockname()[1]
        flag = "--judge-port" if internal else "--port"
        relay = Relay(args, "busy-judge" if internal else "busy-public",
                      ("--judges", "1", flag, str(occupied)), wait=False)
        try:
            code = relay.proc.wait(timeout=15)
            assert code != 0, "occupied listener didn't fail closed"
            assert "не удалось" in relay.text(), relay.text()
            # The relay must have exited, not stay available without its internal listener.
            with socket.socket() as probe:
                probe.settimeout(1)
                assert probe.connect_ex(("127.0.0.1", relay.port)) != 0
        finally:
            relay.close()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline-ref", help="Read old relay from git into scratch for regression")
    parser.add_argument("--slow-receiver", action="store_true", help="Also run B-378 attacks 4/5/8")
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    args.relay_script = "res://scripts/legion/net/net_relay.gd"
    if args.baseline_ref:
        old = subprocess.run(["git", "show", f"{args.baseline_ref}:godot/scripts/legion/net/net_relay.gd"],
                             cwd=args.project, check=True, capture_output=True).stdout
        baseline = args.out / "baseline_relay.gd"
        baseline.write_bytes(old)
        args.relay_script = str(baseline)
    failures = []
    checks = [("idle/build", lambda: idle_and_build(args)),
              ("reserved judge", lambda: reserve_and_roles(args)),
              ("busy judge listener", lambda: busy_listener(args, True)),
              ("busy public listener", lambda: busy_listener(args, False))]
    if args.slow_receiver:
        checks.append(("slow receiver", lambda: slow_receiver(args)))
    for name, check in checks:
        try:
            value = check()
            if asyncio.iscoroutine(value):
                await value
            print(f"{name}: OK")
        except (AssertionError, OSError, TimeoutError, subprocess.TimeoutExpired) as error:
            print(f"{name}: FAIL — {error}")
            failures.append(name)
    print(f"NET SECURITY: {'FAIL' if failures else 'OK'}")
    raise SystemExit(bool(failures))


if __name__ == "__main__":
    asyncio.run(main())
