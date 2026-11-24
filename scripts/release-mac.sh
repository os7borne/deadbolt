#!/usr/bin/env bash
# Ships the downloadable, self-updating Mac build of Deadbolt (not on the Mac App Store; see AGENTS.md "Distribution"):
#   archive → Developer ID export → notarize + staple → Sparkle zip + notes → DMG (signed, notarized) → EdDSA-signed appcast.
# Needs: the Developer ID profiles "Deadbolt Developer ID" / "Deadbolt AutoFill Developer ID" installed, the Developer ID
# Application certificate, the App Store Connect Admin API key (notarization), and the Sparkle signing key in the login
# Keychain under account "deadbolt" (tools: build/sparkle-tools/bin, copied from the Sparkle release).
# Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml first, and add scripts/release-notes/<version>.md
# (bullets; they become the update's release notes).
#
#   scripts/release-mac.sh            build everything under build/direct/ and website/public/updates/ (does NOT publish)
#   scripts/release-mac.sh --deploy   also deploy the website (appcast + zip go live: running copies update within the hour)
#   scripts/release-mac.sh --install  also replace /Applications/Deadbolt.app (previous copy kept in build/backup)
#   scripts/release-mac.sh --no-notarize  TEST ONLY: skip the Apple uploads (the build would be refused by Gatekeeper); cannot be combined with --deploy
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Deadbolt"; SCHEME="DeadboltMac"; PROJECT="Deadbolt.xcodeproj"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_2JGS3623F8.p8"
KEY_ID="2JGS3623F8"; ISSUER="eb6fd3a5-f9b6-4aa6-95b0-c40c496229bf"; TEAM="4CMN2DUGUL"
HOST="https://deadbolt.osborne.vc"
SIGN_ID="Developer ID Application: Osborne Saldanha ($TEAM)"
TOOLS="build/sparkle-tools/bin"

deploy=0; install=0; notarize=1
for a in "$@"; do case "$a" in --deploy) deploy=1 ;; --install) install=1 ;; --no-notarize) notarize=0 ;; *) sed -n '2,16p' "$0"; exit 1 ;; esac; done
[[ $notarize == 0 && $deploy == 1 ]] && { echo "--no-notarize builds must never be deployed"; exit 1; }

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
echo "▶ $APP $version ($build)"
[[ -f "$KEY_PATH" ]] || { echo "Missing App Store Connect key: $KEY_PATH"; exit 1; }
[[ -x "$TOOLS/generate_appcast" ]] || { echo "Missing $TOOLS (copy Sparkle's bin/ there)"; exit 1; }
[[ -f "scripts/release-notes/$version.md" ]] || { echo "Add scripts/release-notes/$version.md (its bullets are the release notes)"; exit 1; }
ids=$(security find-identity -v -p codesigning || true)
[[ "$ids" == *"$SIGN_ID"* ]] || { echo "Developer ID Application certificate not found"; exit 1; }
grep -q '^ *SUPublicEDKey: ' project.yml || { echo "SUPublicEDKey missing in project.yml"; exit 1; }

auth=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
out="build/direct"; rm -rf "$out/$APP.xcarchive" "$out/export" "$out/dmg"; mkdir -p "$out" "$out/updates"

echo "▶ archive"
xcodegen generate >/dev/null
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$out/$APP.xcarchive" -derivedDataPath build/dd-direct "${auth[@]}" -quiet

echo "▶ export (Developer ID, manual signing: Xcode's automatic export can't find these profiles)"
cat > "$out/Export.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
<key>provisioningProfiles</key><dict>
  <key>com.osborne.deadbolt</key><string>Deadbolt Developer ID</string>
  <key>com.osborne.deadbolt.autofill</key><string>Deadbolt AutoFill Developer ID</string>
</dict>
</dict></plist>
PL
xcodebuild -exportArchive -archivePath "$out/$APP.xcarchive" -exportPath "$out/export" -exportOptionsPlist "$out/Export.plist" -quiet
app="$out/export/$APP.app"
[[ -d "$app" ]] || { echo "Export produced no $APP.app"; exit 1; }
flags=$(codesign -dv "$app" 2>&1 || true)   # (not piped into grep -q: with pipefail an early close would fake a failure)
[[ "$flags" == *"(runtime)"* ]] || { echo "Hardened runtime is off; notarization would fail"; exit 1; }
for x in "$app"/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc; do codesign --verify --strict "$x" || { echo "Bad signature: $x"; exit 1; }; done

if [[ $notarize == 1 ]]; then
  echo "▶ notarize the app (a few minutes)"
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait | tee "$out/notarize.log" | tail -4
  grep -q "status: Accepted" "$out/notarize.log" || { echo "Notarization was not accepted"; exit 1; }
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app" || { echo "Gatekeeper would refuse this build"; exit 1; }
else echo "▶ (test build: not notarized)"; fi

echo "▶ Sparkle zip, release notes, appcast"
rm -f "$out/updates/$APP-$version.zip"; ditto -c -k --keepParent "$app" "$out/updates/$APP-$version.zip"
python3 - "scripts/release-notes/$version.md" "$out/updates/$APP-$version.html" <<'PY'
import sys, re, html
out, inlist = [], False
for l in open(sys.argv[1]).read().split("\n"):
    m = re.match(r"\s*[-*] (.*)", l)
    t = html.escape(m.group(1) if m else l.strip())
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t); t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    if m:
        if not inlist: out.append("<ul>"); inlist = True
        out.append(f"<li>{t}</li>")
    else:
        if inlist: out.append("</ul>"); inlist = False
        if t: out.append(f"<p>{t}</p>")
if inlist: out.append("</ul>")
open(sys.argv[2], "w").write('<meta charset="utf-8"><style>body{font:13px -apple-system,sans-serif}code{font:12px ui-monospace}</style>' + "\n".join(out))
PY
rm -f "$out/updates/appcast.xml" "$out"/updates/*.delta   # generate_appcast merges with an existing appcast; start clean (no delta patches: full zips are small)
"$TOOLS/generate_appcast" "$out/updates" --account deadbolt --download-url-prefix "$HOST/updates/" --embed-release-notes --maximum-deltas 0 --link "$HOST/" -o "$out/updates/appcast.xml"
grep -q "sparkle:edSignature" "$out/updates/appcast.xml" || { echo "Appcast has no EdDSA signature: is the Sparkle key (account deadbolt) in the Keychain?"; exit 1; }
if [[ $notarize == 1 ]]; then   # test builds are never copied where a website deploy could publish them
  mkdir -p website/public/updates
  cp -f "$out/updates/appcast.xml" website/public/updates/appcast.xml
  cp -f "$out/updates/$APP-$version.zip" "website/public/updates/$APP-$version.zip"
fi

echo "▶ DMG (signed, notarized, for first installs)"
mkdir -p "$out/dmg"; ditto "$app" "$out/dmg/$APP.app"; ln -s /Applications "$out/dmg/Applications"
dmg="$out/$APP-$version.dmg"; rm -f "$dmg"
hdiutil create -volname "$APP" -srcfolder "$out/dmg" -ov -format UDZO "$dmg" >/dev/null
codesign --sign "$SIGN_ID" --timestamp "$dmg"
if [[ $notarize == 1 ]]; then
  xcrun notarytool submit "$dmg" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait | tee "$out/notarize-dmg.log" | tail -3
  grep -q "status: Accepted" "$out/notarize-dmg.log" || { echo "DMG notarization was not accepted"; exit 1; }
  xcrun stapler staple "$dmg"
fi
shasum -a 256 "$dmg"

if [[ $deploy == 1 ]]; then
  echo "▶ upload the DMG to the invite download store (Workers KV, key Deadbolt.dmg; served only through personal links)"
  size=$(stat -f %z "$dmg")
  (cd website && npx --yes wrangler@4 kv key put Deadbolt.dmg --path "../$dmg" --binding DMG --remote \
     --metadata "{\"filename\":\"$APP-$version.dmg\",\"size\":$size}" 2>&1 | tail -2)
  echo "▶ deploy $HOST"
  (cd website && npx --yes wrangler@4 deploy 2>&1 | tail -4); sleep 3
  for u in "updates/appcast.xml" "updates/$APP-$version.zip"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -I "$HOST/$u"); echo "  $code  /$u"
    [[ "$code" == 200 ]] || { echo "Not live yet: $u"; exit 1; }
  done
fi

if [[ $install == 1 ]]; then
  echo "▶ install to /Applications"
  # Make sure the OLD process is really gone before replacing files: a running copy keeps running from wherever its bundle is
  # moved to (it was left running from build/backup once, so Settings and Sparkle never saw the new version).
  osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP" >/dev/null || break; sleep 1; done
  if pgrep -x "$APP" >/dev/null; then pkill -TERM -x "$APP" || true; sleep 3; fi
  pgrep -x "$APP" >/dev/null && { echo "$APP is still running; quit it and run again"; exit 1; }
  mkdir -p build/backup
  [[ -d "/Applications/$APP.app" ]] && { rm -rf "build/backup/$APP-previous.app"; mv "/Applications/$APP.app" "build/backup/$APP-previous.app"; }
  ditto "$app" "/Applications/$APP.app"
  pluginkit -a "/Applications/$APP.app/Contents/PlugIns/DeadboltMacAutoFill.appex" 2>/dev/null || true
  pluginkit -e use -i com.osborne.deadbolt.autofill 2>/dev/null || true
  open "/Applications/$APP.app"; sleep 3
  running=$(python3 scripts/pidpath.py "$(pgrep -x "$APP" | head -1)")
  [[ "$running" == "/Applications/$APP.app/"* ]] || { echo "The running $APP is not the /Applications copy: $running"; exit 1; }
  echo "  running from $running"
fi
echo "✔ $APP $version ($build) built. DMG: $dmg"
[[ $deploy == 1 ]] || echo "  Not published. Run with --deploy to put the update on $HOST."
