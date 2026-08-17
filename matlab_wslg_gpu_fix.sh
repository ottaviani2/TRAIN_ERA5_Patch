#!/usr/bin/env bash
#
# =============================================================================
#  Patch: blank MATLAB figures / print hanging under WSLg  (+ StaMPS/TRAIN path)
#  Tested on: Windows 11 + WSL2 (WSLg) + Ubuntu 24.04 + MATLAB R2026a
#             with a GPU exposed to the distro via /dev/dxg
#  Date: 2026-08-17
# =============================================================================
#
# SYMPTOM
#   The figure window opens but stays BLANK; print/export and StaMPS's ps_plot
#   commands hang for minutes and then:
#     "Warning: Unable to generate graphics because of system configuration
#      or graphics resource constraint"
#   In MATLAB: rendererinfo -> MaxTextureSize = 0, HardwareSupportLevel = None
#
# CAUSE
#   Under WSL, Mesa selects llvmpipe (software rendering) instead of the GPU
#   exposed by Windows through D3D12. In R2026a a MATLAB figure is a web page
#   drawn by an internal Chromium (MATLABWindow + ANGLE/WebGL), and Chromium
#   REFUSES to create a WebGL context when the only available rendering is
#   software: an upstream security restriction, not a fault. The canvas is
#   never created, the window stays blank and print waits forever.
#
# FIX
#       export GALLIUM_DRIVER=d3d12
#   CAREFUL: MESA_LOADER_DRIVER_OVERRIDE=d3d12 does NOT work (verified: it
#   keeps returning llvmpipe). GALLIUM_DRIVER is what is needed.
#
#   It is applied at TWO levels, because .bashrc alone is not enough: an
#   already-open terminal does not re-read it, and MATLAB launched from there
#   starts without the variable (that is exactly how the problem came back).
#     1. ~/.bashrc                              -> for new terminals
#     2. /usr/local/MATLAB/R2026a/bin/matlab    -> applies from ANY terminal
#
# WHAT DOES NOT WORK (all verified experimentally: do not retry)
#   - -softwareopengl flag ...................... removed in R2026a
#   - opengl('save','software') ................. function removed in R2026a
#   - 'painters' renderer ....................... hangs just the same
#   - matlab -nodisplay / -nodesktop ............ same CEF stack, same stall
#   - LIBGL_ALWAYS_SOFTWARE=1 ................... makes it worse (forces software)
#   - MW_CEF_STARTUP_OPTIONS with --enable-unsafe-swiftshader, --disable-gpu,
#     --use-angle=swiftshader ................... the flags really do reach
#                                                 Chromium, but no context is
#                                                 created anyway
#   - restoring MATLAB's original libvulkan.so.1 /
#     libfreetype.so.6 libraries ................ no effect
#   - libstdc++ conflict ........................ red herring
#
# ALSO: StaMPS and TRAIN paths
#   They were not in MATLAB's saved path (no user pathdef.m): they had to be
#   added by hand in every session and were lost on exit, causing
#   "Undefined function 'setparm'" and "Undefined function 'setparm_aps'".
#   The patch makes them permanent in ~/Documents/MATLAB/startup.m.
#   Both directories are auto-detected under $HOME and can be overridden with
#   the STAMPS_DIR / TRAIN_DIR environment variables.
#
# REQUIREMENT
#   A GPU exposed to WSL (/dev/dxg present). Without hardware acceleration
#   there is NO way to obtain a graphics context in R2026a: in that case the
#   only route is MATLAB for Windows on the files via \\wsl.localhost.
#
# USAGE
#   bash matlab_wslg_gpu_fix.sh              apply
#   bash matlab_wslg_gpu_fix.sh --check      diagnosis only, changes nothing
#   bash matlab_wslg_gpu_fix.sh --rollback   restore from the backups
#   Idempotent: re-running it duplicates nothing.
# =============================================================================

set -u

BASHRC="$HOME/.bashrc"
STARTUP="$HOME/Documents/MATLAB/startup.m"
LAUNCHER="${MATLAB_LAUNCHER:-/usr/local/MATLAB/R2026a/bin/matlab}"
MODE="${1:-apply}"

# Locate the toolboxes: first the environment variable, then the usual layouts
# under $HOME (including the nested one left by an unzipped GitHub archive).
find_toolbox () {                     # $1 = marker file, $2... = glob patterns
    local marker="$1"; shift
    local c
    for c in "$@"; do
        [ -f "$c/$marker" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
STAMPS_DIR="${STAMPS_DIR:-$(find_toolbox setparm.m \
    "$HOME"/StaMPS*/matlab "$HOME"/*/StaMPS*/matlab \
    "$HOME"/*/*/StaMPS*/matlab "$HOME"/*/*/*/StaMPS*/matlab 2>/dev/null)}"
TRAIN_DIR="${TRAIN_DIR:-$(find_toolbox aps_load_era.m \
    "$HOME"/TRAIN/matlab "$HOME"/*/TRAIN*/matlab \
    "$HOME"/*/*/TRAIN*/matlab "$HOME"/*/*/*/TRAIN*/matlab 2>/dev/null)}"
STAMPS_DIR="${STAMPS_DIR:-$HOME/software/StaMPS/matlab}"
TRAIN_DIR="${TRAIN_DIR:-$HOME/software/TRAIN/matlab}"

ok()   { printf "  \033[32m[OK]\033[0m   %s\n" "$1"; }
bad()  { printf "  \033[31m[!!]\033[0m   %s\n" "$1"; }
inf()  { printf "  ---    %s\n" "$1"; }
ttl()  { printf "\n\033[1m%s\033[0m\n" "$1"; }

# -----------------------------------------------------------------------------
diagnose () {
    local fatal=0

    ttl "1. GPU exposed to WSL"
    if [ -e /dev/dxg ]; then
        ok "/dev/dxg present"
    else
        bad "/dev/dxg MISSING: no GPU exposed to the distro"
        inf "Update WSL (wsl --update) and the Windows graphics drivers,"
        inf "or use MATLAB for Windows via \\\\wsl.localhost."
        fatal=1
    fi

    ttl "2. Driver selected by Mesa"
    if command -v glxinfo >/dev/null 2>&1; then
        local now hw
        now=$(timeout 30 glxinfo -B 2>/dev/null | grep "OpenGL renderer string" | sed 's/.*: //')
        hw=$(timeout 30 env GALLIUM_DRIVER=d3d12 glxinfo -B 2>/dev/null | grep "OpenGL renderer string" | sed 's/.*: //')
        inf "current                  : ${now:-unknown}"
        inf "with GALLIUM_DRIVER=d3d12: ${hw:-not available}"
        case "$hw" in
            *D3D12*) ok "hardware acceleration available" ;;
            *)       bad "d3d12 yields no acceleration: Windows drivers to update?"; fatal=1 ;;
        esac
    else
        inf "glxinfo not installed (sudo apt install mesa-utils): skipping"
    fi

    ttl "3. Patch status"
    inf "STAMPS_DIR: $STAMPS_DIR"
    inf "TRAIN_DIR : $TRAIN_DIR"
    grep -q "^export GALLIUM_DRIVER=d3d12" "$BASHRC" 2>/dev/null \
        && ok ".bashrc   : patch present" || inf ".bashrc   : patch absent"

    if [ -f "$LAUNCHER" ]; then
        grep -q "GALLIUM_DRIVER" "$LAUNCHER" 2>/dev/null \
            && ok "launcher  : patch present" || inf "launcher  : patch absent"
    else
        bad "launcher  : $LAUNCHER not found"
    fi

    if [ -f "$STARTUP" ]; then
        grep -qE "^[[:space:]]*setenv\('(LIBGL_ALWAYS_SOFTWARE|MESA_LOADER_DRIVER_OVERRIDE|LD_PRELOAD)'" "$STARTUP" \
            && bad "startup.m : contains lines forcing software rendering" \
            || ok "startup.m : no harmful line"
        grep -q "addpath(genpath(STAMPS_DIR))" "$STARTUP" \
            && ok "startup.m : StaMPS/TRAIN paths present" \
            || inf "startup.m : StaMPS/TRAIN paths absent"
    else
        inf "startup.m : not present (will be created)"
    fi

    return $fatal
}

# -----------------------------------------------------------------------------
if [ "$MODE" = "--rollback" ]; then
    ttl "RESTORE"
    if [ -f "${BASHRC}.bak_gpu" ]; then
        cp "${BASHRC}.bak_gpu" "$BASHRC"; ok ".bashrc restored"
    elif grep -q "^export GALLIUM_DRIVER=d3d12" "$BASHRC" 2>/dev/null; then
        # both marker spellings: earlier revisions of this script wrote the
        # Italian one
        sed -i -E '/# >>> (WSLg graphics patch|patch grafica WSLg)/,/# <<< (WSLg graphics patch|patch grafica WSLg)/d' "$BASHRC"
        ok "block removed from .bashrc"
    else
        inf "nothing to do on .bashrc"
    fi

    if [ -f "${LAUNCHER}.bak_gpu" ]; then
        cat "${LAUNCHER}.bak_gpu" > "$LAUNCHER"; ok "MATLAB launcher restored"
    else
        inf "no launcher backup"
    fi

    if [ -f "${STARTUP}.bak_gpu" ]; then
        cp "${STARTUP}.bak_gpu" "$STARTUP"; ok "startup.m restored"
        bad "CAREFUL: this also brings back the lines that break the graphics,"
        inf "and the StaMPS/TRAIN paths will have to be added by hand again."
    else
        inf "no startup.m backup"
    fi
    echo; inf "Open a new terminal for this to take effect."
    exit 0
fi

if [ "$MODE" = "--check" ]; then
    diagnose; echo; inf "No change made (--check)."; exit 0
fi

# -----------------------------------------------------------------------------
diagnose || { echo; bad "Requirements not met: aborting."; exit 1; }

ttl "4. Applying"

# --- 4a. .bashrc -------------------------------------------------------------
if grep -q "^export GALLIUM_DRIVER=d3d12" "$BASHRC" 2>/dev/null; then
    ok ".bashrc already patched"
else
    [ -f "${BASHRC}.bak_gpu" ] || cp "$BASHRC" "${BASHRC}.bak_gpu"
    cat >> "$BASHRC" <<'BLOCK'

# >>> WSLg graphics patch >>>
# GPU acceleration for WSLg (via D3D12). Without it Mesa falls back on llvmpipe
# (software) and the internal Chromium of MATLAB R2026a refuses the WebGL
# context: figure windows stay blank and print/export hang.
# Note: MESA_LOADER_DRIVER_OVERRIDE=d3d12 does NOT work, GALLIUM_DRIVER is needed.
export GALLIUM_DRIVER=d3d12
# <<< WSLg graphics patch <<<
BLOCK
    ok "GALLIUM_DRIVER added to .bashrc (backup: .bashrc.bak_gpu)"
fi

# --- 4b. MATLAB launcher (terminal-independent) ------------------------------
if [ ! -f "$LAUNCHER" ]; then
    bad "launcher not found: $LAUNCHER"
elif grep -q "GALLIUM_DRIVER" "$LAUNCHER"; then
    ok "launcher already patched"
elif [ ! -w "$LAUNCHER" ]; then
    bad "launcher not writable: re-run with sudo to patch it"
    inf "(without it, the patch only applies from new terminals)"
else
    [ -f "${LAUNCHER}.bak_gpu" ] || cp -p "$LAUNCHER" "${LAUNCHER}.bak_gpu"
    TMP=$(mktemp)
    {
        head -1 "$LAUNCHER"
        cat <<'BLOCK'

# >>> WSLg graphics patch >>>
# Select the GPU exposed by Windows via D3D12. Set here, and not only in
# .bashrc, so that it applies from any terminal: an already-open one does not
# re-read .bashrc and MATLAB would start without the variable.
# Note: MESA_LOADER_DRIVER_OVERRIDE=d3d12 does NOT work, GALLIUM_DRIVER is needed.
# Disable with: export MATLAB_NO_GPU_PATCH=1
if [ -e /dev/dxg ] && [ -z "${MATLAB_NO_GPU_PATCH:-}" ]; then
    GALLIUM_DRIVER=d3d12
    export GALLIUM_DRIVER
    unset LIBGL_ALWAYS_SOFTWARE
    unset MESA_LOADER_DRIVER_OVERRIDE
fi
# <<< WSLg graphics patch <<<
BLOCK
        tail -n +2 "$LAUNCHER"
    } > "$TMP"
    if sh -n "$TMP" 2>/dev/null; then
        cat "$TMP" > "$LAUNCHER"       # preserves permissions and inode
        ok "launcher patched (backup: $(basename "$LAUNCHER").bak_gpu)"
    else
        bad "the launcher edit is not syntactically valid: discarded"
    fi
    rm -f "$TMP"
fi

# --- 4c. startup.m -----------------------------------------------------------
mkdir -p "$(dirname "$STARTUP")"
if [ -f "$STARTUP" ] && grep -qE "^[[:space:]]*setenv\('(LIBGL_ALWAYS_SOFTWARE|MESA_LOADER_DRIVER_OVERRIDE|LD_PRELOAD)'" "$STARTUP"; then
    [ -f "${STARTUP}.bak_gpu" ] || cp "$STARTUP" "${STARTUP}.bak_gpu"
    sed -i -E "s|^([[:space:]]*setenv\('(LIBGL_ALWAYS_SOFTWARE\|MESA_LOADER_DRIVER_OVERRIDE\|LD_PRELOAD)'.*)$|% [WSLg patch] disabled: \1|" "$STARTUP"
    ok "harmful lines disabled in startup.m (backup: startup.m.bak_gpu)"
fi

if [ -f "$STARTUP" ] && grep -q "addpath(genpath(STAMPS_DIR))" "$STARTUP"; then
    ok "startup.m already has the StaMPS/TRAIN paths"
else
    [ -f "$STARTUP" ] && { [ -f "${STARTUP}.bak_gpu" ] || cp "$STARTUP" "${STARTUP}.bak_gpu"; }
    cat >> "$STARTUP" <<EOF

%% [WSLg patch] StaMPS and TRAIN paths
% They were not in MATLAB's saved path: they had to be added by hand in every
% session and were lost on exit, hence the errors
% "Undefined function 'setparm'" and "Undefined function 'setparm_aps'".
STAMPS_DIR = '${STAMPS_DIR}';
TRAIN_DIR  = '${TRAIN_DIR}';
if exist(STAMPS_DIR,'dir')==7
    addpath(genpath(STAMPS_DIR));
else
    warning('startup:stamps','StaMPS path not found: %s', STAMPS_DIR);
end
if exist(TRAIN_DIR,'dir')==7
    addpath(genpath(TRAIN_DIR));
else
    warning('startup:train','TRAIN path not found: %s', TRAIN_DIR);
end
clear STAMPS_DIR TRAIN_DIR

% gmt, snaphu and triangle are called by StaMPS/TRAIN
if isempty(strfind(getenv('PATH'), '/usr/local/bin'))
    setenv('PATH', ['/usr/local/bin:' getenv('PATH')]);
end
EOF
    ok "StaMPS/TRAIN paths added to startup.m"
fi

# -----------------------------------------------------------------------------
ttl "5. Verification"
export GALLIUM_DRIVER=d3d12
if command -v glxinfo >/dev/null 2>&1; then
    r=$(timeout 30 glxinfo -B 2>/dev/null | grep "OpenGL renderer string" | sed 's/.*: //')
    case "$r" in
        *D3D12*) ok "renderer: $r" ;;
        *)       bad "renderer still: ${r:-unknown}" ;;
    esac
fi

if command -v matlab >/dev/null 2>&1; then
    inf "graphics test in MATLAB (up to ~3 minutes)..."
    T=$(mktemp -d)
    cat > "$T/gputest.m" <<'EOF'
r = rendererinfo;
fprintf('MAXTEX=%g\n', r.Details.MaxTextureSize);
fprintf('SETPARM=%d\n', ~isempty(which('setparm')));
fprintf('SETPARMAPS=%d\n', ~isempty(which('setparm_aps')));
h = figure('Visible','off'); plot(1:10,(1:10).^2);
print(h, fullfile(tempdir,'gputest.png'), '-dpng', '-r72');
d = dir(fullfile(tempdir,'gputest.png'));
fprintf('PNG=%d\n', d.bytes);
exit
EOF
    # -u GALLIUM_DRIVER: check that the launcher copes on its own
    out=$(cd "$T" && env -u GALLIUM_DRIVER timeout 200 matlab -batch gputest 2>&1)
    png=$(echo "$out"  | grep -oP 'PNG=\K[0-9]+' | head -1)
    mt=$(echo "$out"   | grep -oP 'MAXTEX=\K[0-9]+' | head -1)
    sp=$(echo "$out"   | grep -oP 'SETPARM=\K[01]' | head -1)
    spa=$(echo "$out"  | grep -oP 'SETPARMAPS=\K[01]' | head -1)
    if [ -z "$mt" ] && [ -z "$png" ]; then
        # MATLAB did not even start: no point blaming the paths
        bad "MATLAB did not start, test not run:"
        echo "$out" | grep -vE "^$" | head -4 | sed 's/^/        /'
    else
        if [ "${png:-0}" -gt 0 ] 2>/dev/null; then
            ok "graphics working with no external variables (MaxTextureSize=${mt:-?}, PNG ${png} bytes)"
        else
            bad "the graphics test produced no image"
            echo "$out" | head -8 | sed 's/^/        /'
        fi
        [ "${sp:-0}"  = "1" ] && ok "setparm (StaMPS) available"     || bad "setparm NOT available: check STAMPS_DIR"
        [ "${spa:-0}" = "1" ] && ok "setparm_aps (TRAIN) available"  || bad "setparm_aps NOT available: check TRAIN_DIR"
    fi
    rm -rf "$T"
else
    inf "matlab not on PATH: skipping the test"
fi

ttl "DONE"
inf "Close MATLAB and reopen it: no new terminal and no WSL restart needed."
inf "To undo: bash $(basename "$0") --rollback"
