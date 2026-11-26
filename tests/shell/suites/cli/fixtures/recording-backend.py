import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root = Path(sys.argv[1])
script = root / "bin/vb-core-recording"
with tempfile.TemporaryDirectory(prefix="vbr-") as tmp:
    base = Path(tmp)
    fake = base / "bin"
    fake.mkdir()
    (base / "run").mkdir()
    def tool(name, body):
        path = fake / name
        path.write_text(body)
        path.chmod(0o700)
    tool("hyprctl", '#!/bin/bash\nsleep 0.15\nprintf "%s\\n" "$TEST_MONITORS"\n')
    tool("vb-shell", """#!/bin/bash
[[ "$*" == "--json tools picker pick logical" ]] || exit 2
[[ -n "$TEST_REGION" ]] || exit 1
printf '%s\n' "$TEST_REGION"
""")
    tool("wl-copy", '#!/bin/bash\ncat >"$TEST_BASE/copied"\n')
    tool("notify-send", '#!/bin/bash\nprintf "%s\\n" "$*" >>"$TEST_BASE/notify"\n')
    tool("python3", '#!/bin/bash\ntouch "$TEST_BASE/python-invoked"\nexit 99\n')
    tool("gpu-screen-recorder", f"#!{sys.executable}\n" + """
import json, os, socket, sys, time
from pathlib import Path
args = sys.argv
get = lambda flag: args[args.index(flag)+1]
mode = os.environ["TEST_MODE"]
out = Path(get("-o"))
with open(Path(os.environ["TEST_BASE"]) / "attempts", "a") as attempts:
    attempts.write(get("-encoder") + "\\n")
if os.environ.get("TEST_REGION"):
    assert get("-w") == "region"
    assert get("-region") == "640x480+-12+34"
if mode == "fail" or (mode == "fallback" and get("-encoder") == "gpu"):
    sys.exit(2)
server = socket.socket(socket.AF_UNIX)
server.bind(get("-ipc"))
server.listen()
if mode == "crash":
    server.settimeout(1)
    while True:
        try:
            conn, _ = server.accept()
            conn.close()
        except TimeoutError:
            sys.exit(23)
while True:
    conn, _ = server.accept()
    with conn:
        request = conn.makefile("rb").readline()
        if not request:
            continue
        req = json.loads(request)
        if req["name"] == "stop":
            if mode == "ignore":
                time.sleep(8)
                continue
            time.sleep(0.1)
            out.write_text("finalized")
            reply = {"id": req["id"], "result":"ok","data":str(out)}
            conn.sendall((json.dumps(reply)+"\\n").encode())
            break
        conn.sendall((json.dumps({"id":req["id"],"result":"ok"})+"\\n").encode())
""")
    env = dict(os.environ, PATH=f"{fake}:{root}/bin:{os.environ['PATH']}",
               CHASSIS_TYPE="desktop", TEST_BASE=str(base),
               XDG_VIDEOS_DIR=str(base / "space % # ? é"),
               VIBRANIUM_RUNTIME=str(base / "run"), VIBRANIUM_CACHE=str(base / "cache"),
               TEST_MODE="normal", TEST_MONITORS='[{"name":"DP-1","focused":true}]')
    marker = base / "run/recording-ongoing"
    results = base / "notify"
    clipboard = base / "copied"
    attempts = base / "attempts"
    process_groups = []

    def spawn(*args, **overrides):
        proc = subprocess.Popen(
            [script, *args], env=env | overrides, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        process_groups.append(proc.pid)
        return proc

    def run(*args, **overrides):
        with spawn(*args, **overrides) as proc:
            try:
                stdout, stderr = proc.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                raise
            return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
    def start(*args, **overrides):
        result = run(*args, **overrides)
        assert result.returncode == 0, result
        assert marker.exists()
    def until(predicate):
        deadline = time.monotonic() + 4
        while not predicate():
            assert time.monotonic() < deadline
            time.sleep(0.025)

    try:
        # An unrelated live PID in old state is ignored rather than signalled.
        marker.write_text(f"{os.getpid()}\n")
        assert run("--status").returncode == 1
        assert not marker.exists()
        assert run(TEST_MONITORS="[]").returncode == 1
        assert not attempts.exists()

        first = spawn()
        until(lambda: attempts.exists())
        duplicate = run()
        assert duplicate.returncode == 1, duplicate
        _, error = first.communicate(timeout=10)
        assert first.returncode == 0, (error, (base / "cache/vb-core-recording.log").read_text())
        assert run("--status").returncode == 0
        assert attempts.read_text().splitlines() == ["gpu"]
        stop = run("--stop")
        assert stop.returncode == 0, stop
        until(lambda: clipboard.exists() and not marker.exists())
        assert b"space%20%25%20%23%20%3F%20%C3%A9" in clipboard.read_bytes()
        until(lambda: "Recording saved" in results.read_text())
        files = list(Path(env["XDG_VIDEOS_DIR"]).glob("Screencasts/recording-*"))
        assert len(files) == 1 and files[0].read_text() == "finalized", files

        start(TEST_MODE="fallback")
        assert attempts.read_text().splitlines()[-2:] == ["gpu", "cpu"]
        assert run("--stop").returncode == 0
        until(lambda: "Encoded on the CPU" in results.read_text())
        assert len(list(Path(env["XDG_VIDEOS_DIR"]).glob("Screencasts/recording-*"))) == 2

        previous_attempts = attempts.read_text()
        assert run("--region", TEST_REGION="").returncode == 1
        assert run("--region", TEST_REGION='{"x":0,"y":0,"w":0,"h":480}').returncode == 1
        assert attempts.read_text() == previous_attempts
        assert not marker.exists()
        start("--region", TEST_MODE="fallback", TEST_MONITORS="[]",
              TEST_REGION='{"x":-12,"y":34,"w":640,"h":480}')
        assert attempts.read_text().splitlines()[-2:] == ["gpu", "cpu"]
        assert run("--stop").returncode == 0
        until(lambda: not marker.exists())

        assert run(TEST_MODE="fail").returncode == 1
        assert not marker.exists()

        start(TEST_MODE="ignore")
        started = time.monotonic()
        assert run("--stop").returncode == 1
        assert time.monotonic() - started < 7.5
        assert marker.exists()
        pid = int(marker.read_text().splitlines()[0])
        os.kill(pid, signal.SIGKILL)
        until(lambda: not marker.exists())

        start(TEST_MODE="crash")
        until(lambda: not marker.exists())
        until(lambda: "status 23" in results.read_text())

        # A PID-only marker can only stop the expected executable and output.
        legacy_encoder = fake / "gpu-screen-recorder"
        legacy_encoder.unlink()
        legacy_encoder.symlink_to("/bin/bash")
        legacy_output = base / "legacy recording.mp4"
        legacy_command = (
            'trap \'printf finalized > "$2"; exit\' INT; '
            'echo ready; while :; do sleep 0.05; done'
        )
        legacy = subprocess.Popen(
            ["env", "--default-signal=INT", legacy_encoder, "-c", legacy_command,
             "--", "-o", str(legacy_output)],
            stdout=subprocess.PIPE, text=True, start_new_session=True,
        )
        process_groups.append(legacy.pid)
        assert legacy.stdout.readline() == "ready\n"
        marker.write_text(f"{legacy.pid}\n")
        legacy_path = base / "run/recording-out-file"
        legacy_path.write_text(f"{base / 'wrong.mp4'}\n")
        assert run("--stop").returncode == 1 and legacy.poll() is None
        legacy_path.write_text(f"{legacy_output}\n")
        stop = run("--stop")
        assert stop.returncode == 0, stop
        assert legacy.wait(timeout=2) == 0
        assert legacy_output.read_text() == "finalized" and not marker.exists()
        assert not (base / "python-invoked").exists()
        print("Pass: stale PID, monitor failure, concurrent starts, save, URI, fallback, both fail, refused stop, recorder death, legacy stop, no Python calls.")

    finally:
        for group in process_groups:
            try:
                os.killpg(group, signal.SIGTERM)
            except ProcessLookupError:
                pass
