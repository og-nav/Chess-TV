#!/bin/zsh
# Release archive + App Store Connect export of the Apple TV app (scheme ChessTV).
#   scripts/archive-tv.sh                 archive and export an .ipa to build/export/
#   scripts/archive-tv.sh --validate      ...and validate it with App Store Connect (needs ASC_* env)
#   scripts/archive-tv.sh --upload        archive and upload to TestFlight (needs ASC_* env)
#   scripts/archive-tv.sh --unsigned      compile-only check with code signing off
# See scripts/testflight.md.
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.."
source "$here/archive-lib.sh"
archive_app tvos ChessTV "generic/platform=tvOS" "$@"
