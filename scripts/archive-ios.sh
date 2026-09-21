#!/bin/zsh
# Release archive + App Store Connect export of the iPhone/iPad app (scheme ChessTVMobile), which
# carries the watch app, the watch widget, the notification extensions and the Live Activity.
#   scripts/archive-ios.sh                archive and export an .ipa to build/export/
#   scripts/archive-ios.sh --validate     ...and validate it with App Store Connect (needs ASC_* env)
#   scripts/archive-ios.sh --upload       archive and upload to TestFlight (needs ASC_* env)
#   scripts/archive-ios.sh --unsigned     compile-only check with code signing off
# See scripts/testflight.md.
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.."
source "$here/archive-lib.sh"
archive_app ios ChessTVMobile "generic/platform=iOS" "$@"
