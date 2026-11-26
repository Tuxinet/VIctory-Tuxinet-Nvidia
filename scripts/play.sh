#!/usr/bin/env bash
# Linux counterpart of play.ps1: runs the cross-built victory.exe under Proton
# (vkd3d-proton turns D3D12 into Vulkan). Build first with:
#   XWIN_ACCEPT_LICENSE=1 cargo xwin build --locked --profile diag -p victory \
#       --features diagnostics --target x86_64-pc-windows-msvc
# Usage: scripts/play.sh [--safe] [--ray-tracing] [--fsr4k quality|balanced|performance]
#                        [--build diag|release] [--exe <path>] [--gamescope] [--auto-start] [--console series-x|series-s] [VAR=value ...]
#                        [-- <other victory command, e.g. config, or shaders <path>>]
# PROTON selects the Proton folder (default: Proton - Experimental);
# VICTORY_PREFIX the Wine prefix (default: ~/.local/share/victory/prefix).
# --auto-start  presses Enter (the pad's A) 15 s in, past the start screen,
#               for runs left alone; VICTORY_KEYS
#               (diagnostics builds) says other keys and times.
# --console     the console the title sees: series-x (default) or series-s
#               (1080p, cheaper; the README's measurements are with it).
# --gamescope   fullscreen in gamescope, the title's 16:9 picture kept 16:9 (bars
#               at the sides on a 21:9 screen); GAMESCOPE_SCREEN=3440x1440 names
#               the screen's size (needed with several screens).
# Each run's whole log is written to ~/.local/share/victory/logs; the terminal
# shows warnings and errors only (VICTORY_TERMINAL=all: everything).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build=diag safe= rt= fsr= exe= gamescope= auto= console=series-x more=() cmd=()
while (($#)); do
    case $1 in
        --safe) safe=1 ;;
        --ray-tracing) rt=1 ;;
        --fsr4k) fsr=$2; shift ;;
        --build) build=$2; shift ;;
        --exe) exe=$2; shift ;;
        --gamescope) gamescope=1 ;;
        --auto-start) auto=1 ;;
        --console) console=$2; shift ;;
        --) shift; cmd=("$@"); break ;;
        *=*) more+=("$1") ;;
        *) echo "Unknown argument $1"; exit 1 ;;
    esac
    shift
done

# The executable: --exe, or the one the dump's manifest names.
if [[ -z $exe ]]; then
    game_dir=${VICTORY_GAME_DIR:-$(sed -n "s/^game_dir *= *['\"]\(.*\)['\"]/\1/p" "$root/victory.toml")}
    name=$(grep -o 'Executable="[^"]*"' "$game_dir/appxmanifest.xml" | head -1 | cut -d'"' -f2)
    exe=$game_dir/$name
fi
[[ -f $exe ]] || { echo "No $exe."; exit 1; }
victory=$root/target/x86_64-pc-windows-msvc/$build/victory.exe
[[ -f $victory ]] || { echo "No $victory. Build it first (see the top of this script)."; exit 1; }

proton_dir=${PROTON:-$HOME/.steam/steam/steamapps/common/Proton - Experimental}
[[ -x $proton_dir/proton ]] || { echo "No Proton at $proton_dir (set PROTON)."; exit 1; }

# Same settings as play.ps1. Unlike play.ps1, VICTORY_* set in the shell are
# kept (`VICTORY_OUTPUT=2560x1440 scripts/play.sh`) and win over these.
inherited=()
for v in $(compgen -e | grep '^VICTORY_'); do
    case $v in VICTORY_CONFIG|VICTORY_GAME_DIR|VICTORY_CACHE_DIR|VICTORY_DATA_DIR|VICTORY_FIDELITYFX_DIR|VICTORY_PREFIX) ;;
        *) inherited+=("$v=${!v}") ;; esac
done
((${#inherited[@]})) && echo "From the shell: ${inherited[*]}"
export VICTORY_TEXTURE_NO_WAIT=1 VICTORY_RELAY=2 VICTORY_WIDE_BACK=1 VICTORY_CARD_REHASH_RUNS=1 \
    VICTORY_JOIN_COPIES=1 VICTORY_INDIRECT_WINDOW=1 VICTORY_RELAY_COPY=1 VICTORY_CARD_STEPS=2 \
    VICTORY_INDIRECT_BATCH=2 VICTORY_MAP_THREADS=1 VICTORY_TITLE_PRIORITIES=0 VICTORY_CARD_AWAKE=1 \
    VICTORY_SHOW_AFTER=1 VICTORY_AMBIENT=0.8 VICTORY_D3D12_DRED=light
# The pipelines the title creates are written down, so that
# `scripts/play.sh -- warm --used` can make them ahead of the next run.
export VICTORY_PIPELINE_BOOK=1
if [[ -n $safe ]]; then
    export VICTORY_UNDER_WIDE=0 VICTORY_LAND_ECHO=0
else
    export VICTORY_THIN=1 VICTORY_JOIN_PARTS=8 VICTORY_UPLOAD_AHEAD=1
    # Renderer patches 1, 2, 6 and 7 (README): under Wine they also save most
    # of its write guards' cost and the scan of the view heap (the opening
    # cutscene: 1,700 to 1,170 ms a frame).
    export VICTORY_PORT_CONSTANTS=1 VICTORY_PORT_DESCRIPTORS=1 VICTORY_PORT_GUARD=1 VICTORY_PORT_JOURNAL=1
fi
[[ -n $auto ]] && export VICTORY_KEYS=15:Enter
[[ -n $rt ]] && export VICTORY_BVH_BUILDER=1
[[ -n $fsr ]] && export VICTORY_FSR_4K=$fsr
for kv in "${inherited[@]}" "${more[@]}"; do export "${kv?}"; done

# Linux paths in victory.toml / the environment are given to Windows as Z:\...
winpath() { printf 'Z:%s' "${1//\//\\}"; }
for v in VICTORY_GAME_DIR VICTORY_CACHE_DIR VICTORY_DATA_DIR VICTORY_FIDELITYFX_DIR; do
    [[ ${!v:-} == /* ]] && export "$v=$(winpath "${!v}")"
done
if [[ -z ${VICTORY_GAME_DIR:-} && -n ${game_dir:-} ]]; then export VICTORY_GAME_DIR=$(winpath "$game_dir"); fi
exe=$(cd "$(dirname "$exe")" && pwd)/$(basename "$exe")

export STEAM_COMPAT_DATA_PATH=${VICTORY_PREFIX:-$HOME/.local/share/victory/prefix}
export STEAM_COMPAT_CLIENT_INSTALL_PATH=${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}
if [[ ! -f $STEAM_COMPAT_DATA_PATH/pfx/system.reg ]]; then
    mkdir -p "$STEAM_COMPAT_DATA_PATH"
    "$proton_dir/proton" run cmd /c exit   # first time: Proton sets the prefix up, vkd3d-proton included
fi
# vkd3d-proton built from upstream master (71cae091, dxil-spirv b540c8a2)
# replaces the prefix's: the dxil-spirv in Proton Experimental's (563eb6ca)
# turns some of the translator's control flow into invalid SPIR-V, on which
# NVIDIA's compiler crashes after the loading screen. Proton puts its own back
# when it updates the prefix, so it is copied in each time. VKD3D_PROTON_LIBS
# names the build's libs folder; empty keeps Proton's own.
vkd3d_libs=${VKD3D_PROTON_LIBS-$HOME/proj/vkd3d-proton/build-x64/libs}
if [[ -n $vkd3d_libs ]]; then
    for dll in d3d12 d3d12core; do
        from=$vkd3d_libs/$dll/$dll.dll to=$STEAM_COMPAT_DATA_PATH/pfx/drive_c/windows/system32/$dll.dll
        [[ -f $from ]] || { echo "No $from (VKD3D_PROTON_LIBS)."; exit 1; }
        cmp -s "$from" "$to" || { cp "$from" "$to" && echo "vkd3d-proton: $dll.dll from $vkd3d_libs"; }
    done
fi
# NVIDIA's shader cache on disk: Steam's launcher raises its size limit (1 GB
# by default, under what this title's pipelines take) and keeps it from being
# cleaned up; so does this.
export __GL_SHADER_DISK_CACHE=1 __GL_SHADER_DISK_CACHE_SIZE=${__GL_SHADER_DISK_CACHE_SIZE:-21474836480} \
    __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
# Proton's own wine, not its launcher, so the log stays in this terminal.
export WINEPREFIX=$STEAM_COMPAT_DATA_PATH/pfx WINEDEBUG=${WINEDEBUG:-fixme-all}   # errors kept: a crash says where
# vkd3d-proton's pipeline cache (game-derived) goes beside the prefix, not into
# the repository this runs from.
export VKD3D_SHADER_CACHE_PATH=${VKD3D_SHADER_CACHE_PATH:-$(winpath "$STEAM_COMPAT_DATA_PATH")}
# What Proton's launcher would set: the prefix's vkd3d-proton and DXVK, not Wine's own.
# And Microsoft's d3dcompiler_47 (`winetricks d3dcompiler_47`): Wine's cannot
# compile the layer's own helper shaders (the indirect argument clamp among
# them; without it every indirect draw is dropped).
export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi,d3d11,d3d10core,d3d9,d3dcompiler_47=n,b${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
if grep -qa "Wine builtin DLL" "$WINEPREFIX/drive_c/windows/system32/d3dcompiler_47.dll" 2>/dev/null; then
    echo "The prefix has Wine's d3dcompiler_47: most of the picture will be missing. Install Microsoft's with"
    echo "  WINEPREFIX=$WINEPREFIX WINE='$proton_dir/files/bin/wine' winetricks d3dcompiler_47"
fi
cd "$root"   # victory.toml is looked for here
if ((${#cmd[@]})); then
    exec "$proton_dir/files/bin/wine" "$victory" "${cmd[@]}"
fi
wrap=()
if [[ -n $gamescope ]]; then
    # The title's output size (3840x2160 unless VICTORY_OUTPUT says otherwise).
    out=${VICTORY_OUTPUT:-3840x2160} screen=${GAMESCOPE_SCREEN:-}
    if [[ -z $screen ]]; then   # the one screen; with several, say which
        screens=$(xrandr --current 2>/dev/null | grep -oP '^\S+ connected( primary)? \K\d+x\d+' || true)
        if (($(wc -l <<<"$screens") > 1)); then
            echo "Several screens ($(tr '\n' ' ' <<<"$screens")): set GAMESCOPE_SCREEN to the one the game goes on."
            exit 1
        fi
        screen=$screens
    fi
    wrap=(gamescope -w "${out%x*}" -h "${out#*x}" -f)
    [[ -n $screen ]] && wrap+=(-W "${screen%x*}" -H "${screen#*x}")
    wrap+=(--)
fi
logs=$HOME/.local/share/victory/logs
mkdir -p "$logs"
log=$logs/play-$(date +%Y%m%d-%H%M%S).log
echo "Log: $log"
# The whole log goes to the file; the terminal gets warnings, errors and the
# frame-rate lines unless VICTORY_TERMINAL=all.
if [[ ${VICTORY_TERMINAL:-} == all ]]; then
    exec > >(tee "$log") 2>&1
else
    exec > >(tee "$log" | grep --line-buffered -aE 'WARN|ERROR|err:|Exception|Unhandled|panicked|frame presented') 2>&1
fi
exec "${wrap[@]}" "$proton_dir/files/bin/wine" "$victory" run "$(winpath "$exe")" --execute --console "$console"
