#!/usr/bin/env bash
# Builds Proton's ntdll.so with ntdll-views.patch.txt and puts it into a copy of
# Proton Experimental (hard links, ~/.local/share/victory/proton-patched),
# which scripts/play.sh then uses. Steam's Proton is left as it is.
#
# The patch: section views of the title's pages are not told to wineserver
# (WINE_VICTORY_NO_VIEW_SERVER=1, which play.sh sets), and otherwise told
# outside the process's memory lock. Under Proton a map of one page took
# 150 us in the world, 24 with it.
#
# Usage: scripts/wine/build-ntdll.sh   (after a Proton update: run it again)
# Needs: git, autoconf, gcc, flex, bison, mingw-w64, python3, perl.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
proton=${PROTON_SOURCE:-$HOME/.steam/steam/steamapps/common/Proton - Experimental}
src=${WINE_SOURCE:-$HOME/proj/proton-wine} build=${WINE_BUILD:-$HOME/proj/proton-wine-build}
dst=$HOME/.local/share/victory/proton-patched

# The wine commit of this Proton build, from Valve's tag of its version.
version=$(awk '{print $2}' "$proton/version")              # e.g. experimental-11.0-20261105c
commit=$(gh api "repos/ValveSoftware/Proton/contents/wine?ref=$version" --jq .sha)
echo "Proton $version, wine $commit"

mkdir -p "$src"
cd "$src"
[[ -d .git ]] || { git init -q; git remote add origin https://github.com/ValveSoftware/wine.git; }
if [[ $(git rev-parse -q HEAD 2>/dev/null) != "$commit" ]]; then
    git fetch -q --depth 1 origin "$commit"
    git checkout -q -f FETCH_HEAD
    git clean -qfdx
fi
git checkout -q -- dlls/ntdll/unix/virtual.c
git apply "$here/ntdll-views.patch.txt"
# Generated sources Proton's build makes before configure.
[[ -f configure ]] || autoreconf -fi
w=$src/dlls/winevulkan
[[ -f include/wine/vulkan.h ]] || XDG_CACHE_HOME=$build/cache python3 "$w/make_vulkan" -x "$w/vk.xml" -X "$w/video.xml"
tools/make_specfiles
tools/make_requests

mkdir -p "$build"
cd "$build"
[[ -f Makefile ]] || "$src/configure" --enable-archs=x86_64,i386 --enable-win64 --disable-tests > configure.log
make -j"$(nproc)" dlls/ntdll/ntdll.so > make.log

rm -rf "$dst"
cp -al "$proton" "$dst"
# Files of our own (not links into Steam's): the new ntdll.so, and a
# wineserver that may be given CAP_SYS_NICE (see play.sh).
f=$dst/files/lib/wine/x86_64-unix/ntdll.so
rm "$f"; cp "$build/dlls/ntdll/ntdll.so" "$f"
f=$dst/files/bin/wineserver
cp "$f" "$f.own"; mv "$f.own" "$f"
echo "Done: $dst"
echo "For thread priorities (the title's audio), once: sudo setcap cap_sys_nice+ep '$f'"
