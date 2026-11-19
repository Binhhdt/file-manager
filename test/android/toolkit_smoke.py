"""Exercise the signed APK with actual archives and PDF files on an emulator."""
import binascii
import hashlib
import io
import os
from pathlib import Path
import re
import shutil
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


def bounds(item):
    xy = list(map(int, re.findall(r"\d+", item.get("bounds", ""))))
    if len(xy) == 4 and xy[2] > xy[0] and xy[3] > xy[1]:
        return xy
    return None


def node(label, *, exact=False, clickable=False):
    for item in hierarchy():
        text = (item.get("text", "") + " " + item.get("content-desc", "")).strip()
        if ((text == label if exact else label in text) and item.get("package") == PACKAGE
                and (not clickable or item.get("clickable") == "true")
                and not item.get("class", "").endswith("EditText") and (xy := bounds(item))):
            return xy
    return None


def tap(label, *, exact=False, clickable=False, hold=False):
    x1, y1, x2, y2 = wait(label, lambda: node(label, exact=exact, clickable=clickable), seconds=45)
    x, y = str((x1 + x2) // 2), str((y1 + y2) // 2)
    if hold:
        adb("shell", "input", "swipe", x, y, x, y, "850")
    else:
        adb("shell", "input", "tap", x, y)
    print(f"Tapped {label}", flush=True)


def open_sample(filename, *, hold=False):
    adb("shell", "am", "force-stop", PACKAGE)
    adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity")
    tap("Tìm kiếm")
    adb("shell", "input", "text", filename)
    key("KEYCODE_ENTER")
    tap(filename, hold=hold)


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
    (folder / "fmkit-plain.7z").write_bytes(fetch(COMPRESS + "bla.7z"))
    (folder / "fmkit-seven.7z").write_bytes(fetch(COMPRESS + "bla.encrypted.7z"))
    make_pdf(folder / "fmkit-document.pdf")
    shutil.copyfile(Path(__file__).with_name("fixtures") / "encrypted-two-pages.pdf",
                    folder / "fmkit-locked.pdf")
    (folder / "fmkit-vault.txt").write_text("Verified private preview", encoding="utf-8")
    digest = hashlib.sha256()
    with zipfile.ZipFile(folder / "fmkit-large.zip", "w") as archive:
        with archive.open("large.bin", "w") as member:
            for index in range(24):
                block = hashlib.shake_128(index.to_bytes(2, "big")).digest(1024 * 1024)
                member.write(block)
                digest.update(block)
    return digest.hexdigest()


def enter_password_field(index, password):
    def field():
        fields = [xy for item in hierarchy() if item.get("package") == PACKAGE
                  and item.get("class", "").endswith("EditText") and (xy := bounds(item))]
        return fields[index] if len(fields) > index else None

    x1, y1, x2, y2 = wait("vault password field", field)
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
    adb("shell", "input", "text", password)


def password(value):
    wait("password field", lambda: node("Mật khẩu tập tin nén"))
    adb("shell", "input", "text", value)
    key("KEYCODE_ENTER")


def has_file(path, text=None):
    if text is None:
        value = adb("shell", "stat", "-c", "%s", path, okay=False).strip()
        return value.isdecimal() and int(value) > 0
    return text in adb("shell", "cat", path, okay=False)


def extract(filename, member, content=None, supplied=None, inspect_password=False,
            select=False, legacy_checksum=False):
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
    def outcome():
        if has_file(target, content):
            return "extracted"
        if legacy_checksum and node("Không xác minh được nội dung giải nén"):
            return "checksum"
        return None

    if wait(target, outcome, seconds=45) == "checksum":
        assert not has_file(target)
        print("UNVERIFIED API 24 cannot verify this encrypted 7Z fixture; no output was published", flush=True)
        return
    if select:
        assert not has_file(f"{SAMPLES}/{filename.rsplit('.', 1)[0]}/skip.txt")
    print(f"PASS extracted {filename}", flush=True)


def exercise_vault():
    open_sample("fmkit-vault.txt", hold=True)
    tap("Show menu")
    tap("Sao chép vào thư mục riêng tư")
    tap("Tạo thư mục riêng tư", exact=True, clickable=True)
    wait("vault password creation", lambda: node("Tạo mật khẩu riêng tư"))
    enter_password_field(0, "SmokeVaultPassword123")
    enter_password_field(1, "SmokeVaultPassword123")
    tap("Tạo", exact=True, clickable=True)
    tap("Nhập 1 bản sao", exact=True, clickable=True)
    tap("Nhập bản sao", exact=True, clickable=True)
    tap("fmkit-vault.txt")
    wait("private preview", lambda: node("Verified private preview", exact=True))
    assert adb("shell", "cat", f"{SAMPLES}/fmkit-vault.txt") == "Verified private preview"
    key("KEYCODE_HOME")
    adb("shell", "am", "start", "-W", "-a", "android.settings.SETTINGS")
    wait("Settings in the foreground", lambda: any(
        item.get("package") == "com.android.settings" for item in hierarchy()
    ))
    adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity")
    wait("vault locked on return", lambda: node("Mở khóa", exact=True, clickable=True))
    assert not node("Verified private preview", exact=True)
    tap("Mở khóa", exact=True, clickable=True)
    wait("vault unlock dialog", lambda: node("Mở khóa thư mục"))
    enter_password_field(0, "SmokeVaultPassword123")
    tap("Mở khóa", exact=True, clickable=True)
    tap("fmkit-vault.txt")
    wait("private preview after unlock", lambda: node("Verified private preview", exact=True))
    print("PASS vault roundtrip, private preview, lock on backgrounding and unlock with Android Keystore", flush=True)


def main():
    api = int(adb("shell", "getprop", "ro.build.version.sdk").strip())
    print(f"Testing toolkit on Android Emulator API {api}", flush=True)
    adb("install", "-r", "-g", os.environ["FM_SMOKE_APK"])
    if api >= 30:
        adb("shell", "appops", "set", "--uid", PACKAGE, "MANAGE_EXTERNAL_STORAGE", "allow")
    adb("shell", "mkdir", "-p", SAMPLES)
    with tempfile.TemporaryDirectory(prefix="fm-toolkit-smoke-") as path:
        folder = Path(path)
        digest = fixtures(folder)
        for item in folder.iterdir():
            adb("push", str(item), f"{SAMPLES}/{item.name}")
    for setting in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
        adb("shell", "settings", "put", "global", setting, "0")
    adb("shell", "wm", "size", "720x1600")
    adb("shell", "wm", "density", "240")
    key("KEYCODE_WAKEUP")
    key("KEYCODE_MENU")

    exercise_vault()
    extract("fmkit-zip.zip", "nested/keep.txt", "zip fixture", select=True)
    extract("fmkit-tar.tgz", "target.txt", "tar fixture")
    extract("fmkit-rar4.rar", "testdir/test.txt", "test text file")
    extract("fmkit-rar5.rar", "helloworld.txt", "hello libarchive")
    extract("fmkit-aes.zip", "README", supplied="password")
    extract("fmkit-plain.7z", "test2.xml")
    extract("fmkit-seven.7z", "test2.xml", supplied="foo", inspect_password=True,
            legacy_checksum=api <= 24)
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

    open_sample("fmkit-locked.pdf")
    wait("PDF password prompt", lambda: node("Mật khẩu PDF"))
    adb("shell", "input", "text", "bad-password")
    tap("Mở")
    # The first dialog closes before the reader opens another for a new attempt.
    time.sleep(1)
    wait("PDF password prompt after a wrong password", lambda: node("Mật khẩu PDF"))
    adb("shell", "input", "text", "test-password")
    tap("Mở")
    wait("encrypted PDF first page", lambda: node("1 / 2"))
    print("PASS PDF password prompt, wrong-password retry and opening", flush=True)

    extract("fmkit-large.zip", "large.bin")
    with tempfile.TemporaryDirectory(prefix="fm-toolkit-extracted-") as extracted:
        output = Path(extracted) / "large.bin"
        adb("pull", f"{SAMPLES}/fmkit-large/large.bin", str(output))
        with output.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    assert digest == checksum
    print("PASS SHA-256 equality of 24 MiB archived fixture", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        adb("shell", "uiautomator", "dump", "/data/local/tmp/fm-toolkit-ui.xml", okay=False)
        print(adb("exec-out", "cat", "/data/local/tmp/fm-toolkit-ui.xml", okay=False), flush=True)
        print(adb("logcat", "-d", "-s", "flutter", "AndroidRuntime", okay=False), flush=True)
        print(adb("logcat", "-d", "-t", "220", okay=False), flush=True)
        raise
