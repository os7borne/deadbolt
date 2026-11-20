#!/bin/sh
# Copies the Chrome extension into the Safari extension's resources (flat: Xcode flattens resources) with a
# Safari manifest. Run after changing chrome/*, then rebuild the Mac app.
set -e
cd "$(dirname "$0")/.."
OUT=Apps/SafariExtension/Resources
mkdir -p "$OUT"
cp chrome/background.js chrome/content.js chrome/fieldmap.js chrome/popup.html chrome/popup.css chrome/popup.js "$OUT/"
for s in 16 32 48 128; do cp "chrome/icons/icon-$s.png" "$OUT/icon-$s.png"; done
sed -i '' 's#icons/icon-32.png#icon-32.png#g' "$OUT/popup.html"
python3 - "$OUT/manifest.json" <<'PY'
import json, sys
m = json.load(open("chrome/manifest.json"))
m.pop("key", None)                                   # Chrome-only (fixed extension id)
m["content_scripts"] = [c for c in m["content_scripts"] if "inject.js" not in c["js"]]   # Safari passkeys: Mac AutoFill provider
m["permissions"] = [p for p in m["permissions"] if p != "favicon"]   # Chrome-only
icons = {k: f"icon-{k}.png" for k in ["16", "32", "48", "128"]}
m["icons"] = icons
m["action"]["default_icon"] = {"16": "icon-16.png", "32": "icon-32.png"}
m["description"] = "Save and fill passwords from Deadbolt for Mac. Nothing is stored in Safari."
json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
echo "Safari extension resources updated in $OUT"
