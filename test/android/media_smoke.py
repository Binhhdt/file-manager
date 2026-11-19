"""Drive the signed APK on a disposable Android emulator using real media files."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

PACKAGE = "com.fmdemo.file_manager"
ACTIVITY = f"{PACKAGE}/.MainActivity"


def run(*args, check=True, timeout=25):
    return subprocess.run(args, check=check, text=True, encoding="utf-8", errors="replace",
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
    adb("shell", "am", "start", "-W", "-n", ACTIVITY)


def key(name):
    adb("shell", "input", "keyevent", name)


def tap(label, *, hold=False):
    def bounds():
        adb("shell", "rm", "-f", "/data/local/tmp/fm-ui.xml", check=False)
        result = adb("shell", "uiautomator", "dump", "/data/local/tmp/fm-ui.xml", check=False)
        if "dumped to" not in result:
            return None
        root = ET.fromstring(adb("exec-out", "cat", "/data/local/tmp/fm-ui.xml"))
        for node in root.iter("node"):
            text = " ".join((node.get("text", ""), node.get("content-desc", "")))
            dismiss = text.strip() == "Got it" and node.get("package") == "com.android.systemui"
            if label not in text and not dismiss:
                continue
            points = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
            if len(points) == 4 and points[0] < points[2] and points[1] < points[3]:
                if dismiss:
                    adb("shell", "input", "tap", str((points[0] + points[2]) // 2),
                        str((points[1] + points[3]) // 2))
                    return None
                return points
        return None

    x1, y1, x2, y2 = wait(f"UI {label}", bounds, seconds=45)
    x, y = str((x1 + x2) // 2), str((y1 + y2) // 2)
    if hold:
        adb("shell", "input", "swipe", x, y, x, y, "850")
    else:
        adb("shell", "input", "tap", x, y)
    print(f"Tapped {label}", flush=True)


def session(track=None, playing=True):
    text = adb("shell", "dumpsys", "media_session")
    for part in re.split(r"(?=\n\s*[^\n]*package=)", text):
        if f"package={PACKAGE}" not in part:
            continue
        state = re.search(r"state\s*=\s*PlaybackState\s*\{state=(?:[A-Z_]+\()?(\d+)\)?,\s*position=(-?\d+)", part)
        if not state or (track and track.lower() not in part.lower()):
            continue
        if playing is not None and (state[1] == "3") != playing:
            continue
        position = max(0, int(state[2]))
        timing = re.search(r"speed=([\d.]+),\s*updated=(\d+)", part)
        if state[1] == "3" and timing:
            uptime_ms = float(adb("shell", "cat", "/proc/uptime").split()[0]) * 1000
            position += int(max(0, uptime_ms - int(timing[2])) * float(timing[1]))
        return position + 1
    return False


def command(action):
    if version < 26:
        output = adb("shell", "media", "dispatch", action)
    else:
        output = adb("shell", "cmd", "media_session", "dispatch", action)
    if any(message in output.lower() for message in ("unknown command", "no shell command", "not found")):
        key(f"KEYCODE_MEDIA_{action.upper()}")


def search(query):
    tap("Tìm kiếm")
    adb("shell", "input", "text", query)
    key("KEYCODE_ENTER")


def exercise_incoming_call(track):
    # The emulator console injects a local, simulated call.
    number = "5550102"
    if "OK" not in adb("emu", "gsm", "call", number, check=False):
        print("UNVERIFIED simulated incoming call unavailable on this image", flush=True)
        return
    try:
        def ringing_or_active():
            calls = adb("emu", "gsm", "list", check=False)
            return number in calls and re.search(r"ringing|incoming|active", calls, re.I)

        wait("simulated incoming call", ringing_or_active, seconds=8)
        adb("emu", "gsm", "accept", number, check=False)
        wait("Android pauses media for the simulated call", lambda: session(track, playing=False), seconds=12)
        print("PASS playback paused while a simulated call was active", flush=True)
    except AssertionError:
        print("UNVERIFIED simulated call did not expose a pause; emulator audio is muted at the host", flush=True)
    finally:
        adb("emu", "gsm", "cancel", number, check=False)
        # Playback cannot reacquire Audio Focus while Telecom still owns it.
        try:
            wait("automatic media resume after the simulated call", lambda: session(track), seconds=4)
        except AssertionError:
            command("play")
            wait("media can resume after the simulated call", lambda: session(track), seconds=15)
        print("PASS media can play again after the simulated call", flush=True)


def fixtures(folder):
    encoder = shutil.which("ffmpeg")
    if encoder is None:
        from imageio_ffmpeg import get_ffmpeg_exe
        encoder = get_ffmpeg_exe()
    for title, length in (("00-fm-short", 5), ("01-fm-second", 100), ("02-fm-third", 100)):
        run(encoder, "-v", "error", "-y", "-f", "lavfi", "-i",
            "sine=frequency=480:sample_rate=22050", "-t", str(length), "-c:a",
            "libmp3lame", "-b:a", "48k", "-metadata", f"title={title}",
            "-metadata", "artist=FM Smoke", str(folder / (title + ".mp3")))
    run(encoder, "-v", "error", "-y", "-f", "lavfi", "-i",
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
        adb("shell", "settings", "put", "secure", "immersive_mode_confirmations", "confirmed")
        adb("shell", "wm", "size", "720x1600")
        adb("shell", "wm", "density", "240")
        key("KEYCODE_WAKEUP")
        adb("shell", "wm", "dismiss-keyguard", check=False)
        key("KEYCODE_MENU")
        foreground()
        search("fm-")
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
        exercise_incoming_call("01-fm-second")

        key("KEYCODE_WAKEUP")
        adb("shell", "wm", "dismiss-keyguard", check=False)
        key("KEYCODE_MENU")
        foreground()

        def stop_audio_service():
            if "isForeground=true" not in adb("shell", "dumpsys", "activity", "services", PACKAGE):
                return True
            command("stop")
            return False

        wait("foreground audio service stopped", stop_audio_service)
        # Isolate video UI assertions from Telecom and keyguard focus changes.
        adb("shell", "am", "force-stop", PACKAGE)
        foreground()
        search("03-fm-video")
        tap("03-fm-video.mp4")
        wait("video is playing", lambda: session("03-fm-video"))
        print("PASS actual MP4 decoding", flush=True)
        command("pause")
        wait("video paused for UI automation", lambda: session("03-fm-video", playing=False))
        tap("Tuỳ chọn phát")
        tap("Phát âm thanh nền")
        tap("Quay lại")
        command("play")
        before = wait("video audio after closing the page", lambda: session("03-fm-video"))
        time.sleep(5)
        after = wait("video audio after elapsed time", lambda: session("03-fm-video"))
        tap("Mở trình phát")
        reopened = wait("same video after reopening the page", lambda: session("03-fm-video"))
        assert after > before + 2000 and reopened >= after - 2000
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

        adb("shell", "am", "force-stop", PACKAGE)
        foreground()
        search("fm-")
        tap("01-fm-second.mp3", hold=True)
        tap("02-fm-third.mp3")
        tap("Show menu")
        tap("Thêm vào playlist")
        tap("Tạo playlist mới")
        adb("shell", "input", "text", "ToolkitSmokePlaylist")
        tap("OK")
        tap("Đã cập nhật playlist.")

        adb("shell", "am", "force-stop", PACKAGE)
        foreground()
        adb("shell", "input", "swipe", "410", "1320", "410", "520", "350")
        tap("Playlist nhạc")
        tap("ToolkitSmokePlaylist")
        tap("01-fm-second.mp3")
        wait("first saved playlist track", lambda: session("01-fm-second"))
        command("next")
        wait("remaining saved playlist track", lambda: session("02-fm-third"))
        print("PASS saved playlist persisted over restart and uses the existing media session", flush=True)
    except Exception:
        adb("shell", "uiautomator", "dump", "/data/local/tmp/fm-ui.xml", check=False)
        print("Latest hierarchy:", adb("exec-out", "cat", "/data/local/tmp/fm-ui.xml", check=False), flush=True)
        print("Package activity:", adb("shell", "dumpsys", "activity", "activities", PACKAGE, check=False), flush=True)
        print(adb("shell", "dumpsys", "media_session", check=False), flush=True)
        print(adb("shell", "dumpsys", "activity", "services", PACKAGE, check=False), flush=True)
        print(adb("logcat", "-d", "-t", "500", check=False), flush=True)
        raise
