"""Exclude private vault data from Android backup and device transfer."""
from pathlib import Path
import xml.etree.ElementTree as ET

android = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", android)
manifest = Path("android/app/src/main/AndroidManifest.xml")
tree = ET.parse(manifest)
app = tree.getroot().find("application")
app.set(f"{{{android}}}fullBackupContent", "@xml/vault_backup_rules")
app.set(f"{{{android}}}dataExtractionRules", "@xml/vault_extraction_rules")
tree.write(manifest, encoding="utf-8", xml_declaration=True)

directory = Path("android/app/src/main/res/xml")
directory.mkdir(parents=True, exist_ok=True)

def exclude(parent):
    ET.SubElement(parent, "exclude", {"domain": "file", "path": "fm-vault/"})

legacy = ET.Element("full-backup-content")
exclude(legacy)
ET.ElementTree(legacy).write(directory / "vault_backup_rules.xml", encoding="utf-8")

modern = ET.Element("data-extraction-rules")
exclude(ET.SubElement(modern, "cloud-backup"))
exclude(ET.SubElement(modern, "device-transfer"))
ET.ElementTree(modern).write(directory / "vault_extraction_rules.xml", encoding="utf-8")
