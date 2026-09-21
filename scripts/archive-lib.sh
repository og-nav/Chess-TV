#!/bin/zsh
# Shared by scripts/archive-tv.sh and scripts/archive-ios.sh. Not meant to be run directly.
#
# archive_app <platform> <scheme> <destination>
#   platform     tvos | ios          (names the archive, export folder, log and altool -t type)
#   scheme       ChessTV | ChessTVMobile
#   destination  generic/platform=tvOS | generic/platform=iOS
#
# Flags (after the script name):
#   --upload     export straight to App Store Connect (ExportOptions destination=upload). Needs signing
#                to work, and an ASC API key or an Apple ID session in Xcode.
#   --validate   after a local export, run `xcrun altool --validate-app` against App Store Connect
#                with the ASC API key (no upload).
#   --unsigned   Release archive with CODE_SIGNING_ALLOWED=NO, no export: proves the code compiles for
#                device when no distribution signing is available yet.
#
# Environment (optional, all three together): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#   An App Store Connect API key (Users and Access > Integrations > App Store Connect API, role App
#   Manager or Admin). Passed to xcodebuild as -authenticationKeyID / -authenticationKeyIssuerID /
#   -authenticationKeyPath so automatic signing can create certificates and profiles headlessly.
#   Without it, `-allowProvisioningUpdates` uses the Apple ID signed in to Xcode > Settings > Accounts.
set -euo pipefail
TEAM_ID="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"

archive_app() {
  local platform=$1 scheme=$2 destination=$3; shift 3
  local upload=0 validate=0 unsigned=0
  for arg in "$@"; do
    case $arg in
      --upload) upload=1 ;;
      --validate) validate=1 ;;
      --unsigned) unsigned=1 ;;
      *) echo "unknown flag: $arg" >&2; return 2 ;;
    esac
  done
  mkdir -p build/archives build/export build/logs
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local log="build/logs/archive-$platform-$stamp.log"
  local archive="build/archives/$scheme-$stamp.xcarchive"
  local export_dir="build/export/$platform-$stamp"

  local build_number; build_number=$(scripts/build-number.sh --write)
  xcodegen generate --quiet
  echo "== $scheme  build $build_number  log $log"

  local -a auth=()
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    echo "== using App Store Connect API key $ASC_KEY_ID"
  elif (( validate )); then
    echo "== --validate runs altool, which needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (see scripts/testflight.md)" >&2
    return 2
  else
    echo "== no ASC_* key in the environment; signing and upload use the Apple ID signed in to Xcode > Settings > Accounts"
  fi

  local -a signing=(-allowProvisioningUpdates "${auth[@]}")
  (( unsigned )) && signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")

  echo "== archiving to $archive"
  if ! xcodebuild archive \
      -project ChessTV.xcodeproj -scheme "$scheme" -configuration Release \
      -destination "$destination" -archivePath "$archive" \
      -derivedDataPath "build/DerivedData-$platform" \
      "DEVELOPMENT_TEAM=$TEAM_ID" "${signing[@]}" >"$log" 2>&1; then
    echo "== archive FAILED; relevant lines from $log:" >&2
    grep -E "error:|error \(|Error Domain|No signing|No profiles|requires a provisioning|No Accounts|Provisioning profile|ARCHIVE FAILED" "$log" | sort -u | head -40 >&2
    return 1
  fi
  echo "== archive ok"
  (( unsigned )) && { echo "== unsigned archive only; skipping export"; return 0; }

  local dest=export; (( upload )) && dest=upload
  local options="build/export/ExportOptions-$platform.plist"
  cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$dest</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
	<key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

  echo "== exporting ($dest) to $export_dir"
  if ! xcodebuild -exportArchive \
      -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$export_dir" \
      -allowProvisioningUpdates "${auth[@]}" >>"$log" 2>&1; then
    echo "== export FAILED; relevant lines from $log:" >&2
    grep -E "error:|Error Domain|No signing|No profiles|requires a provisioning|No Accounts|Provisioning profile|EXPORT FAILED|ITMS-" "$log" | sort -u | head -40 >&2
    return 1
  fi
  echo "== export ok"
  (( upload )) && { echo "== uploaded to App Store Connect; processing takes a few minutes, then it appears under TestFlight"; return 0; }
  ls -la "$export_dir"   # an upload writes nothing locally, so only a local export has a folder to show

  if (( validate )); then
    # altool finds keys by name in API_PRIVATE_KEYS_DIR, so hand it a private copy named the way it wants.
    local keydir="build/.asc-keys"; mkdir -p "$keydir"; chmod 700 "$keydir"
    cp "$ASC_KEY_PATH" "$keydir/AuthKey_$ASC_KEY_ID.p8"; chmod 600 "$keydir/AuthKey_$ASC_KEY_ID.p8"
    local ipa; ipa=$(ls "$export_dir"/*.ipa | head -1)
    echo "== validating $ipa with App Store Connect (no upload)"
    local altool_platform=$platform; [[ $platform == tvos ]] && altool_platform=appletvos   # altool spells it differently
    API_PRIVATE_KEYS_DIR="$PWD/$keydir" xcrun altool --validate-app -f "$ipa" -t "$altool_platform" \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee -a "$log" | grep -vE "^\s*$" | tail -20
    echo "== validation finished; to upload, rerun with --upload"
  fi
}
