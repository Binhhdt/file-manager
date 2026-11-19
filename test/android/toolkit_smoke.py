"""Exercise the signed APK with actual archives and PDF files on an emulator."""
import binascii
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time
from urllib.request import urlopen
import xml.etree.ElementTree as ET
import zipfile

PACKAGE = "com.fmdemo.file_manager"
SAMPLES = "/sdcard/Download/fmkit-cases"
LIBARCHIVE = "https://raw.githubusercontent.com/libarchive/libarchive/v3.8.11/libarchive/test/"
COMPRESS = "https://raw.githubusercontent.com/apache/commons-compress/rel/commons-compress-1.28.0/src/test/resources/"


def adb(*args, okay=True):
    return subprocess.run(
        ["adb", *args], check=okay, timeout=40, text=True, encoding="utf-8",
        errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ).stdout


def wait(label, condition, seconds=35):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        try:
            if result := condition():
                return result
        except (subprocess.SubprocessError, ET.ParseError):
            pass
        time.sleep(0.65)
    raise AssertionError(f"Timed out waiting for {label}")


def key(name):
    adb("shell", "input", "keyevent", name)


def hierarchy():
    result = adb("shell", "uiautomator", "dump", "/data/local/tmp/fm-toolkit-ui.xml", okay=False)
    if "dumped to" not in result:
        return []
    return list(ET.fromstring(adb("exec-out", "cat", "/data/local/tmp/fm-toolkit-ui.xml")).iter("node"))


def node(label):
    for item in hierarchy():
        text = item.get("text", "") + " " + item.get("content-desc", "")
        if (label in text and item.get("package") == PACKAGE
                and not item.get("class", "").endswith("EditText")):
            xy = list(map(int, re.findall(r"\d+", item.get("bounds", ""))))
            if len(xy) == 4 and xy[2] > xy[0] and xy[3] > xy[1]:
                return xy
    return None


def tap(label):
    x1, y1, x2, y2 = wait(label, lambda: node(label), seconds=45)
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
    print(f"Tapped {label}", flush=True)


def open_sample(filename):
    adb("shell", "am", "force-stop", PACKAGE)
    adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity")
    tap("Tìm kiếm")
    adb("shell", "input", "text", filename)
    key("KEYCODE_ENTER")
    tap(filename)


def fetch(url, *, uu=False):
    with urlopen(url, timeout=25) as response:
        raw = response.read(1_000_000)
    if not uu:
        return raw
    lines = raw.splitlines()
    assert lines[0].startswith(b"begin ")
    return b"".join(binascii.a2b_uu(line) for line in lines[1:] if line not in (b"end", b""))


def make_pdf(path):
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 7 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
    ]
    for line in [b"First page", b"Needle on the second page"]:
        stream = b"BT /F1 14 Tf 20 330 Td (" + line + b") Tj ET"
        objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objs, start=1):
        offsets.append(len(pdf))
        pdf.extend(b"%d 0 obj\n" % index + obj + b"\nendobj\n")
    start = len(pdf)
    pdf.extend(b"xref\n0 %d\n0000000000 65535 f \n" % len(offsets))
    for offset in offsets[1:]:
        pdf.extend(b"%010d 00000 n \n" % offset)
    pdf.extend(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(offsets), start))
    path.write_bytes(pdf)


def fixtures(folder):
    with zipfile.ZipFile(folder / "fmkit-zip.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("nested/keep.txt", "zip fixture")
        archive.writestr("skip.txt", "unselected")
    with zipfile.ZipFile(folder / "fmkit-unsafe.zip", "w") as archive:
        archive.writestr("../outside.txt", "rejected")
    with tarfile.open(folder / "fmkit-tar.tgz", "w:gz") as archive:
        data = b"tar fixture"
        info = tarfile.TarInfo("target.txt")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    for dest, fixture in [
        ("fmkit-rar4.rar", "test_read_format_rar_windows.rar.uu"),
        ("fmkit-rar5.rar", "test_read_format_rar5_stored.rar.uu"),
        ("fmkit-aes.zip", "test_read_format_zip_winzip_aes256.zip.uu"),
    ]:
        (folder / dest).write_bytes(fetch(LIBARCHIVE + fixture, uu=True))
    (folder / "fmkit-seven.7z").write_bytes(fetch(COMPRESS + "bla.encrypted.7z"))
    make_pdf(folder / "fmkit-document.pdf")


def password(value):
    wait("password field", lambda: node("Mật khẩu tập tin nén"))
    adb("shell", "input", "text", value)
    key("KEYCODE_ENTER")


def has_file(path, text=None):
    if text is None:
        value = adb("shell", "stat", "-c", "%s", path, okay=False).strip()
        return value.isdecimal() and int(value) > 0
    return text in adb("shell", "cat", path, okay=False)


def extract(filename, member, content=None, supplied=None, inspect_password=False, select=False):
    open_sample(filename)
    if inspect_password:
        password(supplied)
    if select:
        tap("nested")
        tap("keep.txt")
    tap("Giải nén đã chọn" if select else "Giải nén toàn bộ")
    tap("Thư mục chứa tập tin nén")
    tap("Giải nén vào thư mục cùng tên tại đây")
    if supplied and not inspect_password:
        password(supplied)
    target = f"{SAMPLES}/{filename.rsplit('.', 1)[0]}/{member}"
    wait(target, lambda: has_file(target, content), seconds=45)
    if select:
        assert not has_file(f"{SAMPLES}/{filename.rsplit('.', 1)[0]}/skip.txt")
    print(f"PASS extracted {filename}", flush=True)


def main():
    api = int(adb("shell", "getprop", "ro.build.version.sdk").strip())
    print(f"Testing toolkit on Android Emulator API {api}", flush=True)
    adb("install", "-r", "-g", os.environ["FM_SMOKE_APK"])
    if api >= 30:
        adb("shell", "appops", "set", "--uid", PACKAGE, "MANAGE_EXTERNAL_STORAGE", "allow")
    adb("shell", "mkdir", "-p", SAMPLES)
    with tempfile.TemporaryDirectory(prefix="fm-toolkit-smoke-") as path:
        folder = Path(path)
        fixtures(folder)
        for item in folder.iterdir():
            adb("push", str(item), f"{SAMPLES}/{item.name}")
    for setting in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
        adb("shell", "settings", "put", "global", setting, "0")
    adb("shell", "wm", "size", "720x1600")
    adb("shell", "wm", "density", "240")
    key("KEYCODE_WAKEUP")
    key("KEYCODE_MENU")

    extract("fmkit-zip.zip", "nested/keep.txt", "zip fixture", select=True)
    extract("fmkit-tar.tgz", "target.txt", "tar fixture")
    extract("fmkit-rar4.rar", "testdir/test.txt", "test text file")
    extract("fmkit-rar5.rar", "helloworld.txt", "hello libarchive")
    extract("fmkit-aes.zip", "README", supplied="password")
    extract("fmkit-seven.7z", "test2.xml", supplied="foo", inspect_password=True)
    open_sample("fmkit-unsafe.zip")
    wait("reject traversal", lambda: node("đường dẫn không an toàn"))
    assert not has_file(f"{SAMPLES}/outside.txt")
    print("PASS traversal blocked", flush=True)

    open_sample("fmkit-document.pdf")
    wait("first PDF page", lambda: node("1 / 2"))
    tap("Trang sau")
    wait("second PDF page", lambda: node("2 / 2"))
    tap("Tìm trong PDF")
    adb("shell", "input", "text", "Needle")
    key("KEYCODE_ENTER")
    wait("PDF text search", lambda: node("1 kết quả"))
    open_sample("fmkit-document.pdf")
    wait("remembered PDF page", lambda: node("2 / 2"))
    print("PASS PDF rendering, navigation, text search and remembered page", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        adb("shell", "uiautomator", "dump", "/data/local/tmp/fm-toolkit-ui.xml", okay=False)
        print(adb("exec-out", "cat", "/data/local/tmp/fm-toolkit-ui.xml", okay=False), flush=True)
        print(adb("logcat", "-d", "-t", "280", okay=False), flush=True)
        raise
