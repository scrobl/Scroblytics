#!/bin/bash
# Builds the installer disk image from a staging folder (the app and an Applications shortcut): the app on the left,
# the Applications folder on the right, an arrow between them. Finder keeps that layout in the image, so it is set by
# mounting a writable copy, telling Finder where everything goes, and compressing the result.
#
#   scripts/make-dmg.sh <staging folder> <volume name> <output.dmg>
#
# Prints "layout: ok" when the arrangement was saved. If Finder can't be driven (no desktop session, or macOS has not
# allowed this process to control Finder) it prints "layout: skipped (<reason>)" and still writes a plain, working image.
set -uo pipefail

stage="${1:?staging folder}"; volname="${2:?volume name}"; out="${3:?output .dmg}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/scroblytics-dmg.XXXXXX")"
mountpoint="/Volumes/$volname"
attached=0

detach() {
  [ "$attached" = 1 ] || return 0
  hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || { sleep 2; hdiutil detach "$mountpoint" -force -quiet >/dev/null 2>&1; } || true
  attached=0
}
cleanup() { detach; rm -rf "$work"; }
trap cleanup EXIT
die() { echo "make-dmg: $*" >&2; exit 1; }

[ -e "$mountpoint" ] && die "$mountpoint is already mounted or exists; eject it first."
[ -d "$stage/Scroblytics.app" ] || die "no Scroblytics.app in $stage."

# 1. A writable image with the contents, with room for the background picture and Finder's own files.
size_mb=$(( $(du -sm "$stage" | cut -f1) + 40 ))
rw="$work/rw.dmg"
hdiutil create -srcfolder "$stage" -volname "$volname" -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$rw" >/dev/null 2>&1 || die "hdiutil couldn't create the writable image."

# 2. The background picture: normal and Retina, combined into one multi-resolution file.
background_ok=1
swift "$here/make-dmg-background.swift" "$work/background.png" 1 >/dev/null 2>&1 \
  && swift "$here/make-dmg-background.swift" "$work/background@2x.png" 2 >/dev/null 2>&1 \
  && tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" >/dev/null 2>&1 \
  || background_ok=0

# 3. Mount it and set the window.
layout="skipped (could not mount the writable image)"
if hdiutil attach "$rw" -readwrite -noverify -noautoopen -mountpoint "$mountpoint" >/dev/null 2>&1; then
  attached=1
  layout="skipped (the background picture could not be drawn)"
  if [ "$background_ok" = 1 ]; then
    mkdir "$mountpoint/.background" && cp "$work/background.tiff" "$mountpoint/.background/background.tiff" && chflags hidden "$mountpoint/.background"
    # The window is 600 x 400 points inside a title bar; icons sit where the picture's arrow expects them.
    script=$(cat <<EOF
tell application "Finder"
  tell disk "$volname"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 548}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 112
    set text size of theOptions to 13
    set background picture of theOptions to file ".background:background.tiff"
    set position of item "Scroblytics.app" of container window to {150, 175}
    set position of item "Applications" of container window to {450, 175}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
)
    if err="$(printf '%s\n' "$script" | perl -e 'alarm 90; exec "/usr/bin/osascript", "-"' 2>&1)"; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$mountpoint/.DS_Store" ] && break; sleep 1; done
      if [ -f "$mountpoint/.DS_Store" ]; then layout="ok"; else layout="skipped (Finder saved no layout)"; fi
    else
      layout="skipped ($(printf '%s' "$err" | tr '\n' ' ' | cut -c1-160))"
    fi
  fi
  sync
  rm -rf "$mountpoint/.fseventsd" 2>/dev/null || true
  detach
fi

# 4. Compress. (hdiutil convert keeps the layout file.)
rm -f "$out"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -ov -o "$out" >/dev/null 2>&1 || die "hdiutil couldn't compress the image."
echo "layout: $layout"
