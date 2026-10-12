#!/usr/bin/env python3
"""Exercise a built Automator through its public CLI in an isolated display.

Run on Linux with dbus-run-session and xvfb-run using
``-s '-screen 0 1920x1080x24'``. No existing terminal is used.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Self


class Session:
    def __init__(
        self,
        binary: Path,
        directory: Path,
        *,
        config: str = "",
        default_target: bool = False,
    ) -> None:
        self.binary = binary
        self.directory = directory
        directory.mkdir(mode=0o700, exist_ok=True)
        self.name = (
            None
            if default_target
            else f"com.automator.t{os.getpid()}.{directory.name[:3]}"
        )
        self.env = os.environ.copy()
        for key, name in (
            ("XDG_RUNTIME_DIR", "r"),
            ("XDG_CONFIG_HOME", "c"),
            ("XDG_STATE_HOME", "s"),
        ):
            path = directory / name
            path.mkdir(mode=0o700)
            self.env[key] = str(path)
        config_dir = Path(self.env["XDG_CONFIG_HOME"]) / "ghostty"
        config_dir.mkdir()
        (config_dir / "config.ghostty").write_text(config)
        self.env["GDK_BACKEND"] = "x11"
        self.env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        self.env.pop("GHOSTTY_RESOURCES_DIR", None)
        self.surface = ""
        self.socket_path = ""

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_args: object) -> None:
        self.cleanup()

    def run(
        self,
        action: str,
        *args: str,
        success: bool = True,
        ignore_sigchld: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        target = [f"--class={self.name}"] if self.name else []
        result = subprocess.run(
            [str(self.binary), f"+{action}", *target, *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
            preexec_fn=ignore_child_signal if ignore_sigchld else None,
        )
        if success and result.returncode:
            raise AssertionError(
                f"{action} failed ({result.returncode}): {result.stderr}\n{result.stdout}"
            )
        return result

    def query(self, action: str, *args: str) -> dict[str, Any]:
        return json.loads(self.run(action, *args).stdout)

    def surfaces(self) -> list[dict[str, Any]]:
        data = self.query("list-surfaces", "--format=json")
        return [
            surface
            for window in data["windows"]
            for tab in window["tabs"]
            for surface in tab["surfaces"]
        ]

    def read(self) -> str:
        return self.query("get-screen", f"--surface={self.surface}", "--format=json")[
            "content"
        ]

    def wait_text(self, text: str) -> str:
        deadline = time.monotonic() + 10
        content = ""
        while time.monotonic() < deadline:
            content = self.read()
            if text in content:
                return content
            time.sleep(0.05)
        raise AssertionError(f"Screen never contained {text!r}: {content!r}")

    def send(self, text: str) -> None:
        self.run("send-text", f"--surface={self.surface}", f"--text={text}")

    def key(self, key: str, *args: str) -> None:
        self.run("send-key", f"--surface={self.surface}", f"--key={key}", *args)

    def cleanup(self) -> None:
        try:
            for surface in self.surfaces():
                self.run("close-surface", f"--surface={surface['id']}")
        except (AssertionError, OSError, subprocess.TimeoutExpired):
            # A failed startup might not have a reachable socket or any surface.
            pass
        for pid in self.own_pids():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                continue
        deadline = time.monotonic() + 1
        while self.own_pids() and time.monotonic() < deadline:
            time.sleep(0.01)
        for pid in self.own_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                continue

    def own_pids(self) -> list[int]:
        """Find only this case's GUI, excluding CLI calls and terminal children."""
        marker = os.fsencode(f"XDG_RUNTIME_DIR={self.env['XDG_RUNTIME_DIR']}")
        parents = {}
        for process in Path("/proc").glob("[0-9]*"):
            try:
                if marker not in (process / "environ").read_bytes().split(b"\0"):
                    continue
                if (process / "exe").resolve() != self.binary:
                    continue
                argv = (process / "cmdline").read_bytes().split(b"\0")
                parent_line = next(
                    line
                    for line in (process / "status").read_text().splitlines()
                    if line.startswith("PPid:")
                )
            except OSError:
                continue
            if any(arg.startswith(b"+") for arg in argv[1:]):
                continue
            parents[int(process.name)] = int(parent_line.split()[1])
        # The PTY fork retains the GUI executable until its shell exec begins.
        return [pid for pid, parent in parents.items() if parent not in parents]

    def wait_stopped(self, socket_path: Path | None = None) -> None:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            pids = self.own_pids()
            socket_exists = socket_path is not None and socket_path.exists()
            if not pids and not socket_exists:
                return
            time.sleep(0.01)
        raise AssertionError(
            f"Isolated GUI did not stop: pids={pids}, socket={socket_path}, "
            f"socket_exists={socket_exists}"
        )


def ignore_child_signal() -> None:
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)


def test_startup(binary: Path, directory: Path) -> None:
    shell = "--command=bash --noprofile --norc"
    with Session(
        binary, directory / "no_initial", config="initial-window = false\n"
    ) as session:
        report = session.query("bootstrap", shell)
        surface = session.surfaces()[0]
        assert surface["id"] == report["data"]["surface_id"]
        assert surface["rows"] > 0 and surface["cols"] > 0
        assert len(session.surfaces()) == 1
        session.query("get-screen", f"--surface={surface['id']}", "--format=json")
    print(
        "PASS bootstrap overrides initial-window=false with one usable terminal",
        flush=True,
    )

    configured_class = f"com.hyperb1iss.automator.configured{os.getpid()}"
    with Session(
        binary,
        directory / "default_target",
        config=f"class = {configured_class}\n",
        default_target=True,
    ) as session:
        report = session.query("bootstrap", shell)
        data = report["data"]
        assert Path(data["socket_path"]).name == "ghostty-automator.sock"
        assert session.query("doctor")["data"]["surface_id"] == data["surface_id"]
        assert len(session.surfaces()) == 1
        session.query("get-screen", f"--surface={data['surface_id']}", "--format=json")
    print("PASS default bootstrap target clears configured class", flush=True)

    with Session(binary, directory / "ignored_sigchld") as session:
        session.env["DISPLAY"] = ":39999"
        session.env.pop("WAYLAND_DISPLAY", None)
        began = time.monotonic()
        result = session.run(
            "bootstrap", "--timeout-ms=700", success=False, ignore_sigchld=True
        )
        report = json.loads(result.stdout)
        assert result.returncode != 0 and report["ok"] is False
        assert report["data"]["started"] is False
        assert report["error"]["code"] == "LaunchFailed"
        assert time.monotonic() - began < 3
        session.wait_stopped()
    print("PASS inherited SIGCHLD ignore returns bounded startup JSON", flush=True)

    with Session(binary, directory / "expired_launch") as session:
        result = session.run("bootstrap", shell, "--timeout-ms=20", success=False)
        report = json.loads(result.stdout)
        assert result.returncode != 0 and report["ok"] is False
        assert report["error"]["code"] == "StartupTimedOut"
        assert report["data"]["log_path"], "deadline elapsed before exercising launch"
        assert report["data"]["started"] is False
        session.wait_stopped()
        retry = session.query("bootstrap", shell)
        assert retry["data"]["started"] is True
        assert len(session.surfaces()) == 1
    print("PASS expired launch stops its GUI before a clean retry", flush=True)

    with Session(binary, directory / "bad_gl") as session:
        session.env["MESA_GL_VERSION_OVERRIDE"] = "1.0"
        result = session.run("bootstrap", shell, "--timeout-ms=700", success=False)
        report = json.loads(result.stdout)
        assert result.returncode != 0 and report["ok"] is False
        assert report["error"]["code"] == "StartupTimedOut"
        surfaces = [
            surface
            for window in report["data"]["windows"]
            for tab in window["tabs"]
            for surface in tab["surfaces"]
        ]
        assert surfaces, "GL failure did not exercise a reported surface"
        assert all(surface["rows"] == 0 or surface["cols"] == 0 for surface in surfaces)
        assert report["data"]["surface_id"] is None
        assert report["data"]["started"] is False
        session.wait_stopped()
    print("PASS zero-grid GL failure cannot report terminal readiness", flush=True)

    with Session(binary, directory / "concurrent_start") as session:
        barrier = threading.Barrier(12)

        def bootstrap_together() -> dict[str, Any]:
            barrier.wait(timeout=5)
            return session.query("bootstrap", shell)

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            reports = list(pool.map(lambda _: bootstrap_together(), range(12)))
        ids = {report["data"]["surface_id"] for report in reports}
        assert len(ids) == 1 and None not in ids
        assert sum(report["data"]["started"] for report in reports) == 1
        assert len(session.surfaces()) == 1
        assert len(session.own_pids()) == 1
    print(
        "PASS 12 concurrent cold bootstraps share one process and surface", flush=True
    )

    # Exercise teardown directly rather than the normal close-confirmation UI.
    with Session(
        binary, directory / "graceful_exit", config="confirm-close-surface = false\n"
    ) as session:
        report = session.query("bootstrap", shell)
        assert len(session.own_pids()) == 1
        socket_path = Path(report["data"]["socket_path"])
        assert socket_path.exists()
        session.run("close-surface", f"--surface={report['data']['surface_id']}")
        session.wait_stopped(socket_path)
    print(
        "PASS closing the last surface exits the GUI and removes its socket", flush=True
    )


def test_session(session: Session) -> None:
    cold = session.run("doctor", success=False)
    assert cold.returncode != 0, "doctor unexpectedly found a fresh isolated session"
    cold_report = json.loads(cold.stdout)
    assert cold_report["ok"] is False

    # An accepting but silent endpoint must not hang discovery or be replaced.
    socket_path = Path(cold_report["data"]["socket"]["path"])
    socket_path.parent.mkdir(mode=0o700, exist_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stalled:
        stalled.bind(str(socket_path))
        stalled.listen()
        began = time.monotonic()
        blocked = session.run("doctor", "--timeout-ms=150", success=False)
        assert blocked.returncode != 0
        assert json.loads(blocked.stdout)["error"]["code"] == "IPCTimedOut"
        assert time.monotonic() - began < 2
        refused = session.run("bootstrap", "--timeout-ms=200", success=False)
        assert json.loads(refused.stdout)["data"]["started"] is False
    socket_path.unlink()
    print("PASS deadline and refusal to replace an unresponsive socket", flush=True)

    boot = session.query("bootstrap", "--command=bash --noprofile --norc")
    assert boot["ok"] is True
    data = boot["data"]
    session.surface = data["surface_id"]
    session.socket_path = data["socket_path"]
    assert data["started"] is True
    initial = session.surfaces()
    assert [surface["id"] for surface in initial] == [session.surface]
    assert session.query("doctor")["ok"] is True
    again = session.query("bootstrap")["data"]
    assert again["started"] is False
    assert again["surface_id"] == session.surface
    assert len(session.surfaces()) == 1, "repeated bootstrap created another window"
    print("PASS cold bootstrap, doctor, session isolation, reuse", flush=True)

    session.send("printf 'auto%s\\\\n' 'mator-text-ok'\\r")
    session.wait_text("automator-text-ok")
    session.send("printf 'auto%s\\\\n' 'mator-key-ok'")
    session.key("Enter")
    session.wait_text("automator-key-ok")
    screen = session.query(
        "get-screen", f"--surface={session.surface}", "--format=json"
    )
    assert isinstance(screen["cursor_x"], int) and isinstance(screen["cursor_y"], int)
    print("PASS text and key injection, screen and cursor", flush=True)

    session.run(
        "resize-surface", f"--surface={session.surface}", "--rows=30", "--cols=100"
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        surface = session.surfaces()[0]
        if (surface["rows"], surface["cols"]) == (30, 100):
            break
        time.sleep(0.05)
    else:
        raise AssertionError(f"Resize did not produce 100x30: {surface}")

    # A real alternate-screen program validates rendered TUI state and input.
    tui = session.directory / "tui.py"
    tui.write_text(
        "import os, tty, termios\n"
        "saved=termios.tcgetattr(0)\n"
        "try:\n"
        " tty.setraw(0)\n"
        " os.write(1,b'\\x1b[?1049h\\x1b[2J\\x1b[H\\x1b[35mTUI READY\\x1b[0m')\n"
        " while True:\n"
        "  data=os.read(0,1)\n"
        "  if data==b'q': break\n"
        "  os.write(1,b'\\r\\nKEY:'+data+b' HEX:'+data.hex().encode())\n"
        "finally:\n"
        " os.write(1,b'\\x1b[?1049l')\n"
        " termios.tcsetattr(0,termios.TCSANOW,saved)\n"
    )
    session.send(f"{sys.executable} {tui}\\r")
    session.wait_text("TUI READY")
    session.key("KeyA")
    session.wait_text("KEY:a")
    session.key("KeyB", "--action=release")
    session.key("KeyA", "--mods=shift")
    session.wait_text("KEY:A HEX:41")
    session.key("Digit1", "--mods=shift")
    session.wait_text("KEY:! HEX:21")
    session.key("KeyC", "--mods=ctrl")
    content = session.wait_text("HEX:03")
    assert "KEY:b" not in content, "release event unexpectedly produced text"
    session.run("send-mouse", f"--surface={session.surface}", "--x=25", "--y=25")
    session.run("send-scroll", f"--surface={session.surface}", "--y=1")
    image = session.directory / "screen.png"
    session.run(
        "screenshot-surface", f"--surface={session.surface}", f"--output={image}"
    )
    png = image.read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", png[16:24])
    assert width > 100 and height > 100
    session.key("KeyQ")
    session.send("printf 'auto%s\\\\n' 'mator-tui-exited'\\r")
    session.wait_text("automator-tui-exited")
    print(
        f"PASS resize, alternate screen TUI, mouse/scroll, PNG {width}x{height}",
        flush=True,
    )

    # Start all callers together so the server actually sees overlapping IPC.
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(session.surfaces) for _ in range(64)]
        for future in futures:
            assert future.result()[0]["id"] == session.surface
    print("PASS 64 requests from 16 concurrent CLI callers", flush=True)

    session.run("new-tab", "-e", "bash", "--noprofile", "--norc")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if len(session.surfaces()) == 2:
            break
        time.sleep(0.05)
    else:
        raise AssertionError("new-tab failed to add a surface")
    session.run("focus-surface", f"--surface={session.surface}")
    invalid = session.run("get-screen", "--surface=invalid", success=False)
    assert invalid.returncode != 0
    print("PASS new tab, focus, missing surface errors", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--artifacts-dir", type=Path)
    args = parser.parse_args()
    assert os.environ.get("DISPLAY"), "Run inside xvfb-run with dbus-run-session"
    with tempfile.TemporaryDirectory(prefix="automator-live-") as directory:
        root = Path(directory)
        binary = args.binary.resolve()
        session = Session(binary, root / "interactive")
        try:
            test_startup(binary, root)
            test_session(session)
        finally:
            session.cleanup()
            image = session.directory / "screen.png"
            if args.artifacts_dir and image.exists():
                args.artifacts_dir.mkdir(parents=True, exist_ok=True)
                (args.artifacts_dir / "screen.png").write_bytes(image.read_bytes())
            if args.artifacts_dir:
                for log in root.rglob("startup-*.log"):
                    destination = args.artifacts_dir / log.relative_to(root)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(log.read_bytes())


if __name__ == "__main__":
    main()
