#!/usr/bin/env bash
# =============================================================================
# shastenm Linux Dev Labs — Dotfiles Installer  (v2)
# Supports: Void Linux | Slackware (incl. Salix) | FreeBSD (incl. GhostBSD)
# Sources : dotfiles-bsd-main + spectrwm-bsd-main
#           (folders, the .zip files, or cloned fresh from GitLab)
#
# What changed from v1:
#   • Mirrors BOTH repos file-for-file instead of a hand-picked list, so every
#     config shastenm ships lands exactly where it lives on his machine.
#   • Fixes the bugs that stop his configs working off FreeBSD (bar script,
#     chinese_chars shebang, rdmenu path, conky toggle path, tmux switcher).
#   • Pulls his dmenu-solarized build, sm-* helper scripts and wallpapers.
#   • Installs the exact fonts every config asks for.
#   • One timestamped backup folder instead of .bak files everywhere.
#   • Safe to start as root (or with sudo): packages are installed as root,
#     the dotfiles go to your normal user. Sourcing it can no longer log you out.
#   • --isos downloads the latest Void / Slackware / FreeBSD ISOs first.
#
# Usage:
#   ./install.sh [options] [dotfiles-bsd-main] [spectrwm-bsd-main]
#   (paths may be folders or the .zip downloads; omitted = auto-detect)
#
# Options:
#   --no-packages     skip OS package installation
#   --no-fonts        skip Nerd Font downloads
#   --offline         no git clones / downloads at all
#   --with-spectrwm   Slackware only: also deploy the spectrwm desktop
#   --nvim <distro>   Neovim distro to activate (default: astro)
#   --user <name>     who gets the dotfiles when started as root
#                     (default: the user who ran sudo/doas, or the only /home user)
#   --isos [dir]      first download + verify the latest Void (glibc), Slackware64
#                     and FreeBSD ISOs, then carry on with the install
#   --isos-only [dir] download the ISOs and stop
#                     (dir default: Proxmox ISO store if present, else ~/Downloads/isos)
#   -y, --yes         don't ask questions
#   -h, --help        show this help
# =============================================================================

# If someone sources this (". install.sh"), 'set -e' and 'exit' would run in
# THEIR shell and log them out on the first error. Re-run it as a child instead.
if (return 0 2>/dev/null); then
    echo "install.sh was sourced — running it as a separate process instead."
    bash "${BASH_SOURCE[0]}" "$@"
    return $?
fi

set -euo pipefail

# =============================================================================
# COLORS / HELPERS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# Portable in-place sed (GNU + BSD)
sed_i() {
    local expr="$1" file="$2"
    [ -f "$file" ] || return 0
    sed -e "$expr" "$file" > "$file.sm-tmp" && cat "$file.sm-tmp" > "$file" && rm -f "$file.sm-tmp"
}

# =============================================================================
# ARGUMENTS
# =============================================================================
DO_PACKAGES=1; DO_FONTS=1; OFFLINE=0; ASSUME_YES=0; WITH_SPECTRWM_SLACK=0
NVIM_DISTRO="astro"
POSITIONAL=()
TARGET_USER=""; USER_PHASE=0; ISO_MODE=0; ISO_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-packages)   DO_PACKAGES=0 ;;
        --no-fonts)      DO_FONTS=0 ;;
        --offline)       OFFLINE=1 ;;
        --with-spectrwm) WITH_SPECTRWM_SLACK=1 ;;
        --nvim)          shift; NVIM_DISTRO="${1:?--nvim needs a distro name}" ;;
        -y|--yes)        ASSUME_YES=1 ;;
        --user)          shift; TARGET_USER="${1:?--user needs a user name}" ;;
        --user-phase)    USER_PHASE=1 ;;                       # internal
        --isos|--isos-only)
            [ "$1" = "--isos" ] && ISO_MODE=1 || ISO_MODE=2
            if [ $# -gt 1 ] && [[ "$2" != -* ]] && [[ "$2" != *.zip ]] && ! [ -e "$2/spectrwm.conf" ] && ! [ -e "$2/.bashrc" ]; then
                shift; ISO_DIR="$1"
            fi ;;
        -h|--help)       sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)              err "Unknown option: $1 (see --help)" ;;
        *)               POSITIONAL+=("$1") ;;
    esac
    shift
done
ARG_DOTFILES="${POSITIONAL[0]:-}"
ARG_SPECTRWM="${POSITIONAL[1]:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.shastenm-backup-$TS"
WORK_DIR="$HOME/.local/share/shastenm-build"
SPECTRWM_DEST="$HOME/.config/spectrwm"

# Upstream repos (overridable via environment)
REPO_DOTFILES_BSD="${REPO_DOTFILES_BSD:-https://gitlab.com/shastenm/dotfiles-bsd.git}"
REPO_SPECTRWM_BSD="${REPO_SPECTRWM_BSD:-https://gitlab.com/shastenm/spectrwm-bsd.git}"
REPO_DMENU="${REPO_DMENU:-https://gitlab.com/shastenm/dmenu-solarized.git}"
REPO_BIN="${REPO_BIN:-https://gitlab.com/cuauhtlios/bin.git}"
REPO_WALLPAPERS=("https://gitlab.com/shastenm/wallpaper.git" "https://gitlab.com/smothermonethan2002/wallpaper.git")
REPO_DZEN="https://github.com/robm/dzen.git"
REPO_SPECTRWM_SRC="https://github.com/conformal/spectrwm.git"
NERD_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"

BACKED_UP=0; INSTALLED=0; UNCHANGED=0
MISSING_PKGS=()

# =============================================================================
# DETECT DISTRO
# =============================================================================
detect_distro() {
    local id="unknown"
    if [ -f /etc/os-release ]; then
        id="$(. /etc/os-release; echo "${ID:-unknown}")"
    fi
    [ "$(uname -s)" = "FreeBSD" ] && [ "$id" = "unknown" ] && id="freebsd"

    case "$id" in
        void)                 DISTRO="void" ;;
        slackware|salix)      DISTRO="slackware" ;;
        freebsd|ghostbsd)     DISTRO="freebsd" ;;
        *)
            if [ "$(uname -s)" = "FreeBSD" ]; then DISTRO="freebsd"
            else err "Unsupported OS: $id\nThis script supports Void Linux, Slackware and FreeBSD."
            fi ;;
    esac

    # spectrwm desktop: Void + FreeBSD always; Slackware keeps stock XFCE unless asked
    WANT_WM=1
    if [ "$DISTRO" = "slackware" ] && [ "$WITH_SPECTRWM_SLACK" -eq 0 ]; then
        WANT_WM=0
    fi
    ok "Detected: $DISTRO  (spectrwm desktop: $([ $WANT_WM -eq 1 ] && echo yes || echo 'no — CLI rice only, use --with-spectrwm'))"
}

pick_sudo() {
    [ "$DISTRO" = "freebsd" ] && MAKE="gmake"
    if have sudo; then SUDO="sudo"
    elif have doas; then SUDO="doas"
    else SUDO=""; fi
}

# =============================================================================
# PACKAGES
# =============================================================================
# Only packages the repo actually exists for get installed; the rest are
# reported at the end instead of breaking the whole transaction.

VOID_PKGS=(
    # base
    bash git curl wget unzip fontconfig xorg-minimal xinit xset xsetroot xrdb setxkbmap
    # desktop (spectrwm.conf / autostart.sh / sxhkdrc / dzen2 bar)
    spectrwm dzen2 picom nitrogen sxhkd conky dmenu rofi clipmenu xclip xdotool
    # terminals (kitty is the default; wezterm + ghostty configs are shipped too)
    kitty wezterm ghostty
    # shell / CLI
    tmux neovim fzf bat eza starship fastfetch zk zathura zathura-pdf-mupdf
    ripgrep fd lazygit nodejs python3 fuse-sshfs timeshift
    # fonts
    noto-fonts-cjk noto-fonts-emoji dejavu-fonts-ttf
    # build deps for dmenu-solarized / dzen2 / spectrwm fallback
    gcc make pkg-config libX11-devel libXft-devel libXinerama-devel libXpm-devel
    freetype-devel fontconfig-devel libXrandr-devel libXcursor-devel libbsd-devel
    xcb-util-devel xcb-util-wm-devel xcb-util-keysyms-devel libXt-devel
)

FREEBSD_PKGS=(
    bash git curl wget unzip gmake pkgconf xorg
    spectrwm dzen2 picom nitrogen sxhkd conky dmenu rofi clipmenu xclip xdotool
    kitty wezterm ghostty
    tmux neovim fzf bat eza starship fastfetch zk zathura zathura-pdf-mupdf
    ripgrep fd-find lazygit node python3 fusefs-sshfs
    noto-sc noto-emoji dejavu joypixels
    libX11 libXft libXinerama freetype2 fontconfig
)

install_pkgs_filtered() {
    # install_pkgs_filtered <query-fn> <install-cmd...> -- pkgs...
    local query="$1"; shift
    local cmd=()
    while [ "$1" != "--" ]; do cmd+=("$1"); shift; done; shift
    local avail=() p
    for p in "$@"; do
        if "$query" "$p"; then avail+=("$p"); else MISSING_PKGS+=("$p"); fi
    done
    info "Installing ${#avail[@]} packages (${#MISSING_PKGS[@]} not in repo)"
    if ! $SUDO "${cmd[@]}" "${avail[@]}"; then
        warn "Bulk install failed — retrying one at a time"
        for p in "${avail[@]}"; do
            $SUDO "${cmd[@]}" "$p" || MISSING_PKGS+=("$p")
        done
    fi
}

q_void()    { xbps-query -R "$1" >/dev/null 2>&1; }
q_freebsd() { [ -n "$(pkg rquery '%n' "$1" 2>/dev/null)" ]; }

install_void() {
    section "Installing packages (xbps)"
    $SUDO xbps-install -Syu xbps || true
    $SUDO xbps-install -Syu || warn "System update failed — continuing"
    install_pkgs_filtered q_void xbps-install -y -- "${VOID_PKGS[@]}"
}

install_freebsd() {
    section "Installing packages (pkg)"
    $SUDO pkg update
    install_pkgs_filtered q_freebsd pkg install -y -- "${FREEBSD_PKGS[@]}"
}

install_slackware() {
    section "Checking packages (Slackware)"
    warn "Slackware: no automatic package install — checking what's in PATH."
    local want=(git curl tmux nvim fzf bat kitty zathura fastfetch rg starship)
    [ "$WANT_WM" -eq 1 ] && want+=(spectrwm dzen2 picom nitrogen sxhkd conky dmenu rofi clipmenud xclip xdotool)
    local c
    for c in "${want[@]}"; do have "$c" || MISSING_PKGS+=("$c"); done
    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        warn "Not found — install with sbopkg / slackpkg+ (e.g. sudo sbopkg -i <name>):"
        printf '    - %s\n' "${MISSING_PKGS[@]}"
        if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
            read -r -p "Continue dotfiles install anyway? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] || exit 0
        fi
    fi
}

install_starship_fallback() {
    have starship && return 0
    [ "$OFFLINE" -eq 1 ] && { warn "starship missing (offline)"; return 0; }
    local bindir="$HOME/.local/bin"
    [ "$(id -u)" -eq 0 ] && bindir="/usr/local/bin"
    info "starship not packaged here — installing to $bindir"
    mkdir -p "$bindir"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$bindir" \
        || warn "starship install failed — see https://starship.rs"
}

# =============================================================================
# SOURCE TREES
# =============================================================================
# find_root <marker> <repo-name> <explicit-arg> <git-url>  → echoes path
find_root() {
    local marker="$1" name="$2" arg="$3" url="$4" c z

    extract_zip() {
        local zip="$1" dest="$WORK_DIR/src/$name"
        have unzip || err "unzip is needed to read $zip"
        rm -rf "$dest"; mkdir -p "$dest"
        unzip -qo "$zip" -d "$dest"
        local hit; hit="$(find "$dest" -maxdepth 3 -path "*/$marker" -print -quit)"
        [ -n "$hit" ] || return 1
        echo "${hit%/"$marker"}"
    }

    if [ -n "$arg" ]; then
        if [ -d "$arg" ] && [ -e "$arg/$marker" ]; then (cd "$arg" && pwd); return; fi
        if [ -f "$arg" ] && [[ "$arg" == *.zip ]]; then extract_zip "$arg" && return; fi
        err "$arg doesn't look like $name (no $marker inside)"
    fi

    for c in "$SCRIPT_DIR" "$SCRIPT_DIR/$name" "$PWD/$name" "$HOME/$name" \
             "$HOME/dotfiles/$name" "$HOME/Downloads/$name" \
             "$TARGET_HOME/$name" "$TARGET_HOME/dotfiles/$name" "$TARGET_HOME/Downloads/$name" "$PWD"; do
        if [ -e "$c/$marker" ]; then (cd "$c" && pwd); return; fi
    done

    for z in "$SCRIPT_DIR"/*"$name"*.zip "$PWD"/*"$name"*.zip "$HOME/Downloads"/*"$name"*.zip \
             "$TARGET_HOME"/*"$name"*.zip "$TARGET_HOME/Downloads"/*"$name"*.zip; do
        [ -f "$z" ] && extract_zip "$z" && return
    done

    if [ "$OFFLINE" -eq 0 ] && have git; then
        local dest="$WORK_DIR/src/$name"
        rm -rf "$dest"
        git clone --depth=1 "$url" "$dest" >&2 && [ -e "$dest/$marker" ] && { echo "$dest"; return; }
    fi
    err "Cannot find $name.\nUsage: $0 <path-to-dotfiles-bsd-main> <path-to-spectrwm-bsd-main>"
}

# =============================================================================
# MIRROR ENGINE
# =============================================================================
backup_path() {
    local p="$1"
    [ -e "$p" ] || [ -L "$p" ] || return 0
    local rel="${p#"$HOME"/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    mv "$p" "$BACKUP_DIR/$rel"
    BACKED_UP=$((BACKED_UP + 1))
}

# Things in the repos that are junk, machine-specific, or wrong for this OS
skip_dotfile() {
    case "$1" in
        .git|.git/*|.gitignore) return 0 ;;
        README.md|install-shastenm.sh) return 0 ;;        # repo meta
        *.bak|*.bak/*|*.sm-tmp) return 0 ;;              # his old backups
        .config/go|.config/go/*) return 0 ;;             # Go telemetry + upload token
        .zk/notebook.db) return 0 ;;                     # zk rebuilds its index
        */startup.log) return 0 ;;
        .tmux/plugins/*) return 0 ;;                     # TPM is cloned fresh
        .bash/debian.sh) return 0 ;;                     # apt aliases — not a target OS
        .bash/void.sh)    [ "$DISTRO" != "void" ];    return ;;
        .bash/freebsd.sh) [ "$DISTRO" != "freebsd" ]; return ;;
    esac
    return 1
}

skip_spectrwm() {
    case "$1" in
        .git|.git/*|.gitignore|*.bak|*.bak/*|README.md) return 0 ;;
    esac
    return 1
}

# stage_tree <src> <name> → echoes a scratch copy we can patch, so re-runs
# compare against the patched result and don't re-backup every time
stage_tree() {
    local dest="$WORK_DIR/stage/$2"
    rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
    cp -RPp "$1" "$dest"
    echo "$dest"
}

# mirror_tree <src> <dst> <skip-fn>
mirror_tree() {
    local src="$1" dst="$2" skip="$3" rel s d tgt
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        "$skip" "$rel" && continue
        s="$src/$rel"; d="$dst/$rel"
        mkdir -p "$(dirname "$d")"
        if [ -L "$s" ]; then
            tgt="$(readlink "$s")"
            # his links point at /home/cyborg/... — re-root them on this $HOME
            case "$tgt" in /home/*/*) tgt="$HOME/${tgt#/home/*/}" ;; esac
            if [ -L "$d" ] && [ "$(readlink "$d")" = "$tgt" ]; then UNCHANGED=$((UNCHANGED+1)); continue; fi
            backup_path "$d"
            ln -s "$tgt" "$d"
        else
            if [ -f "$d" ] && ! [ -L "$d" ] && cmp -s "$s" "$d"; then UNCHANGED=$((UNCHANGED+1)); continue; fi
            backup_path "$d"
            cp -p "$s" "$d"
        fi
        INSTALLED=$((INSTALLED + 1))
    done < <(cd "$src" && find . -mindepth 1 \( -type f -o -type l \) -print0)
}

# =============================================================================
# DOTFILES (dotfiles-bsd-main → $HOME)
# =============================================================================
deploy_dotfiles() {
    section "Dotfiles  ($DOTFILES_ROOT → ~)"
    local S; S="$(stage_tree "$DOTFILES_ROOT" dotfiles)"

    # --- user-specific fixes (his username is 'shasten') ---------------------
    sed_i 's/chown -R shasten:shasten/chown -R $USER:$USER/' "$S/.bash/shortcuts.sh"

    # --- Linux fixes: his shortcuts.sh is written for FreeBSD -----------------
    if [ "$DISTRO" != "freebsd" ]; then
        sed_i 's|chsh -s /usr/local/bin/bash|chsh -s /bin/bash|; s|chsh -s /usr/local/bin/zsh|chsh -s /bin/zsh|' "$S/.bash/shortcuts.sh"
        sed_i 's|alias hw="pciconf -lv"|alias hw="lspci -v"|; s|alias hwinfo="sysctl hw"|alias hwinfo="lscpu"|' "$S/.bash/shortcuts.sh"
    fi
    if [ "$DISTRO" = "void" ]; then
        sed_i 's|alias SS="sudo service"|alias SS="sudo sv"|' "$S/.bash/shortcuts.sh"
        sed_i 's|alias update-boot=.*|alias update-boot="sudo update-grub"|' "$S/.bash/shortcuts.sh"
    fi

    # --- tmux session switcher: format string was expanded by accident -------
    sed_i "s|tmux list-sessions -F '[^']*'|tmux list-sessions -F '#{session_activity} #{session_name}'|" \
        "$S/.tmux/session-switch.sh"

    mirror_tree "$S" "$HOME" skip_dotfile
    ok "bash, tmux, starship (+themes), kitty, ghostty, wezterm, zathura, fastfetch, rofi, waybar, coc, zk, nvim-configs, ~/.local/bin"

    # --- his aliases use 'exa'; Void/FreeBSD now ship 'eza' ------------------
    if ! have exa && have eza; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$(command -v eza)" "$HOME/.local/bin/exa"
        ok "exa → eza shim in ~/.local/bin (his ls/la/ll/lt aliases need it)"
    fi

    # executables
    chmod +x "$HOME/.tmux/session-switch.sh" "$HOME/.local/bin/osc52copy" 2>/dev/null || true
    chmod +x "$HOME/.config/nvim-configs/"{sm-nvim-switcher,sm-sessionizer,sm-devjump,neovim} 2>/dev/null || true

    # cargo env stub (sourced by .bashrc)
    mkdir -p "$HOME/.cargo"; [ -f "$HOME/.cargo/env" ] || : > "$HOME/.cargo/env"
}

# =============================================================================
# SPECTRWM (spectrwm-bsd-main → ~/.config/spectrwm)
# =============================================================================
write_linux_baraction() {
    # Same layout, glyphs and colours as his FreeBSD baraction.sh,
    # reading /proc instead of sysctl/top (which don't exist on Linux).
    cat > "$1/baraction.sh" <<'EOF'
#!/bin/sh
# Linux port of shastenm's baraction.sh (original kept as baraction.freebsd.sh)

get_center_content() {
    if [ -x ~/.config/spectrwm/chinese_chars ]; then
        ~/.config/spectrwm/chinese_chars
    else
        echo ""
    fi
}

get_mem_usage() {
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
         END {printf "%.1fG/%.1fG", a/1048576, t/1048576}' /proc/meminfo
}

read_cpu() { awk '/^cpu / {idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; print tot, idle}' /proc/stat; }

set -- $(read_cpu); prev_total=$1; prev_idle=$2

while :; do
    set -- $(read_cpu); total=$1; idle=$2
    dt=$((total - prev_total)); di=$((idle - prev_idle))
    if [ "$dt" -gt 0 ]; then cpu_usage=$(( (100 * (dt - di)) / dt )); else cpu_usage=0; fi
    prev_total=$total; prev_idle=$idle

    center_content=$(get_center_content)
    mem_info=$(get_mem_usage)
    disk_info=$(df -h / | awk 'NR==2 {print $3 " / " $2}')
    datetime=$(date "+%a %b %d [%R]")
    right_content="+@fg=5;  核 $cpu_usage    +@fg=4; 碟 $disk_info   +@fg=2; 忆 $mem_info     +@fg=1; 历 $datetime"

    echo "+|C$center_content +|R$right_content"
    sleep 3
done
EOF
}

deploy_spectrwm() {
    section "spectrwm  ($SPECTRWM_ROOT → ~/.config/spectrwm)"
    mkdir -p "$SPECTRWM_DEST"
    local S; S="$(stage_tree "$SPECTRWM_ROOT" spectrwm)"

    if [ "$DISTRO" != "freebsd" ]; then
        cp -p "$S/baraction.sh" "$S/baraction.freebsd.sh"
        write_linux_baraction "$S"
        # chinese_chars points at FreeBSD's /usr/local/bin/bash
        sed_i '1s|^#!.*|#!/usr/bin/env bash|' "$S/chinese_chars"
        ok "Linux fixes: baraction.sh reads /proc, chinese_chars shebang"
    fi

    # toggle-sxhkd-keys still pointed at his old pekwm folder
    sed_i 's|~/.pekwm/conky/sxhkd-keys.conf|~/.config/spectrwm/conky/sxhkd-keys.conf|' \
        "$S/scripts/toggle-sxhkd-keys"
    # rdmenu still pointed at his old bspwm folder
    sed_i 's|\$HOME/.config/bspwm/panel/menu/submenu.yaml|$HOME/.config/spectrwm/dzen2/menu/submenu.yaml|' \
        "$S/dzen2/menu/rdmenu"

    mirror_tree "$S" "$SPECTRWM_DEST" skip_spectrwm
    ok "spectrwm.conf, autostart.sh, baraction.sh, sxhkdrc, chinese_chars, conky, dzen2 (bar/icons/menu), scripts"

    chmod +x "$SPECTRWM_DEST"/{autostart.sh,baraction.sh,chinese_chars} \
             "$SPECTRWM_DEST"/scripts/* "$SPECTRWM_DEST"/dzen2/bar \
             "$SPECTRWM_DEST"/dzen2/scripts/* "$SPECTRWM_DEST"/dzen2/menu/rdmenu 2>/dev/null || true

    # sxhkdrc + dzen2 bar call 'rdmenu' by name
    mkdir -p "$HOME/.local/bin"
    ln -sf "$SPECTRWM_DEST/dzen2/menu/rdmenu" "$HOME/.local/bin/rdmenu"
    ok "rdmenu linked into ~/.local/bin"
}

# =============================================================================
# EXTRA REPOS: dmenu-solarized, sm-* scripts, dzen2/spectrwm source fallback
# =============================================================================
clone_or_pull() {
    local url="$1" dest="$2"
    if [ -d "$dest/.git" ]; then git -C "$dest" pull --ff-only -q || true
    else rm -rf "$dest"; git clone --depth=1 -q "$url" "$dest"; fi
}

MAKE="make"
x11_make_flags() {
    if [ "$DISTRO" = "freebsd" ]; then
        echo "X11INC=/usr/local/include X11LIB=/usr/local/lib FREETYPEINC=/usr/local/include/freetype2"
    fi
}

build_dmenu_solarized() {
    section "dmenu-solarized (his dmenu build)"
    local d="$WORK_DIR/dmenu-solarized" flags
    clone_or_pull "$REPO_DMENU" "$d" || { warn "Couldn't clone dmenu-solarized — keeping stock dmenu"; return 0; }
    flags="$(x11_make_flags)"
    # shellcheck disable=SC2086
    if (cd "$d" && $MAKE $flags && $SUDO $MAKE $flags PREFIX=/usr/local install); then
        ok "dmenu-solarized installed to /usr/local/bin"
    else
        warn "dmenu-solarized build failed — stock dmenu stays in place"
    fi
}

build_dzen2_if_missing() {
    have dzen2 && return 0
    section "dzen2 (not packaged — building)"
    local d="$WORK_DIR/dzen" flags
    clone_or_pull "$REPO_DZEN" "$d" || { warn "Couldn't clone dzen2 — bottom panel won't start"; return 0; }
    flags="$(x11_make_flags)"
    # shellcheck disable=SC2086
    (cd "$d" && $MAKE $flags && $SUDO $MAKE $flags PREFIX=/usr/local install) \
        && ok "dzen2 installed" || warn "dzen2 build failed — bottom panel won't start"
}

build_spectrwm_if_missing() {
    have spectrwm && return 0
    [ "$DISTRO" = "freebsd" ] && { warn "spectrwm missing — sudo pkg install spectrwm"; return 0; }
    section "spectrwm (not packaged — building)"
    local d="$WORK_DIR/spectrwm"
    clone_or_pull "$REPO_SPECTRWM_SRC" "$d" || { warn "Couldn't clone spectrwm"; return 0; }
    (cd "$d/linux" && make && $SUDO make install) \
        && ok "spectrwm installed" || warn "spectrwm build failed (needs libbsd-devel + X11 headers)"
}

install_sm_scripts() {
    section "sm-* helper scripts (~/.local/bin)"
    local d="$WORK_DIR/bin" f
    if clone_or_pull "$REPO_BIN" "$d"; then
        while IFS= read -r -d '' f; do
            local name="${f#"$d"/}"
            case "$name" in .git*|README*|LICENSE*) continue ;; esac
            mkdir -p "$HOME/.local/bin/$(dirname "$name")"
            # never clobber what dotfiles-bsd just installed
            [ -e "$HOME/.local/bin/$name" ] || cp -p "$f" "$HOME/.local/bin/$name"
        done < <(find "$d" -type f -not -path '*/.git/*' -print0)
        find "$HOME/.local/bin" -type f -exec chmod +x {} + 2>/dev/null || true
        ok "Copied $REPO_BIN into ~/.local/bin"
    else
        warn "Couldn't clone $REPO_BIN"
    fi
}

check_sm_scripts() {
    local missing=() s
    for s in sm-pdf sm-man sm-dots sm-dmscr; do
        have "$s" || [ -x "$HOME/.local/bin/$s" ] || missing+=("$s")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Called by his sxhkdrc / dzen2 menus but not found: ${missing[*]}"
        warn "  (they live in his dmenu-scripts repo — drop them in ~/.local/bin)"
    fi
}

# =============================================================================
# TMUX / NEOVIM / ZK / WALLPAPER / X
# =============================================================================
setup_tmux() {
    section "tmux plugins (TPM)"
    [ "$OFFLINE" -eq 1 ] && { warn "offline — TPM will self-clone on first tmux start"; return 0; }
    clone_or_pull https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" || { warn "TPM clone failed"; return 0; }
    if have tmux; then
        "$HOME/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1 \
            && ok "tmux-open, pain-control, sidebar, yank, vim-tmux-navigator installed" \
            || warn "Plugin install deferred — open tmux and press Ctrl+a then I"
    fi
}

setup_neovim() {
    section "Neovim switcher (active: $NVIM_DISTRO)"
    local nv="$HOME/.config/nvim" cfgs="$HOME/.config/nvim-configs"
    [ -d "$cfgs/$NVIM_DISTRO" ] || { warn "No '$NVIM_DISTRO' in nvim-configs — available: $(ls "$cfgs" | tr '\n' ' ')"; return 0; }

    if [ -L "$nv" ] && [[ "$(readlink "$nv")" == "$cfgs/"* ]]; then
        ok "Keeping your current switcher choice: $(basename "$(readlink "$nv")")"
    else
        if [ -e "$nv" ] || [ -L "$nv" ]; then
            backup_path "$nv"
            backup_path "$HOME/.local/share/nvim"
            backup_path "$HOME/.local/state/nvim"
            backup_path "$HOME/.cache/nvim"
        fi
        sh "$cfgs/sm-nvim-switcher" "$NVIM_DISTRO" >/dev/null
        ok "\$HOME/.config/nvim → nvim-configs/$NVIM_DISTRO   (switch-astro / switch-lazy / … aliases)"
    fi

    if have nvim && [ "$OFFLINE" -eq 0 ]; then
        info "Restoring plugins to his lazy-lock.json versions (first run can take a few minutes)…"
        local t=""; have timeout && t="timeout 900"
        $t nvim --headless "+Lazy! restore" +qa >/dev/null 2>&1 \
            && ok "Neovim plugins pinned to his versions" \
            || warn "Headless plugin restore didn't finish — just open nvim and let Lazy finish"
    fi
}

setup_zk() {
    # his .zk/config.toml + zk aliases expect these
    mkdir -p "$HOME/Documents/second-brain" "$HOME/srv/second-brain"
}

setup_wallpaper() {
    [ "$WANT_WM" -eq 1 ] || return 0
    section "Wallpapers (nitrogen)"
    local dest="$HOME/Pictures/wallpaper" url got=0
    if [ "$OFFLINE" -eq 0 ]; then
        for url in "${REPO_WALLPAPERS[@]}"; do
            if clone_or_pull "$url" "$dest" 2>/dev/null; then got=1; break; fi
        done
    fi
    [ -d "$dest" ] && got=1
    [ "$got" -eq 1 ] || { warn "No wallpaper repo reachable — run: nitrogen ~/Pictures"; return 0; }
    ok "Wallpapers in $dest"

    local ncfg="$HOME/.config/nitrogen"
    mkdir -p "$ncfg"
    if [ ! -f "$ncfg/nitrogen.cfg" ]; then
        printf '[nitrogen]\nview=icon\nrecurse=true\nsort=alpha\nicon_caps=false\ndirs=%s;\n' "$dest" > "$ncfg/nitrogen.cfg"
    fi
    if [ ! -f "$ncfg/bg-saved.cfg" ]; then
        local first
        first="$(find "$dest" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort | head -n1)"
        if [ -n "$first" ]; then
            printf '[xin_-1]\nfile=%s\nmode=5\nbgcolor=#000000\n' "$first" > "$ncfg/bg-saved.cfg"
            ok "nitrogen --restore will load $(basename "$first")  (pick another: nitrogen)"
        fi
    fi
}

setup_xinit() {
    [ "$WANT_WM" -eq 1 ] || return 0
    section "X session"
    # spectrwm.conf already runs autostart.sh via 'autorun = ws[1]:…', so
    # we only exec spectrwm here (running autostart twice doubles picom/conky).
    local f
    for f in "$HOME/.xinitrc" "$HOME/.xsession"; do
        if [ ! -f "$f" ]; then
            printf '#!/bin/sh\n# Generated by shastenm install.sh\n[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"\nexec spectrwm\n' > "$f"
            chmod +x "$f"
            ok "Created $(basename "$f") → exec spectrwm"
        elif ! grep -q spectrwm "$f"; then
            warn "$(basename "$f") exists and doesn't start spectrwm — add: exec spectrwm"
        fi
    done
}

# =============================================================================
# FONTS
# =============================================================================
# Everything his configs name:
#   spectrwm bar : Noto Sans CJK SC, Mononoki Nerd Font, JoyPixels
#   kitty        : MonaspiceNE (Monaspace Nerd Font)
#   wezterm      : JetBrains Mono          zathura : AurulentSansMono Nerd Font
#   conky        : DejaVu Sans / Mono      dzen2   : ubuntu-mono
NERD_FONTS=(Mononoki Monaspace JetBrainsMono AurulentSansMono UbuntuMono)

font_present() { grep -Eqi "$1" <<<"$FONT_LIST"; }

install_fonts() {
    [ "$DO_FONTS" -eq 1 ] && [ "$OFFLINE" -eq 0 ] || return 0
    have fc-list || { warn "fontconfig missing — skipping font install"; return 0; }
    section "Nerd Fonts"
    FONT_LIST="$(fc-list : family 2>/dev/null || true)"
    local fdir="$HOME/.local/share/fonts" f probe added=0
    mkdir -p "$fdir"
    for f in "${NERD_FONTS[@]}"; do
        case "$f" in
            Monaspace)        probe="MonaspiceNe" ;;
            JetBrainsMono)    probe="JetBrainsMono Nerd" ;;
            AurulentSansMono) probe="AurulentSansM" ;;
            UbuntuMono)       probe="UbuntuMono Nerd" ;;
            *)                probe="$f Nerd" ;;
        esac
        if font_present "$probe"; then ok "$f already installed"; continue; fi
        info "Downloading $f Nerd Font…"
        local tmp="$WORK_DIR/fonts/$f.zip"; mkdir -p "$WORK_DIR/fonts"
        if curl -fsSL "$NERD_URL/$f.zip" -o "$tmp" && mkdir -p "$fdir/$f" && unzip -oq "$tmp" -d "$fdir/$f"; then
            ok "$f installed"; added=1
        else
            warn "$f download failed"
        fi
    done
    [ "$added" -eq 1 ] && fc-cache -f "$fdir" >/dev/null
    return 0
}

check_fonts() {
    section "Font check"
    have fc-list || { warn "fc-list not found — can't check fonts"; return 0; }
    FONT_LIST="$(fc-list : family 2>/dev/null || true)"
    local missing=()
    font_present "Noto Sans CJK|Noto Sans SC" || missing+=("Noto Sans CJK SC   — spectrwm bar workspace names (终网开系…)")
    font_present "Mononoki"                    || missing+=("Mononoki Nerd Font — spectrwm bar")
    font_present "JoyPixels"                   || missing+=("JoyPixels          — bar emoji (Noto Color Emoji is used as fallback)")
    font_present "MonaspiceNe"                 || missing+=("MonaspiceNE Nerd   — kitty")
    font_present "JetBrains"                   || missing+=("JetBrains Mono     — wezterm (wezterm also bundles it)")
    font_present "AurulentSansM"               || missing+=("AurulentSansMono   — zathura")
    font_present "DejaVu Sans"                 || missing+=("DejaVu Sans/Mono   — conky key overlays")
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing fonts:"; printf '    - %s\n' "${missing[@]}"
        info "Nerd Fonts: https://www.nerdfonts.com/font-downloads → ~/.local/share/fonts, then fc-cache -fv"
    else
        ok "All fonts his configs reference are installed"
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║        Installation Complete — shastenm rice     ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Files installed: $INSTALLED   unchanged: $UNCHANGED   backed up: $BACKED_UP"
    [ "$BACKED_UP" -gt 0 ] && echo "  Your old files : $BACKUP_DIR"
    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Not available from your package repo (install by hand if you want them):${NC}"
        echo "  ${MISSING_PKGS[*]}"
    fi
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1.  source ~/.bashrc        (or open a new kitty)"
    if [ "$WANT_WM" -eq 1 ]; then
        echo "  2.  startx                  (or pick spectrwm at your login screen)"
        echo "  3.  Change wallpaper:       nitrogen ~/Pictures/wallpaper"
    fi
    [ "$DISTRO" = "freebsd" ] && [ "${SHELL##*/}" != "bash" ] && echo "  •   Make bash your shell:   chsh -s /usr/local/bin/bash"
    echo ""
    echo -e "${YELLOW}Neovim:${NC} active = $NVIM_DISTRO  ·  switch-astro | switch-dev | switch-lazy | switch-kick | switch-nvchad | switch-writing | switch-zeeno | switch-nvim"
    echo -e "${YELLOW}tmux  :${NC} prefix Ctrl+a  ·  sessions via: init conf pl zn sb dot pro (sm-devjump)  ·  ss = sm-sessionizer"
    if [ "$WANT_WM" -eq 1 ]; then
        echo ""
        echo -e "${YELLOW}spectrwm:${NC}"
        echo "  Super+Return        kitty            Super+Shift+Return  dmenu_run"
        echo "  Super+1…0           workspaces 终 网 开 系 文 图 音 影 编 龙"
        echo "  Super+x             close window     Super+q             restart spectrwm"
        echo "  Super+Alt+p         toggle dzen2 bottom panel"
        echo "  Alt+o → c/g/l/p     chrome / gimp / l3afpad / pavucontrol"
        echo "  Alt+m → F12/F11/F10 rdmenu / sm-dots / sm-dmscr      Alt+p → d/m  sm-pdf / sm-man"
    fi
    echo ""
}


# =============================================================================
# ISO DOWNLOADS  (--isos / --isos-only)
# =============================================================================
# Directory listings are read at run time, so you always get the newest
# release; every image is checked against the project's own checksums.
VOID_LIVE="${VOID_LIVE:-https://repo-default.voidlinux.org/live/current}"
SLACK_ISO="${SLACK_ISO:-https://mirrors.slackware.com/slackware/slackware-iso}"
FBSD_ISO="${FBSD_ISO:-https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES}"

fetch_listing() { curl -fsSL "$1/" ; }

sha_check() {
    # sha_check <algo 256|512|md5> <file> <expected>
    local got
    case "$1" in
        md5) got="$( (md5sum "$2" 2>/dev/null || md5 -q "$2") | awk '{print $1}')" ;;
        *)   got="$( (sha${1}sum "$2" 2>/dev/null || shasum -a "$1" "$2") | awk '{print $1}')" ;;
    esac
    [ "$got" = "$3" ]
}

fetch_iso() {
    # fetch_iso <label> <url> <file> <algo> <expected-sum>
    local label="$1" url="$2" file="$3" algo="$4" sum="$5" out="$ISO_DIR/$3"
    if [ -f "$out" ] && sha_check "$algo" "$out" "$sum"; then
        ok "$label: $file already downloaded and verified"; return 0
    fi
    info "$label: downloading $file"
    curl -fL --retry 3 -# -C - -o "$out" "$url" || { rm -f "$out"; curl -fL --retry 3 -# -o "$out" "$url"; } \
        || { warn "$label download failed"; return 1; }
    if ! sha_check "$algo" "$out" "$sum"; then
        warn "$label: checksum mismatch — downloading again from scratch"
        rm -f "$out"
        curl -fL --retry 3 -# -o "$out" "$url" || { warn "$label download failed"; return 1; }
    fi
    if sha_check "$algo" "$out" "$sum"; then ok "$label: $file verified ($algo)"
    else warn "$label: CHECKSUM MISMATCH — deleting $file"; rm -f "$out"; return 1; fi
}

download_isos() {
    section "Downloading OS ISOs"
    have curl || err "curl is needed to download ISOs"
    if [ -z "$ISO_DIR" ]; then
        if [ -d /var/lib/vz/template/iso ] && [ -w /var/lib/vz/template/iso ]; then
            ISO_DIR="/var/lib/vz/template/iso"          # Proxmox local ISO storage
        else
            ISO_DIR="${TARGET_HOME:-$HOME}/Downloads/isos"
        fi
    fi
    mkdir -p "$ISO_DIR"
    info "Saving to $ISO_DIR"
    local failed=0 f sum ver

    # Void — x86_64 glibc base live image (the glibc build he moved to from musl)
    f="$(fetch_listing "$VOID_LIVE" | grep -oE 'void-live-x86_64-[0-9]{8}-base\.iso' | sort -u | tail -n1)"
    sum="$(curl -fsSL "$VOID_LIVE/sha256sum.txt" | grep -F "($f)" | awk '{print $NF}')"
    if [ -n "$f" ] && [ -n "$sum" ]; then fetch_iso "Void" "$VOID_LIVE/$f" "$f" 256 "$sum" || failed=1
    else warn "Void: couldn't read $VOID_LIVE"; failed=1; fi

    # Slackware — newest slackware64-X.Y install DVD
    ver="$(fetch_listing "$SLACK_ISO" | grep -oE 'slackware64-[0-9]+\.[0-9]+-iso' | sort -t- -k2 -V -u | tail -n1)"
    ver="${ver#slackware64-}"; ver="${ver%-iso}"
    if [ -n "$ver" ]; then
        f="slackware64-$ver-install-dvd.iso"
        sum="$(curl -fsSL "$SLACK_ISO/slackware64-$ver-iso/$f.md5" | awk '{print $1}')"
        if [ -n "$sum" ]; then fetch_iso "Slackware $ver" "$SLACK_ISO/slackware64-$ver-iso/$f" "$f" md5 "$sum" || failed=1
        else warn "Slackware: no checksum file"; failed=1; fi
    else warn "Slackware: couldn't read $SLACK_ISO"; failed=1; fi

    # FreeBSD — newest RELEASE, disc1 (full installer, no network needed)
    ver="$(fetch_listing "$FBSD_ISO" | grep -oE '>[0-9]+\.[0-9]+/' | tr -d '>/' | sort -V -u | tail -n1)"
    if [ -n "$ver" ]; then
        f="FreeBSD-$ver-RELEASE-amd64-disc1.iso"
        sum="$(curl -fsSL "$FBSD_ISO/$ver/CHECKSUM.SHA256-FreeBSD-$ver-RELEASE-amd64" | grep -F "($f)" | awk '{print $NF}')"
        if [ -n "$sum" ]; then fetch_iso "FreeBSD $ver" "$FBSD_ISO/$ver/$f" "$f" 256 "$sum" || failed=1
        else warn "FreeBSD: no checksum for $f"; failed=1; fi
    else warn "FreeBSD: couldn't read $FBSD_ISO"; failed=1; fi

    # hand the folder to the real user if it's in their home
    if [ "$(id -u)" -eq 0 ] && [ -n "${TARGET_USER:-}" ] && [ "$TARGET_USER" != root ] \
       && [[ "$ISO_DIR" == "$TARGET_HOME"/* ]]; then
        chown -R "$TARGET_USER" "$ISO_DIR" 2>/dev/null || true
    fi

    [ "$failed" -eq 0 ] && ok "All 3 ISOs ready in $ISO_DIR" || warn "Some ISOs failed — re-run with --isos-only to resume"
    ls -lh "$ISO_DIR"/*.iso 2>/dev/null | awk '{print "    " $5 "  " $NF}' || true
}

# =============================================================================
# ROOT HANDLING
# =============================================================================
# Started as root: install packages/builds here, then hand the dotfiles part
# to the real user so nothing in their home ends up owned by root.
pick_target_user() {
    if [ -n "$TARGET_USER" ]; then :
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then TARGET_USER="$SUDO_USER"
    elif [ -n "${DOAS_USER:-}" ] && [ "$DOAS_USER" != root ]; then TARGET_USER="$DOAS_USER"
    else
        local l; l="$(logname 2>/dev/null || true)"
        if [ -n "$l" ] && [ "$l" != root ]; then TARGET_USER="$l"
        else
            local users=() d u
            for d in /home/* /usr/home/*; do
                [ -d "$d" ] || continue
                u="$(basename "$d")"
                id "$u" >/dev/null 2>&1 && users+=("$u")
            done
            if [ ${#users[@]} -eq 1 ]; then
                TARGET_USER="${users[0]}"
            elif [ ${#users[@]} -gt 1 ] && [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
                echo "Who should get the dotfiles?"
                select u in "${users[@]}" root; do [ -n "$u" ] && { TARGET_USER="$u"; break; }; done
            else
                err "Started as root and can't tell which user the dotfiles are for.\n      Re-run with:  ./install.sh --user <yourname>   (or --user root)"
            fi
        fi
    fi
    id "$TARGET_USER" >/dev/null 2>&1 || err "User '$TARGET_USER' doesn't exist"
    TARGET_HOME="$(eval echo "~$TARGET_USER")"
    [ -d "$TARGET_HOME" ] || err "Home folder for $TARGET_USER not found ($TARGET_HOME)"
}

hand_off_to_user() {
    section "Switching to $TARGET_USER for the dotfiles"
    # copy the script + sources somewhere the user can read (/root isn't)
    local tmp; tmp="$(mktemp -d /tmp/shastenm-install.XXXXXX)"
    cp "${BASH_SOURCE[0]}" "$tmp/install.sh"
    local args=(--user-phase --no-packages)
    [ "$DO_FONTS" -eq 0 ]            && args+=(--no-fonts)
    [ "$OFFLINE" -eq 1 ]             && args+=(--offline)
    [ "$WITH_SPECTRWM_SLACK" -eq 1 ] && args+=(--with-spectrwm)
    [ "$ASSUME_YES" -eq 1 ]          && args+=(--yes)
    args+=(--nvim "$NVIM_DISTRO")
    cp -RPp "$DOTFILES_ROOT" "$tmp/dotfiles-bsd-main"; args+=("$tmp/dotfiles-bsd-main")
    if [ "$WANT_WM" -eq 1 ]; then cp -RPp "$SPECTRWM_ROOT" "$tmp/spectrwm-bsd-main"; args+=("$tmp/spectrwm-bsd-main"); fi
    chmod -R a+rX "$tmp"

    local q="" a
    for a in "${args[@]}"; do q+=" $(printf '%q' "$a")"; done
    local rc=0
    su - "$TARGET_USER" -c "bash $tmp/install.sh$q" || rc=$?
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || err "The $TARGET_USER part stopped with an error (code $rc) — see above. You're still logged in; fix it and re-run."
    exit 0
}

# =============================================================================
# MAIN
# =============================================================================
echo -e "${BOLD}${BLUE}"
echo "  ░██████╗██╗░░██╗░█████╗░░██████╗████████╗███████╗███╗░░██╗███╗░░░███╗"
echo "  ██╔════╝██║░░██║██╔══██╗██╔════╝╚══██╔══╝██╔════╝████╗░██║████╗░████║"
echo "  ╚█████╗░███████║███████║╚█████╗░░░░██║░░░█████╗░░██╔██╗██║██╔████╔██║"
echo "  ░╚═══██╗██╔══██║██╔══██║░╚═══██╗░░░██║░░░██╔══╝░░██║╚████║██║╚██╔╝██║"
echo "  ██████╔╝██║░░██║██║░░██║██████╔╝░░░██║░░░███████╗██║░╚███║██║░╚═╝░██║"
echo "  ╚═════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═════╝░░░╚═╝░░░╚══════╝╚═╝░░╚══╝╚═╝░░░░░╚═╝"
echo -e "${NC}"
echo -e "${CYAN}  Linux Dev Labs — Dotfiles Install${NC}"
echo -e "${CYAN}  Void | Slackware | FreeBSD${NC}"
echo ""

TARGET_HOME="$HOME"
AS_ROOT=0; [ "$(id -u)" -eq 0 ] && AS_ROOT=1
if [ "$AS_ROOT" -eq 1 ] && [ "$USER_PHASE" -eq 0 ]; then
    pick_target_user
    if [ "$TARGET_USER" = root ]; then          # sudo may have kept another user's $HOME
        HOME="$TARGET_HOME"; BACKUP_DIR="$HOME/.shastenm-backup-$TS"
        WORK_DIR="$HOME/.local/share/shastenm-build"; SPECTRWM_DEST="$HOME/.config/spectrwm"
    fi
    info "Started as root — packages install here, dotfiles go to: $TARGET_USER ($TARGET_HOME)"
fi

if [ "$ISO_MODE" -ne 0 ] && [ "$USER_PHASE" -eq 0 ]; then
    download_isos
    [ "$ISO_MODE" -eq 2 ] && exit 0
fi

detect_distro
pick_sudo
[ "$AS_ROOT" -eq 1 ] && SUDO=""            # already root — no sudo/doas needed
CAN_ROOT=0; { [ "$AS_ROOT" -eq 1 ] || [ -n "$SUDO" ]; } && CAN_ROOT=1
mkdir -p "$WORK_DIR"

if [ "$DO_PACKAGES" -eq 1 ]; then
    [ "$CAN_ROOT" -eq 1 ] || err "Neither sudo nor doas found — run this as root (su -) or re-run with --no-packages"
    case "$DISTRO" in
        void)      install_void ;;
        slackware) install_slackware ;;
        freebsd)   install_freebsd ;;
    esac
fi
install_starship_fallback
[ "$OFFLINE" -eq 1 ] || have git || err "git is required — install it and re-run."

DOTFILES_ROOT="$(find_root ".config/nvim-configs" "dotfiles-bsd-main" "$ARG_DOTFILES" "$REPO_DOTFILES_BSD")"
info "Dotfiles root : $DOTFILES_ROOT"
if [ "$WANT_WM" -eq 1 ]; then
    SPECTRWM_ROOT="$(find_root "spectrwm.conf" "spectrwm-bsd-main" "$ARG_SPECTRWM" "$REPO_SPECTRWM_BSD")"
    info "Spectrwm root : $SPECTRWM_ROOT"
fi

if [ "$WANT_WM" -eq 1 ] && [ "$OFFLINE" -eq 0 ] && [ "$CAN_ROOT" -eq 1 ] && [ "$USER_PHASE" -eq 0 ]; then
    build_spectrwm_if_missing
    build_dzen2_if_missing
    build_dmenu_solarized
fi

# root → do the rest as the real user (unless they asked for root's own home)
if [ "$AS_ROOT" -eq 1 ] && [ "$USER_PHASE" -eq 0 ] && [ "$TARGET_USER" != root ]; then
    hand_off_to_user
fi

deploy_dotfiles
[ "$WANT_WM" -eq 1 ] && deploy_spectrwm
[ "$OFFLINE" -eq 0 ] && install_sm_scripts
[ "$WANT_WM" -eq 1 ] && check_sm_scripts
setup_tmux
setup_neovim
setup_zk
setup_wallpaper
setup_xinit
install_fonts
check_fonts
print_summary
