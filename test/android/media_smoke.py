"""Drive the signed APK on a disposable Android emulator using real media files."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

PACKAGE = "com.fmdemo.file_manager"
ACTIVITY = f"{PACKAGE}/.MainActivity"


def run(*args, check=True, timeout=25):
    return subprocess.run(args, check=check, text=True, encoding="utf-8",
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)


def adb(*args, check=True):
    return run("adb", *args, check=check).stdout


def wait(label, predicate, seconds=35):
    end = time.monotonic() + seconds
    last = None
    while time.monotonic() < end:
        try:
            last = predicate()
            if last:
                return last
        except (subprocess.SubprocessError, ET.ParseError):
            pass
        time.sleep(0.65)
    raise AssertionError(f"Timed out waiting for {label}. Last value: {last}")


def foreground():
    adb("shell", "am", "start", "-n", ACTIVITY)


def key(name):
    adb("shell", "input", "keyevent", name)


def tap(label):
    def bounds():
        result = adb("shell", "uiautomator", "dump", "--compressed", "/sdcard/fm-ui.xml",
                     check=False)
        if "UI hierchary dumped" not in result and "UI hierarchy dumped" not in result:
            return None
        root = ET.fromstring(adb("exec-out", "cat", "/sdcard/fm-ui.xml"))
        for node in root.iter("node"):
            text = " ".join((node.get("text", ""), node.get("content-desc", "")))
            if label not in text:
                continue
            points = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
            if len(points) == 4 and points[0] < points[2] and points[1] < points[3]:
                return points
        return None

    x1, y1, x2, y2 = wait(f"UI {label}", bounds, seconds=45)
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def session(track=None, playing=True):
    text = adb("shell", "dumpsys", "media_session")
    for part in re.split(r"(?=\n\s*[^\n]*package=)", text):
        if f"package={PACKAGE}" not in part:
            continue
        state = re.search(r"state\s*=\s*PlaybackState\s*\{state=(\d+),\s*position=(-?\d+)", part)
        if not state or (track and track.lower() not in part.lower()):
            continue
        if playing is not None and (state[1] == "3") != playing:
            continue
        return max(0, int(state[2])) + 1
    return False


def command(action):
    adb("shell", "cmd", "media_session", "dispatch", action)


def fixtures(folder):
    for title, length in (("00-fm-short", 5), ("01-fm-second", 100), ("02-fm-third", 100)):
        run("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
            "sine=frequency=480:sample_rate=22050", "-t", str(length), "-c:a",
            "libmp3lame", "-b:a", "48k", "-metadata", f"title={title}",
            "-metadata", "artist=FM Smoke", str(folder / (title + ".mp3")))
    run("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
        "testsrc2=size=160x90:rate=10", "-f", "lavfi", "-i",
        "sine=frequency=520:sample_rate=22050", "-t", "100", "-c:v", "libx264",
        "-threads", "2", "-preset", "ultrafast", "-c:a", "aac", "-b:a", "48k",
        "-metadata", "title=03-fm-video", str(folder / "03-fm-video.mp4"))


with tempfile.TemporaryDirectory(prefix="fm-media-smoke-") as temp:
    version = int(adb("shell", "getprop", "ro.build.version.sdk").strip())
    print(f"Running actual APK on Android emulator API {version}", flush=True)
    try:
        folder = Path(temp)
        fixtures(folder)
        adb("install", "-r", "-g", os.environ["FM_SMOKE_APK"])
        if version >= 30:
            adb("shell", "appops", "set", "--uid", PACKAGE, "MANAGE_EXTERNAL_STORAGE", "allow")
        adb("shell", "mkdir", "-p", "/sdcard/Download")
        for file in folder.iterdir():
            adb("push", str(file), f"/sdcard/Download/{file.name}")
        for setting in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
            adb("shell", "settings", "put", "global", setting, "0")
        key("KEYCODE_WAKEUP")
        key("KEYCODE_MENU")
        foreground()
        tap("Download")
        tap("00-fm-short.mp3")
        wait("auto advance to second track", lambda: session("01-fm-second"))
        print("PASS audio decoding and auto advance", flush=True)

        key("KEYCODE_HOME")
        wait("mediaPlayback foreground service", lambda: "isForeground=true" in
             adb("shell", "dumpsys", "activity", "services", PACKAGE))
        wait("playback after Home", lambda: session("01-fm-second"))
        adb("shell", "am", "start", "-a", "android.settings.SETTINGS")
        wait("playback in another app", lambda: session("01-fm-second"))
        key("KEYCODE_SLEEP")
        wait("screen off", lambda: re.search(r"mWakefulness=(Asleep|Dozing)|Display Power: state=OFF",
             adb("shell", "dumpsys", "power")))
        wait("playback with screen off", lambda: session("01-fm-second"))
        print("PASS Home, another app, screen off and foreground service", flush=True)

        command("pause")
        wait("system media pause", lambda: session("01-fm-second", playing=False))
        command("play")
        wait("system media play", lambda: session("01-fm-second"))
        command("next")
        wait("system media next", lambda: session("02-fm-third"))
        command("previous")
        wait("system media previous", lambda: session("01-fm-second"))
        print("PASS Android media session play/pause/next/previous commands", flush=True)

        key("KEYCODE_WAKEUP")
        key("KEYCODE_MENU")
        foreground()
        key("KEYCODE_BACK")
        wait("music while file browser is visible", lambda: session("01-fm-second"))
        tap("03-fm-video.mp4")
        wait("video is playing", lambda: session("03-fm-video"))
        command("pause")
        wait("video paused for UI automation", lambda: session("03-fm-video", playing=False))
        tap("Tuỳ chọn phát")
        tap("Phát âm thanh nền")
        command("play")
        key("KEYCODE_BACK")
        before = wait("video audio after closing the page", lambda: session("03-fm-video"))
        time.sleep(5)
        after = wait("video audio after elapsed time", lambda: session("03-fm-video"))
        tap("Mở trình phát")
        reopened = wait("same video after reopening the page", lambda: session("03-fm-video"))
        assert after >= before and reopened >= after - 2000
        print(f"PASS video background and same session on reopen ({before}, {after}, {reopened})", flush=True)

        if version >= 26 and "android.software.picture_in_picture" in adb("shell", "pm", "list", "features"):
            command("pause")
            wait("video paused before PiP", lambda: session("03-fm-video", playing=False))
            tap("Cửa sổ nổi (PiP)")
            wait("pinned window", lambda: re.search(
                r"mode=pinned|windowingMode=pinned|mWindowingMode=2",
                adb("shell", "dumpsys", "activity", "activities"),
            ))
            command("play")
            wait("playback in the pinned window", lambda: session("03-fm-video"))
            print("PASS picture-in-picture window", flush=True)

        command("stop")
        wait("foreground media service stopped", lambda: "isForeground=true" not in
             adb("shell", "dumpsys", "activity", "services", PACKAGE))
        print("PASS explicit stop releases foreground playback", flush=True)
    except Exception:
        print(adb("shell", "dumpsys", "media_session", check=False), flush=True)
        print(adb("shell", "dumpsys", "activity", "services", PACKAGE, check=False), flush=True)
        print(adb("logcat", "-d", "-t", "500", check=False), flush=True)
        raise
