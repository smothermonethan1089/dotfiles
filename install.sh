#!/usr/bin/env bash
# --- If this was piped in ("curl ... | bash", "bash < install.sh") there is no
# --- file on disk to copy onto the rice CD or hand to your user, so save the
# --- rest of the script to a real file first and run that instead.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
    _self="$(mktemp /tmp/shastenm-install-XXXXXX)"
    case "${BASH_SOURCE[0]:-}" in
        /dev/fd/*|/proc/*) { echo '#!/usr/bin/env bash'; cat "${BASH_SOURCE[0]}"; } > "$_self" ;;  # bash <(curl ...)
        *)                 { echo '#!/usr/bin/env bash'; cat; } > "$_self" ;;                     # curl ... | bash
    esac
    chmod 755 "$_self"
    if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then exec bash "$_self" "$@" </dev/tty
    else exec bash "$_self" "$@" </dev/null; fi
fi
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
#   • PROXMOX: run it on the Proxmox host (web shell or SSH, as root) and it
#     builds 3 fully installed VMs with NO keyboard input — login ethan / 1234
#     (root / 1234) — each with the shastenm rice already on it:
#       void-shastenm       Void's own autoinstaller (live ISO, root=vai auto)
#       slackware-shastenm  Slackware's own installer + installpkg, scripted
#       freebsd-shastenm    FreeBSD's own bsdinstall, run unattended
#     Every VM: OS installs → reboots → dotfiles install by themselves → reboots.
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
#   --dmenu-scripts <dir|zip>  his dmenu_scripts repo (sm-pdf, sm-dots, …);
#                     auto-found next to the script / in ~/Downloads, or cloned
#   --user <name>     who gets the dotfiles when started as root
#                     (default: the user who ran sudo/doas, or the only /home user)
#   --isos [dir]      first download + verify the latest Void (glibc), Slackware64
#                     and FreeBSD ISOs, then carry on with the install
#   --isos-only [dir] download the ISOs and stop
#                     (dir default: Proxmox ISO store if present, else ~/Downloads/isos)
#   Proxmox only:
#   --storage <id>    disk storage for the VMs (default: local-lvm/local-zfs/first)
#   --iso-storage <id> ISO storage (default: local)
#   --bridge <vmbr>   network bridge (default: first vmbr, usually vmbr0)
#   --vm-user <name>  login created in the VMs (default: ethan)
#   --vm-pass <pass>  password for it and root (default: 1234)
#   --rebuild         destroy the 3 shastenm VMs first and build them again
#   --no-vms          only download ISOs + build the rice CD
#   --no-start        create the VMs but don't start them
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
TARGET_USER=""; USER_PHASE=0; ISO_MODE=0; ISO_DIR=""; ARG_DMENU_SCRIPTS=""; DMENU_SCRIPTS_ROOT=""
PVE_STORAGE=""; PVE_ISO_STORAGE=""; PVE_BRIDGE=""; PVE_VMS=1; PVE_START=1
VM_USER="ethan"; VM_PASS="1234"; PVE_REBUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-packages)   DO_PACKAGES=0 ;;
        --no-fonts)      DO_FONTS=0 ;;
        --offline)       OFFLINE=1 ;;
        --with-spectrwm) WITH_SPECTRWM_SLACK=1 ;;
        --nvim)          shift; NVIM_DISTRO="${1:?--nvim needs a distro name}" ;;
        --dmenu-scripts) shift; ARG_DMENU_SCRIPTS="${1:?--dmenu-scripts needs a path}" ;;
        -y|--yes)        ASSUME_YES=1 ;;
        --user)          shift; TARGET_USER="${1:?--user needs a user name}" ;;
        --user-phase)    USER_PHASE=1 ;;                       # internal
        --storage)       shift; PVE_STORAGE="${1:?--storage needs a storage id}" ;;
        --iso-storage)   shift; PVE_ISO_STORAGE="${1:?--iso-storage needs a storage id}" ;;
        --bridge)        shift; PVE_BRIDGE="${1:?--bridge needs a bridge name}" ;;
        --no-vms)        PVE_VMS=0 ;;
        --no-start)      PVE_START=0 ;;
        --vm-user)       shift; VM_USER="${1:?--vm-user needs a name}" ;;
        --vm-pass)       shift; VM_PASS="${1:?--vm-pass needs a password}" ;;
        --rebuild)       PVE_REBUILD=1 ;;
        --isos|--isos-only)
            [ "$1" = "--isos" ] && ISO_MODE=1 || ISO_MODE=2
            if [ $# -gt 1 ] && [[ "$2" != -* ]] && [[ "$2" != *.zip ]] && ! [ -e "$2/spectrwm.conf" ] && ! [ -e "$2/.bashrc" ]; then
                shift; ISO_DIR="$1"
            fi ;;
        -h|--help)       awk '/^# =====/{n++; next} n==1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)              err "Unknown option: $1 (see --help)" ;;
        *)               POSITIONAL+=("$1") ;;
    esac
    shift
done
ARG_DOTFILES="${POSITIONAL[0]:-}"
ARG_SPECTRWM="${POSITIONAL[1]:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.shastenm-backup-$TS"
WORK_DIR="$HOME/.local/share/shastenm-build"
SPECTRWM_DEST="$HOME/.config/spectrwm"

# Upstream repos (overridable via environment)
# (space-separated: tried in order)
REPO_DOTFILES_BSD="${REPO_DOTFILES_BSD:-https://gitlab.com/smothermonethan2002/dotfiles-bsd.git https://gitlab.com/shastenm/dotfiles-bsd.git}"
REPO_SPECTRWM_BSD="${REPO_SPECTRWM_BSD:-https://gitlab.com/smothermonethan2002/spectrwm-bsd.git https://gitlab.com/shastenm/spectrwm-bsd.git}"
REPO_DMENU_SCRIPTS="${REPO_DMENU_SCRIPTS:-https://gitlab.com/smothermonethan2002/dmenu_scripts.git https://gitlab.com/shastenm/dmenu_scripts.git}"
REPO_DMENU="${REPO_DMENU:-https://gitlab.com/shastenm/dmenu-solarized.git https://gitlab.com/smothermonethan2002/dmenu-solarized.git}"
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
    # used by his dmenu scripts (sm-dots/sm-dmscr → alacritty, sm-pdf → evince,
    # sm-man → ps2pdf + zathura, notify-send, sm-ytf → ytfzf)
    alacritty evince libnotify ghostscript jq ytfzf
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
    alacritty evince libnotify ghostscript10 jq ytfzf
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
    # find_root <marker> <name> <arg> <urls> [optional]
    local marker="$1" name="$2" arg="$3" url="$4" optional="${5:-}" c z

    extract_zip() {
        local zip="$1" dest="$WORK_DIR/src/$name"
        have unzip || err "unzip is needed to read $zip"
        rm -rf "${dest:?}"; mkdir -p "$dest"
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

    # newest download first (you may have several copies of the same repo)
    local zips
    zips="$(ls -t "$SCRIPT_DIR"/*"$name"*.zip "$PWD"/*"$name"*.zip "$HOME/Downloads"/*"$name"*.zip \
             "$TARGET_HOME"/*"$name"*.zip "$TARGET_HOME/Downloads"/*"$name"*.zip 2>/dev/null | awk '!seen[$0]++' || true)"
    while IFS= read -r z; do
        [ -f "$z" ] && extract_zip "$z" && return
    done <<<"$zips"

    if [ "$OFFLINE" -eq 0 ] && have git; then
        local dest="$WORK_DIR/src/$name" u
        for u in $url; do
            rm -rf "${dest:?}"
            echo -e "${BLUE}[INFO]${NC}  Cloning $u" >&2
            if git clone --depth=1 -q "$u" "$dest" >&2 && [ -e "$dest/$marker" ]; then
                echo "$dest"; return
            fi
        done
    fi
    [ -n "$optional" ] && return 0
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
    rm -rf "${dest:?}"; mkdir -p "$(dirname "$dest")"
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
    # clone_or_pull "<url> [fallback-url...]" <dest>
    local urls="$1" dest="$2" u
    if [ -d "$dest/.git" ]; then git -C "$dest" pull --ff-only -q || true; return 0; fi
    for u in $urls; do
        rm -rf "${dest:?}"
        git clone --depth=1 -q "$u" "$dest" 2>/dev/null && return 0
    done
    return 1
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

deploy_dmenu_scripts() {
    [ -n "$DMENU_SCRIPTS_ROOT" ] || return 0
    section "dmenu scripts  ($DMENU_SCRIPTS_ROOT → ~/.local/bin/dmenu)"
    local d="$HOME/.local/bin/dmenu" f n
    mkdir -p "$d"
    for f in "$DMENU_SCRIPTS_ROOT"/*; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        case "$n" in README*|LICENSE*|*.md) continue ;; esac
        if [ -f "$d/$n" ] && ! cmp -s "$f" "$d/$n"; then backup_path "$d/$n"; fi
        cp -p "$f" "$d/$n"; chmod +x "$d/$n"
        ln -sfn "dmenu/$n" "$HOME/.local/bin/$n"
    done
    # his sm-dots / sm-dmscr open files in alacritty; sm-pdf browses ~/.pdf
    mkdir -p "$HOME/.pdf"
    ok "sm-pdf, sm-man, sm-dots, sm-dmscr, rdmenu, … installed (rdmenu = his rofi launcher)"
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
# Several mirrors per OS, tried in order. A mirror that 404s/403s or is down
# is skipped — a single bad mirror can never stop the script any more.
# (VOID_LIVE / SLACK_ISO / FBSD_ISO in the environment are tried first.)
# shellcheck disable=SC2206
VOID_MIRRORS=(${VOID_LIVE:-}
    https://repo-default.voidlinux.org/live/current
    https://repo-fastly.voidlinux.org/live/current
    https://mirrors.servercentral.com/voidlinux/live/current
    https://repo-de.voidlinux.org/live/current)
# shellcheck disable=SC2206
SLACK_MIRRORS=(${SLACK_ISO:-}
    https://slackware.uk/slackware/slackware-iso
    https://ftp.osuosl.org/pub/slackware/slackware-iso
    https://mirrors.kernel.org/slackware/slackware-iso
    https://mirrors.slackware.com/slackware/slackware-iso)
# shellcheck disable=SC2206
FBSD_MIRRORS=(${FBSD_ISO:-}
    https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES
    https://download.freebsd.org/ftp/releases/amd64/amd64/ISO-IMAGES
    https://ftp.osuosl.org/pub/FreeBSD/releases/amd64/amd64/ISO-IMAGES)

# get <url> — print the page, or nothing; never fails (so set -e can't trip)
get() { curl -fsSL --retry 2 --connect-timeout 20 --max-time 120 "$1" 2>/dev/null || true; }
fetch_listing() { get "$1/"; }

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
        || { warn "$label: download failed on this mirror"; return 1; }
    if ! sha_check "$algo" "$out" "$sum"; then
        warn "$label: checksum mismatch — downloading again from scratch"
        rm -f "$out"
        curl -fL --retry 3 -# -o "$out" "$url" || { warn "$label download failed"; return 1; }
    fi
    if sha_check "$algo" "$out" "$sum"; then ok "$label: $file verified ($algo)"
    else warn "$label: CHECKSUM MISMATCH — deleting $file"; rm -f "$out"; return 1; fi
}

ISO_VOID=""; ISO_SLACK=""; ISO_FBSD=""; ISO_FBSD_AUTO=""; ISO_VOID_AUTO=""; ISO_SLACK_AUTO=""; VOID_ROOTFS=""
declare -A VM_STATE=()
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
    local failed=0 f sum ver m listing

    # Void — x86_64 glibc base live image (the glibc build he moved to from musl)
    # + the ROOTFS tarball the Proxmox auto-install builds the VM from
    local want_rootfs=0   # (ROOTFS no longer needed — every VM uses its own installer)
    for m in "${VOID_MIRRORS[@]}"; do
        listing="$(fetch_listing "$m")"; [ -n "$listing" ] || { warn "Void: $m not reachable — next mirror"; continue; }
        local sums; sums="$(get "$m/sha256sum.txt")"
        [ -n "$sums" ] || { warn "Void: no sha256sum.txt on $m — next mirror"; continue; }
        if [ -z "$ISO_VOID" ]; then
            f="$(grep -oE 'void-live-x86_64-[0-9]{8}-base\.iso' <<<"$listing" | sort -u | tail -n1 || true)"
            sum="$(grep -F "($f)" <<<"$sums" | awk '{print $NF}' || true)"
            if [ -n "$f" ] && [ -n "$sum" ] && fetch_iso "Void" "$m/$f" "$f" 256 "$sum"; then ISO_VOID="$f"; fi
        fi
        if [ "$want_rootfs" -eq 1 ] && [ -z "$VOID_ROOTFS" ]; then
            f="$(grep -oE 'void-x86_64-ROOTFS-[0-9]{8}\.tar\.xz' <<<"$listing" | sort -u | tail -n1 || true)"
            sum="$(grep -F "($f)" <<<"$sums" | awk '{print $NF}' || true)"
            if [ -n "$f" ] && [ -n "$sum" ]; then
                local keep="$ISO_DIR"; ISO_DIR="$WORK_DIR/dl"; mkdir -p "$ISO_DIR"
                if fetch_iso "Void ROOTFS" "$m/$f" "$f" 256 "$sum"; then VOID_ROOTFS="$ISO_DIR/$f"; fi
                ISO_DIR="$keep"
            fi
        fi
        if [ -n "$ISO_VOID" ] && { [ "$want_rootfs" -eq 0 ] || [ -n "$VOID_ROOTFS" ]; }; then break; fi
    done
    [ -n "$ISO_VOID" ] || { warn "Void ISO: every mirror failed"; failed=1; }
    if [ "$want_rootfs" -eq 1 ] && [ -z "$VOID_ROOTFS" ]; then warn "Void ROOTFS: every mirror failed"; failed=1; fi

    # Slackware — newest slackware64-X.Y install DVD
    for m in "${SLACK_MIRRORS[@]}"; do
        listing="$(fetch_listing "$m")"; [ -n "$listing" ] || { warn "Slackware: $m not reachable — next mirror"; continue; }
        ver="$(grep -oE 'slackware64-[0-9]+\.[0-9]+-iso' <<<"$listing" | sort -t- -k2 -V -u | tail -n1 || true)"
        ver="${ver#slackware64-}"; ver="${ver%-iso}"
        [ -n "$ver" ] || { warn "Slackware: no ISO folders on $m — next mirror"; continue; }
        f="slackware64-$ver-install-dvd.iso"
        sum="$(get "$m/slackware64-$ver-iso/$f.md5" | awk '{print $1}' || true)"
        [ -n "$sum" ] || { warn "Slackware: no checksum on $m — next mirror"; continue; }
        if fetch_iso "Slackware $ver" "$m/slackware64-$ver-iso/$f" "$f" md5 "$sum"; then ISO_SLACK="$f"; break; fi
    done
    [ -n "$ISO_SLACK" ] || { warn "Slackware: every mirror failed"; failed=1; }

    # FreeBSD — newest RELEASE that actually has a disc1 + checksum, then older
    # ones (a brand-new release dir can be listed before its ISOs are uploaded)
    local vers v
    for m in "${FBSD_MIRRORS[@]}"; do
        listing="$(fetch_listing "$m")"
        vers="$( { grep -oE 'href="[0-9]+\.[0-9]+/' <<<"$listing" | grep -oE '[0-9]+\.[0-9]+'
                   grep -oE '>[0-9]+\.[0-9]+/' <<<"$listing" | grep -oE '[0-9]+\.[0-9]+'
                   printf '%s\n' 15.1 15.0 14.4 14.3; } | sort -t. -k1,1nr -k2,2nr -u | head -n 6 || true)"
        for v in $vers; do
            f="FreeBSD-$v-RELEASE-amd64-disc1.iso"
            sum="$(get "$m/$v/CHECKSUM.SHA256-FreeBSD-$v-RELEASE-amd64" | grep -F "($f)" | awk '{print $NF}' || true)"
            [ -n "$sum" ] || continue
            if fetch_iso "FreeBSD $v" "$m/$v/$f" "$f" 256 "$sum"; then ISO_FBSD="$f"; break 2; fi
        done
        warn "FreeBSD: nothing usable on $m — next mirror"
    done
    [ -n "$ISO_FBSD" ] || { warn "FreeBSD: every mirror failed (is download.freebsd.org reachable from this host?)"; failed=1; }

    # hand the folder to the real user if it's in their home
    if [ "$(id -u)" -eq 0 ] && [ -n "${TARGET_USER:-}" ] && [ "$TARGET_USER" != root ] \
       && [[ "$ISO_DIR" == "$TARGET_HOME"/* ]]; then
        chown -R "$TARGET_USER" "$ISO_DIR" 2>/dev/null || true
    fi

    if [ "$failed" -eq 0 ]; then ok "All 3 ISOs ready in $ISO_DIR"
    else warn "Some downloads failed on every mirror — re-run to resume (finished ones are kept)"; fi
    ls -lh "$ISO_DIR"/*.iso 2>/dev/null | awk '{print "    " $5 "  " $NF}' || true
}


# =============================================================================
# PROXMOX MODE
# =============================================================================
is_proxmox() { [ -d /etc/pve ] && have qm && have pvesm; }

pve_pick_storage() {
    # pve_pick_storage <content> <preferred...>
    local content="$1"; shift
    local list p
    list="$(pvesm status --content "$content" --enabled 1 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}')"
    for p in "$@"; do
        if grep -qx "$p" <<<"$list"; then echo "$p"; return; fi
    done
    head -n1 <<<"$list"
}

pve_tools() {
    local need=()
    have unzip || need+=(unzip)
    have git   || need+=(git)
    have xorriso || need+=(xorriso)
    have cpio    || need+=(cpio)
    have xz      || need+=(xz-utils)
    [ ${#need[@]} -eq 0 ] && return 0
    section "Installing host tools: ${need[*]}"
    apt-get update -qq 2>/dev/null || warn "apt-get update had errors (enterprise repo without a subscription?) — trying anyway"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" \
        || err "Couldn't install ${need[*]}.\n      Enable the pve-no-subscription repo (node → Updates → Repositories) and re-run."
}

build_rice_iso() {
    section "Building the shastenm-rice CD"
    local stage="$WORK_DIR/rice-cd" out="$ISO_DIR/shastenm-rice.iso"
    rm -rf "${stage:?}"; mkdir -p "$stage"
    cp "$SELF" "$stage/install.sh"
    cp -RPp "$DOTFILES_ROOT" "$stage/dotfiles-bsd-main"
    cp -RPp "$SPECTRWM_ROOT" "$stage/spectrwm-bsd-main"
    [ -n "$DMENU_SCRIPTS_ROOT" ] && cp -RPp "$DMENU_SCRIPTS_ROOT" "$stage/dmenu_scripts-main"
    rm -rf "${stage:?}/dotfiles-bsd-main/.git" "${stage:?}/spectrwm-bsd-main/.git" "${stage:?}/dmenu_scripts-main/.git"
    cat > "$stage/run.sh" <<'EOF'
#!/bin/sh
# shastenm rice — run as root inside the new VM after the OS is installed:
#   Void / Slackware : mount /dev/disk/by-label/SHASTENM /mnt && sh /mnt/run.sh
#   FreeBSD          : mount -t cd9660 /dev/iso9660/SHASTENM /mnt && sh /mnt/run.sh
# Extra options go straight to install.sh, e.g.  sh /mnt/run.sh --user ethan
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
W=/tmp/shastenm-rice
rm -rf "${W:?}"; mkdir -p "$W"
cp -R "$SRC/install.sh" "$SRC/dotfiles-bsd-main" "$SRC/spectrwm-bsd-main" "$W/"
[ -d "$SRC/dmenu_scripts-main" ] && cp -R "$SRC/dmenu_scripts-main" "$W/"
chmod -R u+w "$W"
if ! command -v bash >/dev/null 2>&1; then
    if [ "$(uname -s)" = FreeBSD ]; then
        env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
        env ASSUME_ALWAYS_YES=yes pkg install -y bash
    else
        echo "bash is missing — install it first"; exit 1
    fi
fi
if [ -d "$W/dmenu_scripts-main" ]; then set -- --dmenu-scripts "$W/dmenu_scripts-main" "$@"; fi
exec bash "$W/install.sh" "$@" "$W/dotfiles-bsd-main" "$W/spectrwm-bsd-main"
EOF
    chmod +x "$stage/run.sh" "$stage/install.sh"
    cat > "$stage/README.TXT" <<'EOF'
shastenm Linux Dev Labs rice
Log in as root after installing the OS, then:
  Void / Slackware : mount /dev/disk/by-label/SHASTENM /mnt && sh /mnt/run.sh
  FreeBSD          : mount -t cd9660 /dev/iso9660/SHASTENM /mnt && sh /mnt/run.sh
EOF
    local mk=(xorriso -as mkisofs); have xorriso || mk=(genisoimage)
    # -R (Rock Ridge) keeps real permissions, dotfiles and symlinks
    "${mk[@]}" -quiet -R -J -joliet-long -V SHASTENM -o "$out" "$stage" 2>/dev/null \
        || "${mk[@]}" -R -V SHASTENM -o "$out" "$stage"
    ok "$(basename "$out") → $PVE_ISO_STORAGE:iso/  ($(du -h "$out" | cut -f1))"
}

pve_destroy_named() {
    local name="$1" id
    id="$(qm list 2>/dev/null | awk -v n="$name" 'NR>1 && $2==n {print $1; exit}')"
    [ -n "$id" ] || return 0
    warn "--rebuild: destroying VM $id ($name)"
    qm stop "$id" >/dev/null 2>&1 || true
    qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null
}

pve_vol_exists() {
    # pve_vol_exists <storage:iso/file.iso>
    local f; f="$(pvesm path "$1" 2>/dev/null || true)"
    [ -n "$f" ] && [ -f "$f" ]
}

pve_missing_media() {
    # print every CD/DVD volume a VM uses that isn't actually in storage
    qm config "$1" 2>/dev/null | sed -n 's/^\(ide[0-9]\|sata[0-9]\|scsi[0-9]\): \([^,]*:iso\/[^,]*\),.*/\2/p' \
        | while IFS= read -r v; do pve_vol_exists "$v" || echo "$v"; done
}

pve_existing_vm() {
    qm list 2>/dev/null | awk -v n="$1" 'NR>1 && $2==n {print $1; exit}'
}

# -----------------------------------------------------------------------------
# First boot: the OS installs, reboots, THEN this installs the rice and reboots
# into it. Same script on all three VMs.
# -----------------------------------------------------------------------------
firstboot_script() {
    # firstboot_script [extra install.sh args]
    local extra="$*"
    sed -e "s|@USER@|$VM_USER|g" -e "s|@EXTRA@|$extra|g" <<'FBEOF'
#!/bin/sh
# shastenm first boot — installs the dotfiles once, then reboots into them.
# Log: /var/log/shastenm-rice.log   (re-run by hand: /usr/local/sbin/shastenm-firstboot)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
FLAG=/var/db/shastenm-firstboot
LOG=/var/log/shastenm-rice.log
RICE=/root/shastenm-rice
[ -f "$FLAG" ] || exit 0
say() { echo "[shastenm] $*" >> "$LOG"; echo "[shastenm] $*" > /dev/console 2>/dev/null || true; }

say "first boot — waiting for the network..."
i=0
until ping -c 1 8.8.8.8 >/dev/null 2>&1 || [ "$i" -ge 60 ]; do i=$((i + 1)); sleep 5; done

if [ ! -f "$RICE/run.sh" ]; then
    # FreeBSD keeps the rice on the second CD — copy it onto the disk
    mkdir -p /mnt/rice
    for d in /dev/iso9660/SHASTENM /dev/disk/by-label/SHASTENM /dev/cd0 /dev/cd1 /dev/sr0 /dev/sr1; do
        [ -e "$d" ] || continue
        if mount -t cd9660 -o ro "$d" /mnt/rice 2>/dev/null || mount -o ro "$d" /mnt/rice 2>/dev/null; then
            if [ -f /mnt/rice/run.sh ]; then cp -R /mnt/rice "$RICE"; umount /mnt/rice; break; fi
            umount /mnt/rice
        fi
    done
fi
[ -f "$RICE/run.sh" ] || { say "rice files not found — is the shastenm-rice CD attached?"; exit 1; }

say "installing the shastenm dotfiles for @USER@ — the VM reboots by itself when done"
say "watch it:  tail -f $LOG"
if sh "$RICE/run.sh" --user @USER@ -y @EXTRA@ >> "$LOG" 2>&1; then
    # his rice lives in ~/.bashrc, so log in to bash (FreeBSD starts users on sh)
    B="$(command -v bash 2>/dev/null || true)"
    if [ -n "$B" ]; then
        grep -qx "$B" /etc/shells 2>/dev/null || echo "$B" >> /etc/shells
        if command -v pw >/dev/null 2>&1; then pw usermod @USER@ -s "$B"; else usermod -s "$B" @USER@ 2>/dev/null || true; fi
    fi
    rm -f "$FLAG"
    say "dotfiles installed — rebooting into the riced system"
    sleep 5
    reboot
else
    say "dotfiles install hit an error — see $LOG (it retries on the next boot)"
    exit 1
fi
FBEOF
}

# -----------------------------------------------------------------------------
# ISO + initrd remastering helpers (run on the Proxmox host)
# -----------------------------------------------------------------------------
iso_extract() {
    # iso_extract <iso> <path-in-iso> <local-file>
    rm -f "${3:?}"
    xorriso -osirrox on -indev "$1" -extract "$2" "$3" >/dev/null 2>&1 || true
    [ -s "$3" ] && chmod u+w "$3"
    [ -s "$3" ]
}

iso_label() { xorriso -indev "$1" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p' | head -n1; }

# Plain ISO9660 names must stay exactly as on the original disc: ISOLINUX
# looks files up by them, and xorriso's defaults would turn "bzImage" into
# "bzImage.;1" ("Could not find kernel image: /kernels/huge.s/bzImage").
ISO_COMPLIANCE="no_force_dots:omit_version:allow_dir_id_ext:lowercase:full_ascii:iso_9660_level=3"
ISO_MUST=()   # extra files (e.g. the kernel) that must exist in a remastered ISO

iso_ok() {
    # iso_ok <iso> <path-in-iso>... — exists, still bootable, contains every path
    local iso="$1"; shift
    set -- "$@" "${ISO_MUST[@]}"
    [ -s "$iso" ] || return 1
    xorriso -indev "$iso" -report_el_torito plain 2>/dev/null | grep -qi 'boot img' || return 1
    local p
    for p in "$@"; do
        xorriso -indev "$iso" -find "$p" 2>/dev/null | grep -qF "${p##*/}" || return 1
    done
}

iso_remaster() {
    # iso_remaster <src.iso> <out.iso> <log> "<mkisofs BIOS boot args>" <local> <iso-path> [<local> <iso-path>...]
    # Replaces/adds files in an installer ISO while keeping it bootable.
    local src="$1" final="$2" xlog="$3" bootargs="$4"; shift 4
    # build under a temp name; only replace the real ISO once the new one checks out
    local out="$final.part.iso"
    local maps=() paths=() a=("$@")
    while [ $# -ge 2 ]; do maps+=(-map "$1" "$2"); paths+=("$2"); shift 2; done
    rm -f "${out:?}"
    # 1) copy the ISO with our files dropped in, replaying its own boot setup.
    #    (xorriso exits non-zero on harmless hybrid-layout warnings, so judge
    #    by checking the result instead of the exit code)
    xorriso -return_with FAILURE 32 -indev "$src" -outdev "$out" -compliance "$ISO_COMPLIANCE" \
        "${maps[@]}" -boot_image any replay > "$xlog" 2>&1 || true
    if iso_ok "$out" "${paths[@]}"; then mv -f "$out" "$final"; return 0; fi
    # 2) rebuild it from its files with the OS's BIOS boot loader
    warn "Quick remaster of $(basename "$src") didn't work — rebuilding it from its files (log: $xlog)"
    # unpack on the ISO storage (it has room for a full DVD; / often doesn't)
    local tree="$ISO_DIR/.shastenm-iso-tree" label need_k free_k want got
    label="$(iso_label "$src")"
    rm -rf "${tree:?}"; mkdir -p "$tree"
    need_k=$(( $(stat -c %s "$src") / 1024 + 1048576 ))
    free_k="$(df -Pk "$ISO_DIR" | awk 'NR==2{print $4}')"
    if [ "$free_k" -lt "$need_k" ]; then
        warn "Not enough room in $ISO_DIR to unpack $(basename "$src") ($((need_k/1048576))G needed)"
        rm -rf "${tree:?}"; rm -f "${out:?}"; return 1
    fi
    xorriso -osirrox on -indev "$src" -extract / "$tree" >> "$xlog" 2>&1 || true
    chmod -R u+w "$tree"
    want="$(xorriso -indev "$src" -find / -type f 2>/dev/null | wc -l)"
    got="$(find "$tree" -type f | wc -l)"
    if [ "$got" -lt "$want" ]; then
        warn "Unpacking $(basename "$src") was incomplete ($got of $want files) — see $xlog"
        rm -rf "${tree:?}"; rm -f "${out:?}"; return 1
    fi
    set -- "${a[@]}"
    while [ $# -ge 2 ]; do mkdir -p "$tree$(dirname "$2")"; cp "$1" "$tree$2"; shift 2; done
    rm -f "${out:?}"
    # shellcheck disable=SC2086
    xorriso -as mkisofs -iso-level 3 -untranslated-filenames -untranslated_name_len 96 \
        -R -J -joliet-long -V "${label:-INSTALL}" $bootargs -o "$out" "$tree" >> "$xlog" 2>&1 || true
    rm -rf "${tree:?}"
    if iso_ok "$out" "${paths[@]}"; then mv -f "$out" "$final"; return 0; fi
    rm -f "${out:?}"
    return 1
}

initrd_overlay() {
    # initrd_overlay <base-initrd> <out-initrd> <overlay-dir>
    # Appends an extra cpio archive; the kernel unpacks it on top of the
    # original, so files in <overlay-dir> are added/replaced at boot.
    cp "$1" "$2"
    local sz pad
    sz="$(stat -c %s "$2")"; pad=$(( (512 - sz % 512) % 512 ))
    [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero >> "$2"
    (cd "$3" && find . | cpio -o -H newc -R 0:0 --quiet) >> "$2"
}

initrd_cat() {
    # initrd_cat <initrd> <path-inside> — print one file from a (compressed) initrd
    local magic dec
    magic="$(head -c 6 "$1" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        fd377a585a00*) dec="xz -dc" ;;
        1f8b*)         dec="gzip -dc" ;;
        28b52ffd*)     dec="zstd -dc" ;;
        *)             dec="cat" ;;
    esac
    # shellcheck disable=SC2086
    $dec < "$1" 2>/dev/null | cpio -i --to-stdout --quiet "$2" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Void — the official live ISO's built-in unattended installer (root=vai auto)
# -----------------------------------------------------------------------------
build_void_iso() {
    local src="$ISO_DIR/$ISO_VOID" out="$ISO_DIR/void-shastenm-auto.iso"
    local w="$WORK_DIR/void-iso" xlog="$WORK_DIR/logs/void-remaster.log"
    rm -rf "${w:?}"; mkdir -p "$w/overlay/etc" "$WORK_DIR/logs"

    iso_extract "$src" /boot/isolinux/isolinux.cfg "$w/isolinux.cfg" \
        || { warn "Void ISO has no /boot/isolinux/isolinux.cfg"; return 1; }
    iso_extract "$src" /boot/initrd "$w/initrd" \
        || { warn "Void ISO has no /boot/initrd"; return 1; }

    # boot the default entry straight into the autoinstaller
    sed -i -e 's/^TIMEOUT .*/TIMEOUT 30/' \
           -e '0,/root=live:CDLABEL=[A-Za-z0-9_]*/s//root=vai auto/' "$w/isolinux.cfg"
    grep -q 'root=vai auto' "$w/isolinux.cfg" || { warn "Couldn't find the Void boot line to change"; return 1; }

    # autoinstaller settings (it reads /etc/autoinstall.default from the initrd)
    {
        cat <<EOF
# shastenm — Void Linux autoinstall settings
disk="/dev/\$(lsblk --json -d -o NAME,TYPE | jq -r '[.blockdevices[]|select(.type=="disk")][0].name')"
username="$VM_USER"
password="$VM_PASS"
hostname="void-shastenm"
timezone="America/Indiana/Indianapolis"
keymap="us"
libclocale="en_US.UTF-8"
end_action=func

# Replaces the autoinstaller's own GRUB step (this file is loaded inside the
# installer, so this definition wins). Theirs stops at the first error and can
# leave a disk with GRUB but no grub.cfg — the empty "grub>" prompt.
VAI_configure_grub() {
    echo 'hostonly="no"' > "\${target}/etc/dracut.conf.d/hostonly.conf"
    echo "[shastenm] installing GRUB on \${disk}"
    chroot "\${target}" grub-install --target=i386-pc "\${disk}" \
        || chroot "\${target}" grub-install "\${disk}" || echo "[shastenm] grub-install reported an error"
    echo "[shastenm] building the initramfs"
    chroot "\${target}" xbps-reconfigure -fa || echo "[shastenm] xbps-reconfigure reported an error"
    echo "[shastenm] writing grub.cfg"
    chroot "\${target}" grub-mkconfig -o /boot/grub/grub.cfg || echo "[shastenm] grub-mkconfig reported an error"
    if ! grep -q '^[[:space:]]*linux' "\${target}/boot/grub/grub.cfg" 2>/dev/null; then
        _k="\$(ls "\${target}/boot" | sed -n 's/^vmlinuz-//p' | tail -n1)"
        _u="\$(blkid -s UUID -o value "\${disk}\${partsep}1")"
        echo "[shastenm] grub-mkconfig gave no menu — writing one for kernel \${_k}"
        mkdir -p "\${target}/boot/grub"
        {
            echo "set timeout=3"
            echo "insmod part_msdos"
            echo "insmod ext2"
            echo "search --no-floppy --fs-uuid --set=root \${_u}"
            echo "menuentry 'Void Linux' {"
            echo "    linux /boot/vmlinuz-\${_k} root=UUID=\${_u} ro loglevel=4"
            echo "    initrd /boot/initramfs-\${_k}.img"
            echo "}"
        } > "\${target}/boot/grub/grub.cfg"
    fi
}

end_function() {
    echo "[shastenm] setting up first-boot dotfiles install"
    echo "root:$VM_PASS" | chpasswd -c SHA512 -R "\${target}"
    for s in dhcpcd sshd; do
        [ -d "\${target}/etc/sv/\$s" ] && ln -sf "/etc/sv/\$s" "\${target}/etc/runit/runsvdir/default/\$s"
    done
    mkdir -p "\${target}/usr/local/sbin" "\${target}/var/db" "\${target}/etc/sv/shastenm-firstboot"
    cat > "\${target}/usr/local/sbin/shastenm-firstboot" <<'SMFB'
EOF
        firstboot_script
        cat <<'EOF'
SMFB
    chmod 755 "${target}/usr/local/sbin/shastenm-firstboot"
    cat > "${target}/etc/sv/shastenm-firstboot/run" <<'SMRUN'
#!/bin/sh
[ -f /var/db/shastenm-firstboot ] && /usr/local/sbin/shastenm-firstboot
if [ -f /var/db/shastenm-firstboot ]; then sleep 600; exit 1; fi
rm -f /etc/runit/runsvdir/default/shastenm-firstboot
exec sleep 1000000
SMRUN
    chmod 755 "${target}/etc/sv/shastenm-firstboot/run"
    ln -sf /etc/sv/shastenm-firstboot "${target}/etc/runit/runsvdir/default/shastenm-firstboot"
    : > "${target}/var/db/shastenm-firstboot"
    echo "[shastenm] Void installed — rebooting into it"
    sync
    umount -R "${target}" 2>/dev/null || true
    reboot -f
}
EOF
    } > "$w/overlay/etc/autoinstall.default"
    sh -n "$w/overlay/etc/autoinstall.default" || { warn "Generated Void autoinstall config isn't valid sh"; return 1; }

    initrd_overlay "$w/initrd" "$w/initrd.new" "$w/overlay"
    ISO_MUST=(/boot/vmlinuz /boot/isolinux/isolinux.bin)
    iso_remaster "$src" "$out" "$xlog" \
        "-b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table" \
        "$w/isolinux.cfg" /boot/isolinux/isolinux.cfg "$w/initrd.new" /boot/initrd \
        || { warn "Couldn't build the unattended Void ISO — see $xlog"; return 1; }
    rm -rf "${w:?}"
    ISO_VOID_AUTO="$(basename "$out")"
    ok "Unattended Void installer → $PVE_ISO_STORAGE:iso/$ISO_VOID_AUTO"
}

# -----------------------------------------------------------------------------
# Slackware — its own installer + its own installpkg, scripted
# -----------------------------------------------------------------------------
slackware_autoinstall_script() {
    sed -e "s|@USER@|$VM_USER|g" -e "s|@PASS@|$VM_PASS|g" -e "s|@SPECTRWM@|$WITH_SPECTRWM_SLACK|g" <<'SLEOF'
#!/bin/sh
# shastenm — unattended Slackware install, run by the installer at boot.
# Uses the installer's own tools; the DVD is the package source.
say() { echo "[shastenm] $*"; }
die() { say "ERROR: $*"; say "dropping to a shell"; exec /bin/sh; }
SERIES="a ap d l n x xap xfce"

say "Slackware unattended install starting"
DISK=""
for t in 1 2 3 4 5 6 7 8 9 10; do
    for d in /dev/sda /dev/vda /dev/hda; do [ -b "$d" ] && { DISK="$d"; break 2; }; done
    [ "$t" = 3 ] && { modprobe ahci; modprobe virtio_scsi; modprobe virtio_blk; modprobe sd_mod; } 2>/dev/null
    sleep 1
done
[ -n "$DISK" ] || die "no hard disk found"
say "target disk: $DISK"

mkdir -p /cdrom
found=""
for c in /dev/sr0 /dev/sr1 /dev/sr2 /dev/sr3 /dev/hdc /dev/hdd; do
    [ -b "$c" ] || continue
    if mount -o ro -t iso9660 "$c" /cdrom 2>/dev/null; then
        if [ -d /cdrom/slackware64 ]; then found="$c"; break; fi
        umount /cdrom
    fi
done
[ -n "$found" ] || die "Slackware DVD not found"
say "packages from $found"

say "partitioning $DISK"
if command -v sfdisk >/dev/null 2>&1; then
    printf 'label: dos\n,,L,*\n' | sfdisk -q "$DISK" || die "sfdisk failed"
else
    printf 'o\nn\np\n1\n\n\na\nw\n' | fdisk "$DISK" >/dev/null 2>&1 || die "fdisk failed"
fi
sleep 2
PART="${DISK}1"
[ -b "$PART" ] || { mdev -s 2>/dev/null; sleep 2; }
[ -b "$PART" ] || die "$PART didn't appear"
mkfs.ext4 -F -q -L slackware "$PART" 2>/dev/null || mke2fs -F -q -t ext4 -L slackware "$PART" || die "mkfs failed"
mount "$PART" /mnt || die "can't mount $PART"

for s in $SERIES; do
    [ -d "/cdrom/slackware64/$s" ] || continue
    say "installing series $s ($(ls /cdrom/slackware64/$s/*.t?z | wc -l) packages)"
    installpkg --root /mnt --terse /cdrom/slackware64/$s/*.t?z >/dev/null 2>&1
done
[ -x /mnt/bin/bash ] || die "package install failed (no /bin/bash on the new system)"

say "configuring the new system"
for d in dev proc sys; do mkdir -p /mnt/$d; mount -o bind /$d /mnt/$d; done
cat > /mnt/etc/fstab <<EOF
$PART / ext4 defaults 1 1
devpts /dev/pts devpts gid=5,mode=620 0 0
proc /proc proc defaults 0 0
tmpfs /dev/shm tmpfs nosuid,nodev,noexec 0 0
EOF
echo "slackware-shastenm.lan" > /mnt/etc/HOSTNAME
sed -i 's/^USE_DHCP\[0\]=""/USE_DHCP[0]="yes"/' /mnt/etc/rc.d/rc.inet1.conf 2>/dev/null
ln -sf /usr/share/zoneinfo/America/Indiana/Indianapolis /mnt/etc/localtime
chmod +x /mnt/etc/rc.d/rc.sshd 2>/dev/null
chroot /mnt /sbin/ldconfig 2>/dev/null

say "creating user @USER@"
chroot /mnt /usr/sbin/useradd -m -g users -s /bin/bash @USER@ 2>/dev/null \
    || chroot /mnt /usr/sbin/useradd -m -s /bin/bash @USER@ || die "useradd failed"
for g in wheel audio video cdrom plugdev netdev power lp scanner; do
    chroot /mnt /usr/sbin/usermod -a -G "$g" @USER@ 2>/dev/null
done
printf '%s\n%s\n' '@USER@:@PASS@' 'root:@PASS@' | chroot /mnt /usr/sbin/chpasswd || die "chpasswd failed"

say "installing the LILO bootloader"
K="$(ls /mnt/boot/vmlinuz-huge-* 2>/dev/null | head -n1)"
[ -n "$K" ] || K="$(ls /mnt/boot/vmlinuz-* 2>/dev/null | head -n1)"
[ -n "$K" ] || die "no kernel in /mnt/boot"
cat > /mnt/etc/lilo.conf <<EOF
boot = $DISK
compact
lba32
prompt
timeout = 30
vga = normal
image = /boot/${K##*/}
  root = $PART
  label = Slackware
  read-only
EOF
chroot /mnt /sbin/lilo || die "lilo failed"

say "setting up the first-boot dotfiles install"
mkdir -p /mnt/usr/local/sbin /mnt/var/db
cp /shastenm/firstboot.sh /mnt/usr/local/sbin/shastenm-firstboot
chmod 755 /mnt/usr/local/sbin/shastenm-firstboot
touch /mnt/var/db/shastenm-firstboot
touch /mnt/etc/rc.d/rc.local
grep -q shastenm-firstboot /mnt/etc/rc.d/rc.local || cat >> /mnt/etc/rc.d/rc.local <<'EOF'

# shastenm: install the dotfiles on first boot (log: /var/log/shastenm-rice.log)
[ -x /usr/local/sbin/shastenm-firstboot ] && /usr/local/sbin/shastenm-firstboot &
EOF
chmod 755 /mnt/etc/rc.d/rc.local

say "Slackware installed — rebooting into it"
sync
for d in sys proc dev; do umount /mnt/$d 2>/dev/null; done
umount /mnt; umount /cdrom 2>/dev/null
sleep 3
reboot -f || reboot
SLEOF
}

build_slackware_iso() {
    local src="$ISO_DIR/$ISO_SLACK" out="$ISO_DIR/slackware-shastenm-auto.iso"
    local w="$WORK_DIR/slack-iso" xlog="$WORK_DIR/logs/slackware-remaster.log"
    rm -rf "${w:?}"; mkdir -p "$w/overlay/etc/rc.d" "$w/overlay/shastenm" "$WORK_DIR/logs"

    iso_extract "$src" /isolinux/isolinux.cfg "$w/isolinux.cfg" \
        || { warn "Slackware DVD has no /isolinux/isolinux.cfg"; return 1; }
    iso_extract "$src" /isolinux/initrd.img "$w/initrd.img" \
        || { warn "Slackware DVD has no /isolinux/initrd.img"; return 1; }

    # boot the default (huge.s) kernel straight away, no boot: prompt
    local lbl
    lbl="$(awk 'tolower($1)=="label"{print $2}' "$w/isolinux.cfg" | grep -m1 huge || true)"
    [ -n "$lbl" ] || lbl="$(awk 'tolower($1)=="label"{print $2; exit}' "$w/isolinux.cfg")"
    [ -n "$lbl" ] || { warn "Couldn't find a boot entry in the Slackware isolinux.cfg"; return 1; }
    sed -i -e '/^[Dd][Ee][Ff][Aa][Uu][Ll][Tt] /d' -e '/^[Pp][Rr][Oo][Mm][Pp][Tt] /d' \
           -e '/^[Tt][Ii][Mm][Ee][Oo][Uu][Tt] /d' -e '/^[Dd][Ii][Ss][Pp][Ll][Aa][Yy] /d' \
           -e '/^[Ff][0-9]* /d' "$w/isolinux.cfg"
    sed -i "1i default $lbl\nprompt 0\ntimeout 10" "$w/isolinux.cfg"

    # wrap the installer's startup script: let it set up hardware as normal
    # (pressing Enter at its keyboard-map question), then run our install
    initrd_cat "$w/initrd.img" etc/rc.d/rc.S > "$w/overlay/etc/rc.d/rc.S.orig"
    [ -s "$w/overlay/etc/rc.d/rc.S.orig" ] || { warn "Couldn't read rc.S from the Slackware installer initrd"; return 1; }
    cat > "$w/overlay/etc/rc.d/rc.S" <<'EOF'
#!/bin/sh
# shastenm: run the normal installer startup, answering its prompts with Enter
( while :; do echo; done ) | /bin/sh /etc/rc.d/rc.S.orig
# then install Slackware unattended (reboots when done)
/bin/sh /shastenm/autoinstall.sh 2>&1 | tee /shastenm-install.log
EOF
    chmod 755 "$w/overlay/etc/rc.d/rc.S" "$w/overlay/etc/rc.d/rc.S.orig"
    slackware_autoinstall_script > "$w/overlay/shastenm/autoinstall.sh"
    local extra=""; [ "$WITH_SPECTRWM_SLACK" -eq 1 ] && extra="--with-spectrwm"
    # shellcheck disable=SC2086
    firstboot_script $extra > "$w/overlay/shastenm/firstboot.sh"
    chmod 755 "$w/overlay/shastenm/"*.sh
    sh -n "$w/overlay/shastenm/autoinstall.sh" || { warn "Generated Slackware install script isn't valid sh"; return 1; }

    initrd_overlay "$w/initrd.img" "$w/initrd.new" "$w/overlay"
    local kern; kern="$(awk 'tolower($1)=="kernel"{print $2; exit}' "$w/isolinux.cfg")"
    ISO_MUST=(/isolinux/isolinux.bin "${kern:-/kernels/huge.s/bzImage}")
    iso_remaster "$src" "$out" "$xlog" \
        "-b isolinux/isolinux.bin -c isolinux/isolinux.boot -no-emul-boot -boot-load-size 4 -boot-info-table" \
        "$w/isolinux.cfg" /isolinux/isolinux.cfg "$w/initrd.new" /isolinux/initrd.img \
        || { warn "Couldn't build the unattended Slackware ISO — see $xlog"; return 1; }
    rm -rf "${w:?}"
    ISO_SLACK_AUTO="$(basename "$out")"
    ok "Unattended Slackware installer → $PVE_ISO_STORAGE:iso/$ISO_SLACK_AUTO"
}

# -----------------------------------------------------------------------------
# FreeBSD — its own installer, made unattended with an installerconfig
# -----------------------------------------------------------------------------
build_freebsd_iso() {
    local out="$ISO_DIR/freebsd-shastenm-auto.iso" cfg="$WORK_DIR/installerconfig"
    cat > "$cfg" <<'EOF'
# --- unattended FreeBSD install (shastenm) -----------------------------------
# virtio-scsi disk = da0. Classic dist sets from the disc (15.x defaults to
# pkgbase otherwise). If the sets aren't on the disc, fetch them over DHCP.
PARTITIONS="da0"
DISTRIBUTIONS="kernel.txz base.txz"
BSDINSTALL_DISTSITE="https://download.freebsd.org/releases/amd64/@FBSDREL@"
export nonInteractive="YES"
if [ ! -f /usr/freebsd-dist/base.txz ]; then
    for nic in vtnet0 em0; do ifconfig "$nic" >/dev/null 2>&1 && dhclient "$nic" >/dev/null 2>&1 && break; done
fi

#!/bin/sh
sysrc hostname="freebsd-shastenm"
sysrc ifconfig_DEFAULT="SYNCDHCP"
sysrc sshd_enable="YES"
sysrc dumpdev="NO"
echo '@PASS@' | pw usermod root -h 0
# only join groups that exist (a missing one would fail the whole step)
grps="wheel"
for g in operator video; do pw groupshow "$g" >/dev/null 2>&1 && grps="$grps,$g"; done
pw useradd @USER@ -m -G "$grps" -s /bin/sh -c "@USER@"
echo '@PASS@' | pw usermod @USER@ -h 0
touch /var/db/shastenm-firstboot
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/shastenm-firstboot <<'SMFB'
@FIRSTBOOT@
SMFB
chmod 755 /usr/local/sbin/shastenm-firstboot
cat > /etc/rc.local <<'RCEOF'
#!/bin/sh
# shastenm: install the dotfiles on first boot (log: /var/log/shastenm-rice.log)
[ -x /usr/local/sbin/shastenm-firstboot ] && /usr/local/sbin/shastenm-firstboot &
RCEOF
chmod +x /etc/rc.local
EOF
    local rel; rel="$(sed -n 's/^FreeBSD-\([0-9.]*-RELEASE\)-.*/\1/p' <<<"$ISO_FBSD")"
    sed -i "s/@USER@/$VM_USER/g; s/@PASS@/$VM_PASS/g; s/@FBSDREL@/${rel:-15.1-RELEASE}/g" "$cfg"
    # drop the shared first-boot script in place of @FIRSTBOOT@
    local fb="$WORK_DIR/firstboot.sh"
    firstboot_script > "$fb"
    sed -i -e "/^@FIRSTBOOT@\$/{r $fb" -e 'd;}' "$cfg"
    local src="$ISO_DIR/$ISO_FBSD" xlog="$WORK_DIR/logs/freebsd-remaster.log"
    mkdir -p "$WORK_DIR/logs"
    ISO_MUST=(/boot/cdboot /boot/kernel/kernel)
    iso_remaster "$src" "$out" "$xlog" "-b boot/cdboot -no-emul-boot" "$cfg" /etc/installerconfig \
        || { warn "Couldn't build the unattended FreeBSD ISO — see $xlog"; return 1; }
    ISO_FBSD_AUTO="$(basename "$out")"
    ok "Unattended FreeBSD installer → $PVE_ISO_STORAGE:iso/$ISO_FBSD_AUTO"
}

# -----------------------------------------------------------------------------
# Create one VM from its unattended installer ISO + the rice CD, and start it
# -----------------------------------------------------------------------------
pve_auto_vm() {
    # pve_auto_vm <name> <void|slackware|freebsd> <size-GiB> <mem-MiB>
    local name="$1" kind="$2" size="$3" mem="$4" id iso ostype nic diskopt bootdev
    id="$(pve_existing_vm "$name")"
    if [ -n "$id" ]; then
        local missing; missing="$(pve_missing_media "$id")"
        if [ -z "$missing" ]; then
            ok "$name already exists (VM $id) — leaving it alone (use --rebuild to start over)"
            VM_STATE[$name]="exists"; VM_IDS+=("$id:$name"); return 0
        fi
        warn "$name (VM $id) points at ISO(s) that aren't in storage: $(echo $missing)"
        warn "  → rebuilding its installer ISO and re-attaching the discs"
    fi
    section "Preparing $name"
    case "$kind" in
        void)
            [ -n "$ISO_VOID" ] || { warn "$name: no Void ISO — skipping"; VM_STATE[$name]="skipped (no ISO)"; return 0; }
            build_void_iso || { VM_STATE[$name]="failed (ISO remaster, see $WORK_DIR/logs/void-remaster.log)"; return 0; }
            iso="$ISO_VOID_AUTO"; ostype=l26; nic=virtio
            diskopt=(--scsihw virtio-scsi-single --scsi0 "$PVE_STORAGE:$size,discard=on,iothread=1"); bootdev=scsi0 ;;
        slackware)
            [ -n "$ISO_SLACK" ] || { warn "$name: no Slackware DVD — skipping"; VM_STATE[$name]="skipped (no ISO)"; return 0; }
            build_slackware_iso || { VM_STATE[$name]="failed (ISO remaster, see $WORK_DIR/logs/slackware-remaster.log)"; return 0; }
            # SATA disk + e1000 NIC: drivers the Slackware installer kernel always has
            iso="$ISO_SLACK_AUTO"; ostype=l26; nic=e1000
            diskopt=(--sata0 "$PVE_STORAGE:$size,discard=on"); bootdev=sata0 ;;
        freebsd)
            [ -n "$ISO_FBSD" ] || { warn "$name: no FreeBSD ISO — skipping"; VM_STATE[$name]="skipped (no ISO)"; return 0; }
            build_freebsd_iso || { VM_STATE[$name]="failed (ISO remaster, see $WORK_DIR/logs/freebsd-remaster.log)"; return 0; }
            iso="$ISO_FBSD_AUTO"; ostype=other; nic=virtio
            diskopt=(--scsihw virtio-scsi-single --scsi0 "$PVE_STORAGE:$size,discard=on,iothread=1"); bootdev=scsi0 ;;
    esac
    pve_vol_exists "$PVE_ISO_STORAGE:iso/$iso" || { warn "$name: $iso didn't land in $PVE_ISO_STORAGE"; VM_STATE[$name]="failed (installer ISO missing)"; return 0; }
    if [ -n "$id" ]; then
        qm set "$id" --ide2 "$PVE_ISO_STORAGE:iso/$iso,media=cdrom" \
                     --ide0 "$PVE_ISO_STORAGE:iso/shastenm-rice.iso,media=cdrom" >/dev/null
        ok "Re-attached $iso + shastenm-rice.iso to VM $id ($name)"
        VM_STATE[$name]="selfinstall"; VM_IDS+=("$id:$name"); return 0
    fi
    id="$(pvesh get /cluster/nextid)"
    qm create "$id" --name "$name" --tags shastenm \
        --memory "$mem" --cores 2 --cpu host --ostype "$ostype" \
        "${diskopt[@]}" --net0 "$nic,bridge=$PVE_BRIDGE" --vga std \
        --ide2 "$PVE_ISO_STORAGE:iso/$iso,media=cdrom" \
        --ide0 "$PVE_ISO_STORAGE:iso/shastenm-rice.iso,media=cdrom" \
        --boot "order=$bootdev;ide2" >/dev/null
    ok "Created VM $id $name — installs itself from $iso, reboots, then installs the dotfiles"
    VM_STATE[$name]="selfinstall"
    VM_IDS+=("$id:$name")
}

proxmox_main() {
    [ "$(id -u)" -eq 0 ] || err "On Proxmox run this as root (the web shell already is)."
    DISTRO="proxmox"
    ok "Detected: Proxmox VE $(pveversion 2>/dev/null | cut -d/ -f2) on $(hostname) — auto-installing Void, Slackware and FreeBSD VMs ($VM_USER / $VM_PASS)"
    info "(The rice itself goes inside the VMs, not on the hypervisor.)"
    mkdir -p "$WORK_DIR"

    pve_tools

    # ISO storage → its folder on disk
    [ -n "$PVE_ISO_STORAGE" ] || PVE_ISO_STORAGE="$(pve_pick_storage iso local)"
    [ -n "$PVE_ISO_STORAGE" ] || err "No storage with ISO content found (Datacenter → Storage)"
    ISO_DIR="$(dirname "$(pvesm path "$PVE_ISO_STORAGE:iso/probe.iso")")"
    TARGET_HOME="$HOME"
    download_isos

    DOTFILES_ROOT="$(find_root ".config/nvim-configs" "dotfiles-bsd-main" "$ARG_DOTFILES" "$REPO_DOTFILES_BSD")"
    SPECTRWM_ROOT="$(find_root "spectrwm.conf" "spectrwm-bsd-main" "$ARG_SPECTRWM" "$REPO_SPECTRWM_BSD")"
    DMENU_SCRIPTS_ROOT="$(find_root "sm-dmscr" "dmenu_scripts-main" "$ARG_DMENU_SCRIPTS" "$REPO_DMENU_SCRIPTS" optional)"
    info "Dotfiles root : $DOTFILES_ROOT"
    if [ -n "$DMENU_SCRIPTS_ROOT" ]; then info "dmenu scripts : $DMENU_SCRIPTS_ROOT"
    else warn "dmenu_scripts not found — sm-pdf / sm-dots / sm-dmscr / sm-man won't be installed"; fi
    info "Spectrwm root : $SPECTRWM_ROOT"
    build_rice_iso

    VM_IDS=()
    if [ "$PVE_VMS" -eq 1 ]; then
        section "Creating VMs"
        [ -n "$PVE_STORAGE" ] || PVE_STORAGE="$(pve_pick_storage images local-lvm local-zfs local)"
        [ -n "$PVE_STORAGE" ] || err "No storage with VM-disk content found"
        [ -n "$PVE_BRIDGE" ]  || PVE_BRIDGE="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep '^vmbr' | head -n1 || true)"
        PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"

        # size disks to what the pool actually has (3 VMs, keep 20% spare)
        local avail_k size mem host_mem fit
        avail_k="$(pvesm status --storage "$PVE_STORAGE" 2>/dev/null | awk 'NR==2{print $6}')"
        size=32
        if [ -n "$avail_k" ]; then
            fit=$(( avail_k * 8 / 10 / 1048576 / 3 ))
            if [ "$fit" -lt "$size" ]; then size="$fit"; fi
        fi
        [ "$size" -ge 12 ] || err "$PVE_STORAGE only has room for ${size}G per VM (need 12G+) — free space or use --storage"
        host_mem="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
        mem=4096; if [ "$host_mem" -lt 16384 ]; then mem=2048; fi

        if [ "$PVE_REBUILD" -eq 1 ]; then
            pve_destroy_named void-shastenm
            pve_destroy_named slackware-shastenm
            pve_destroy_named freebsd-shastenm
        fi
        pve_auto_vm "void-shastenm"      void      "$size" "$mem"
        pve_auto_vm "slackware-shastenm" slackware "$size" "$mem"
        pve_auto_vm "freebsd-shastenm"   freebsd   "$size" "$mem"

        if [ "$PVE_START" -eq 1 ]; then
            local v
            for v in "${VM_IDS[@]}"; do
                if qm status "${v%%:*}" | grep -q running; then continue; fi
                local miss; miss="$(pve_missing_media "${v%%:*}")"
                if [ -n "$miss" ]; then
                    warn "Not starting ${v#*:}: missing $(echo $miss) — re-run the script to rebuild it"
                    VM_STATE[${v#*:}]="not started (missing $(echo $miss))"
                    continue
                fi
                qm start "${v%%:*}" >/dev/null 2>&1 && ok "Started ${v#*:} (VM ${v%%:*})" \
                    || warn "Couldn't start ${v#*:} — see: qm start ${v%%:*}"
            done
        fi
    fi

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║      Proxmox ready — shastenm rice VMs           ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ISOs in $PVE_ISO_STORAGE ($ISO_DIR):"
    echo "    ${ISO_VOID:-<Void failed>}"
    echo "    ${ISO_SLACK:-<Slackware failed>}"
    echo "    ${ISO_FBSD:-<FreeBSD failed>}"
    echo "    shastenm-rice.iso"
    if [ ${#VM_IDS[@]} -gt 0 ]; then
        echo ""
        echo "  VMs (Console in the web UI, or ssh $VM_USER@<vm-ip>):"
        local v; for v in "${VM_IDS[@]}"; do echo "    ${v%%:*}  ${v#*:}"; done
    fi
    echo ""
    echo -e "${YELLOW}Logins:${NC} $VM_USER / $VM_PASS   (root / $VM_PASS)"
    local n st
    for n in void-shastenm slackware-shastenm freebsd-shastenm; do
        st="${VM_STATE[$n]:-not created}"
        case "$st" in
            ready)
                echo "  $n — OS installed. Booting now: dotfiles install by themselves, then it reboots" ;;
            selfinstall)
                echo "  $n — installing itself from its own installer, then reboots,"
                echo "                     installs the dotfiles, and reboots again" ;;
            exists) echo "  $n — already existed, left untouched (--rebuild to redo it)" ;;
            *)      echo -e "  $n — ${RED}$st${NC}" ;;
        esac
    done
    echo "  Watch any VM's dotfiles install:  tail -f /var/log/shastenm-rice.log"
    echo "  When a VM has rebooted the second time: log in as $VM_USER and run startx"
    echo "  (Slackware: startxfce4). Host build logs: $WORK_DIR/logs/"
    echo ""
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
    cp "$SELF" "$tmp/install.sh"
    local args=(--user-phase --no-packages)
    [ "$DO_FONTS" -eq 0 ]            && args+=(--no-fonts)
    [ "$OFFLINE" -eq 1 ]             && args+=(--offline)
    [ "$WITH_SPECTRWM_SLACK" -eq 1 ] && args+=(--with-spectrwm)
    [ "$ASSUME_YES" -eq 1 ]          && args+=(--yes)
    args+=(--nvim "$NVIM_DISTRO")
    cp -RPp "$DOTFILES_ROOT" "$tmp/dotfiles-bsd-main"; args+=("$tmp/dotfiles-bsd-main")
    if [ "$WANT_WM" -eq 1 ]; then cp -RPp "$SPECTRWM_ROOT" "$tmp/spectrwm-bsd-main"; args+=("$tmp/spectrwm-bsd-main"); fi
    if [ -n "$DMENU_SCRIPTS_ROOT" ]; then
        cp -RPp "$DMENU_SCRIPTS_ROOT" "$tmp/dmenu_scripts-main"
        args=(--dmenu-scripts "$tmp/dmenu_scripts-main" "${args[@]}")
    fi
    chmod -R a+rX "$tmp"

    local q="" a
    for a in "${args[@]}"; do q+=" $(printf '%q' "$a")"; done
    local rc=0
    su - "$TARGET_USER" -c "bash $tmp/install.sh$q" || rc=$?
    rm -rf "${tmp:?}"
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
if is_proxmox && [ "$USER_PHASE" -eq 0 ]; then
    proxmox_main
    exit 0
fi

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
DMENU_SCRIPTS_ROOT="$(find_root "sm-dmscr" "dmenu_scripts-main" "$ARG_DMENU_SCRIPTS" "$REPO_DMENU_SCRIPTS" optional)"
[ -n "$DMENU_SCRIPTS_ROOT" ] && info "dmenu scripts : $DMENU_SCRIPTS_ROOT"

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
deploy_dmenu_scripts
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
