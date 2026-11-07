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
#       void-shastenm       built from Void's ROOTFS in a chroot
#       slackware-shastenm  DVD packages installed straight to disk
#       freebsd-shastenm    FreeBSD's own installer, run unattended
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
TARGET_USER=""; USER_PHASE=0; ISO_MODE=0; ISO_DIR=""
PVE_STORAGE=""; PVE_ISO_STORAGE=""; PVE_BRIDGE=""; PVE_VMS=1; PVE_START=1
VM_USER="ethan"; VM_PASS="1234"; PVE_REBUILD=0

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

    for z in "$SCRIPT_DIR"/*"$name"*.zip "$PWD"/*"$name"*.zip "$HOME/Downloads"/*"$name"*.zip \
             "$TARGET_HOME"/*"$name"*.zip "$TARGET_HOME/Downloads"/*"$name"*.zip; do
        [ -f "$z" ] && extract_zip "$z" && return
    done

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

ISO_VOID=""; ISO_SLACK=""; ISO_FBSD=""; ISO_FBSD_AUTO=""; VOID_ROOTFS=""
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
    local want_rootfs=0; [ "${DISTRO:-}" = proxmox ] && [ "$PVE_VMS" -eq 1 ] && want_rootfs=1
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

    # FreeBSD — newest RELEASE, disc1 (full installer, no network needed)
    for m in "${FBSD_MIRRORS[@]}"; do
        listing="$(fetch_listing "$m")"; [ -n "$listing" ] || { warn "FreeBSD: $m not reachable — next mirror"; continue; }
        ver="$(grep -oE '>[0-9]+\.[0-9]+/' <<<"$listing" | tr -d '>/' | sort -V -u | tail -n1 || true)"
        [ -n "$ver" ] || { warn "FreeBSD: no releases listed on $m — next mirror"; continue; }
        f="FreeBSD-$ver-RELEASE-amd64-disc1.iso"
        sum="$(get "$m/$ver/CHECKSUM.SHA256-FreeBSD-$ver-RELEASE-amd64" | grep -F "($f)" | awk '{print $NF}' || true)"
        [ -n "$sum" ] || { warn "FreeBSD: no checksum on $m — next mirror"; continue; }
        if fetch_iso "FreeBSD $ver" "$m/$ver/$f" "$f" 256 "$sum"; then ISO_FBSD="$f"; break; fi
    done
    [ -n "$ISO_FBSD" ] || { warn "FreeBSD: every mirror failed"; failed=1; }

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
    have sfdisk  || need+=(fdisk)
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
    rm -rf "${stage:?}/dotfiles-bsd-main/.git" "${stage:?}/spectrwm-bsd-main/.git"
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
chmod -R u+w "$W"
if ! command -v bash >/dev/null 2>&1; then
    if [ "$(uname -s)" = FreeBSD ]; then
        env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
        env ASSUME_ALWAYS_YES=yes pkg install -y bash
    else
        echo "bash is missing — install it first"; exit 1
    fi
fi
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

pve_existing_vm() {
    qm list 2>/dev/null | awk -v n="$1" 'NR>1 && $2==n {print $1; exit}'
}

# -----------------------------------------------------------------------------
# Disk-image helpers (run on the Proxmox host)
# -----------------------------------------------------------------------------
img_prepare() {
    # img_prepare <img> <size-GiB> <label>  → sets LOOP MNT ROOT_UUID
    local img="$1" size="$2" label="$3"
    rm -f "${img:?}"
    truncate -s "${size}G" "$img"
    printf 'label: dos\nlabel-id: 0x5ac0ffee\n,,L,*\n' | sfdisk -q "$img"
    LOOP="$(losetup -fP --show "$img")"
    local _ sysdev; for _ in 1 2 3 4 5; do [ -b "${LOOP}p1" ] && break; partx -u "$LOOP" 2>/dev/null || true; sleep 1; done
    if ! [ -b "${LOOP}p1" ]; then       # no udev: make the node from /sys
        sysdev="/sys/block/${LOOP##*/}/${LOOP##*/}p1/dev"
        [ -r "$sysdev" ] && mknod "${LOOP}p1" b "$(cut -d: -f1 "$sysdev")" "$(cut -d: -f2 "$sysdev")"
    fi
    [ -b "${LOOP}p1" ] || { echo "partition ${LOOP}p1 never appeared"; return 1; }
    # GRUB 2.06 (Slackware 15) can't read these newer ext4 features
    mkfs.ext4 -q -F -L "$label" -O ^metadata_csum_seed,^orphan_file "${LOOP}p1" 2>/dev/null \
        || mkfs.ext4 -q -F -L "$label" "${LOOP}p1"
    ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p1")"
    MNT="$WORK_DIR/mnt-$label"
    mkdir -p "$MNT"
    mount "${LOOP}p1" "$MNT"
}

chroot_prepare() {
    local d
    for d in dev dev/pts proc sys run; do mkdir -p "$MNT/$d"; done
    mount --rbind /dev  "$MNT/dev";  mount --make-rslave "$MNT/dev"
    mount -t proc proc  "$MNT/proc"
    mount --rbind /sys  "$MNT/sys";  mount --make-rslave "$MNT/sys"
    mount -t tmpfs tmpfs "$MNT/run"
    rm -f "$MNT/etc/resolv.conf"
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
}

in_chroot() {
    chroot "$MNT" /usr/bin/env -i HOME=/root TERM=xterm LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

img_cleanup() {
    [ -n "${MNT:-}" ] || return 0
    # stop anything the rice left running inside (tmux, gpg-agent, dbus…)
    local p r
    for p in /proc/[0-9]*; do
        r="$(readlink "$p/root" 2>/dev/null || true)"
        if [ "$r" = "$MNT" ]; then kill -9 "${p#/proc/}" 2>/dev/null || true; fi
    done
    sleep 1
    umount -R "$MNT" 2>/dev/null || umount -lR "$MNT" 2>/dev/null || true
    [ -n "${SRCMNT:-}" ] && { umount "$SRCMNT" 2>/dev/null || umount -l "$SRCMNT" 2>/dev/null || true; }
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
    MNT=""; LOOP=""; SRCMNT=""
}

write_grub_cfg() {
    # write_grub_cfg <title> <kernel> <initrd-or-empty> <root-arg> [<title2> <kernel2> <initrd2> <root2>]
    {
        echo "set timeout=2"
        echo "set default=0"
        while [ $# -ge 4 ]; do
            echo "menuentry \"$1\" {"
            echo "    insmod part_msdos"
            echo "    insmod ext2"
            echo "    search --no-floppy --fs-uuid --set=root $ROOT_UUID"
            echo "    linux $2 $4 ro"
            [ -n "$3" ] && echo "    initrd $3"
            echo "}"
            shift 4
        done
    } > "$MNT/boot/grub/grub.cfg"
}

install_grub_bios() {
    mkdir -p "$MNT/boot/grub"
    if in_chroot grub-install --target=i386-pc --boot-directory=/boot \
            --modules="part_msdos ext2 biosdisk" "$LOOP"; then
        return 0
    fi
    echo "guest grub-install failed — trying the host's grub"
    [ -d /usr/lib/grub/i386-pc ] || { echo "host has no BIOS grub modules either"; return 1; }
    grub-install --target=i386-pc --boot-directory="$MNT/boot" \
        --modules="part_msdos ext2 biosdisk" "$LOOP"
}

add_vm_user() {
    # add_vm_user <groups-wanted>
    local wanted="$1" g have=""
    for g in $wanted; do
        if in_chroot getent group "$g" >/dev/null 2>&1; then have="${have:+$have,}$g"; fi
    done
    in_chroot id "$VM_USER" >/dev/null 2>&1 || in_chroot useradd -m -G "$have" -s /bin/bash "$VM_USER"
    printf '%s:%s\nroot:%s\n' "$VM_USER" "$VM_PASS" "$VM_PASS" | in_chroot chpasswd
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

implant_rice() {
    # implant_rice [extra args] — copy the rice onto the new disk + arm first boot
    rm -rf "${MNT:?}/root/shastenm-rice"
    cp -RPp "$WORK_DIR/rice-cd" "$MNT/root/shastenm-rice"
    mkdir -p "$MNT/usr/local/sbin" "$MNT/var/db"
    firstboot_script "$@" > "$MNT/usr/local/sbin/shastenm-firstboot"
    chmod 755 "$MNT/usr/local/sbin/shastenm-firstboot"
    touch "$MNT/var/db/shastenm-firstboot"
    echo ">>> dotfiles implanted — they install automatically on the first boot"
}

# -----------------------------------------------------------------------------
# Void Linux — built from the official ROOTFS tarball in a chroot
# -----------------------------------------------------------------------------
build_void_image() {
    local img="$1" size="$2"
    img_prepare "$img" "$size" void
    echo ">>> unpacking $(basename "$VOID_ROOTFS")"
    tar xpf "$VOID_ROOTFS" --xattrs --xattrs-include='*' --numeric-owner -C "$MNT"
    chroot_prepare

    # generic initramfs (not tied to the Proxmox host's hardware) with virtio
    mkdir -p "$MNT/etc/dracut.conf.d"
    printf 'hostonly="no"\nadd_drivers+=" virtio_pci virtio_scsi virtio_blk virtio_net sd_mod ext4 "\n' \
        > "$MNT/etc/dracut.conf.d/10-shastenm.conf"

    echo ">>> installing base-system + kernel + grub"
    in_chroot xbps-install -Syu xbps
    in_chroot xbps-install -yu
    in_chroot xbps-install -y base-system grub
    in_chroot xbps-remove -y base-container-full 2>/dev/null || in_chroot xbps-remove -y base-voidstrap 2>/dev/null || true
    in_chroot xbps-reconfigure -fa

    echo ">>> configuring system"
    echo "void-shastenm" > "$MNT/etc/hostname"
    printf 'UUID=%s / ext4 defaults 0 1\ntmpfs /tmp tmpfs defaults,nosuid,nodev 0 0\n' "$ROOT_UUID" > "$MNT/etc/fstab"
    if [ -f "$MNT/etc/default/libc-locales" ]; then
        sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$MNT/etc/default/libc-locales"
        in_chroot xbps-reconfigure -f glibc-locales || true
    fi
    sed -i 's|^#\{0,1\}TIMEZONE=.*|TIMEZONE="America/Indiana/Indianapolis"|' "$MNT/etc/rc.conf" 2>/dev/null || true
    add_vm_user "wheel audio video input cdrom storage network"
    mkdir -p "$MNT/etc/sudoers.d"
    echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/wheel"; chmod 440 "$MNT/etc/sudoers.d/wheel"
    local s
    for s in dhcpcd sshd; do
        [ -d "$MNT/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" "$MNT/etc/runit/runsvdir/default/$s"
    done

    echo ">>> bootloader"
    install_grub_bios
    local kver
    kver="$(ls "$MNT/boot" | sed -n 's/^vmlinuz-//p' | sort -V | tail -n1)"
    [ -n "$kver" ] || { echo "no kernel in /boot"; return 1; }
    [ -f "$MNT/boot/initramfs-$kver.img" ] || in_chroot dracut -f "/boot/initramfs-$kver.img" "$kver"
    write_grub_cfg "Void Linux" "/boot/vmlinuz-$kver" "/boot/initramfs-$kver.img" "root=UUID=$ROOT_UUID"

    implant_rice
    # runit service: runs the first-boot rice, retries every 10 min until it works
    mkdir -p "$MNT/etc/sv/shastenm-firstboot"
    cat > "$MNT/etc/sv/shastenm-firstboot/run" <<'EOF'
#!/bin/sh
[ -f /var/db/shastenm-firstboot ] && /usr/local/sbin/shastenm-firstboot
if [ -f /var/db/shastenm-firstboot ]; then sleep 600; exit 1; fi
rm -f /etc/runit/runsvdir/default/shastenm-firstboot
exec sleep 1000000
EOF
    chmod 755 "$MNT/etc/sv/shastenm-firstboot/run"
    ln -sfn /etc/sv/shastenm-firstboot "$MNT/etc/runit/runsvdir/default/shastenm-firstboot"
    img_cleanup
}

# -----------------------------------------------------------------------------
# Slackware — packages installed from the DVD straight into the new disk
# -----------------------------------------------------------------------------
build_slackware_image() {
    local img="$1" size="$2"
    img_prepare "$img" "$size" slackware
    SRCMNT="$WORK_DIR/mnt-slackdvd"; mkdir -p "$SRCMNT"
    mount -o loop,ro "$ISO_DIR/$ISO_SLACK" "$SRCMNT"
    local tree; tree="$(find "$SRCMNT" -maxdepth 1 -type d -name 'slackware64' | head -n1)"
    [ -n "$tree" ] || { echo "no slackware64/ on the DVD"; return 1; }

    local tools="$WORK_DIR/pkgtools"
    rm -rf "${tools:?}"; mkdir -p "$tools"
    tar xf "$(ls "$tree"/a/pkgtools-*.t?z | head -n1)" -C "$tools"

    # Package install scripts chown files to Slackware's own users/groups
    # (utmp, shadow, slocate, …) — those only exist INSIDE the new system.
    # So: 1) lay down the core "a" series from the host just to get a working
    # bash/coreutils/tar/xz/pkgtools in the new root, then 2) chroot in and
    # (re)install everything with Slackware's own installpkg.
    local base=()
    while IFS= read -r f; do base+=("$f"); done < <(ls "$tree"/a/*.t?z 2>/dev/null | sort)
    echo ">>> stage 1/2: bootstrapping ${#base[@]} core packages from the host"
    ROOT="$MNT" "$tools/sbin/installpkg" --root "$MNT" --terse "${base[@]}" >/dev/null 2>&1 || true
    [ -x "$MNT/sbin/installpkg" ] && [ -x "$MNT/bin/bash" ] || { echo "core bootstrap failed"; return 1; }

    chroot_prepare
    mkdir -p "$MNT/mnt/slackdvd"
    mount --bind "$tree" "$MNT/mnt/slackdvd"
    in_chroot /sbin/ldconfig || true

    # a ap d l n x xap xfce = a full desktop install without KDE, TeX, Emacs, games
    local n; n="$(ls "$tree"/{a,ap,d,l,n,x,xap,xfce}/*.t?z 2>/dev/null | wc -l)"
    echo ">>> stage 2/2: installing $n Slackware packages inside the new system (takes a while)"
    in_chroot /bin/bash -c '
        cd /mnt/slackdvd || exit 1
        /sbin/upgradepkg --reinstall --terse a/*.t?z >/dev/null 2>&1
        for s in ap d l n x xap xfce; do
            [ -d "$s" ] || continue
            echo "    series $s"
            /sbin/installpkg --terse "$s"/*.t?z >/dev/null 2>&1
        done
        /sbin/ldconfig
        true'
    umount "$MNT/mnt/slackdvd" 2>/dev/null || umount -l "$MNT/mnt/slackdvd"
    rmdir "$MNT/mnt/slackdvd" 2>/dev/null || true
    umount "$SRCMNT"; SRCMNT=""
    [ -x "$MNT/usr/bin/startxfce4" ] || echo "warning: XFCE didn't install — check the log"

    echo ">>> configuring system"
    echo "slackware-shastenm.lan" > "$MNT/etc/HOSTNAME"
    printf '/dev/sda1 / ext4 defaults 1 1\ndevpts /dev/pts devpts gid=5,mode=620 0 0\nproc /proc proc defaults 0 0\ntmpfs /dev/shm tmpfs nosuid,nodev,noexec 0 0\n' > "$MNT/etc/fstab"
    sed -i 's/^USE_DHCP\[0\]=""/USE_DHCP[0]="yes"/' "$MNT/etc/rc.d/rc.inet1.conf" 2>/dev/null || true
    ln -sf /usr/share/zoneinfo/America/Indiana/Indianapolis "$MNT/etc/localtime"
    add_vm_user "users wheel audio video cdrom plugdev netdev power lp scanner"
    in_chroot usermod -g users "$VM_USER" 2>/dev/null || true
    chmod +x "$MNT/etc/rc.d/rc.sshd" 2>/dev/null || true

    echo ">>> bootloader"
    install_grub_bios
    local huge gen kver
    huge="$(ls "$MNT"/boot/vmlinuz-huge-* 2>/dev/null | sort -V | tail -n1)"
    gen="$(ls "$MNT"/boot/vmlinuz-generic-* 2>/dev/null | sort -V | tail -n1)"
    [ -n "$huge" ] || { echo "no huge kernel in /boot"; return 1; }
    if [ -n "$gen" ]; then
        kver="${gen##*/vmlinuz-generic-}"
        in_chroot mkinitrd -c -k "$kver" -f ext4 -r /dev/sda1 \
            -m virtio_pci:virtio_scsi:sd_mod:ext4 -u -o /boot/initrd.gz >/dev/null 2>&1 || true
    fi
    if [ -n "$gen" ] && [ -f "$MNT/boot/initrd.gz" ]; then
        write_grub_cfg "Slackware (huge)"    "/boot/${huge##*/}" "" "root=/dev/sda1" \
                       "Slackware (generic)" "/boot/${gen##*/}"  "/boot/initrd.gz" "root=/dev/sda1"
    else
        write_grub_cfg "Slackware (huge)"    "/boot/${huge##*/}" "" "root=/dev/sda1"
    fi

    local extra=(); [ "$WITH_SPECTRWM_SLACK" -eq 1 ] && extra+=(--with-spectrwm)
    implant_rice "${extra[@]}"
    # rc.local runs at the end of boot, after rc.inet1 has brought up DHCP
    touch "$MNT/etc/rc.d/rc.local"
    if ! grep -q shastenm-firstboot "$MNT/etc/rc.d/rc.local"; then
        printf '\n# shastenm: install the dotfiles on first boot\n[ -x /usr/local/sbin/shastenm-firstboot ] && /usr/local/sbin/shastenm-firstboot &\n' \
            >> "$MNT/etc/rc.d/rc.local"
    fi
    chmod 755 "$MNT/etc/rc.d/rc.local"
    img_cleanup
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
    rm -f "${out:?}"
    xorriso -indev "$ISO_DIR/$ISO_FBSD" -outdev "$out" \
        -map "$cfg" /etc/installerconfig -boot_image any replay >/dev/null 2>&1 \
        || { warn "Couldn't build the unattended FreeBSD ISO"; return 1; }
    ISO_FBSD_AUTO="$(basename "$out")"
    ok "Unattended FreeBSD installer → $PVE_ISO_STORAGE:iso/$ISO_FBSD_AUTO"
}

# -----------------------------------------------------------------------------
# Build one VM: image → Proxmox disk → start
# -----------------------------------------------------------------------------
pve_auto_vm() {
    # pve_auto_vm <name> <builder|freebsd> <size> <mem>
    local name="$1" builder="$2" size="$3" mem="$4" id log rc
    id="$(pve_existing_vm "$name")"
    if [ -n "$id" ]; then
        ok "$name already exists (VM $id) — leaving it alone (use --rebuild to start over)"
        VM_STATE[$name]="exists"; VM_IDS+=("$id:$name"); return 0
    fi
    log="$WORK_DIR/logs/$name.log"; mkdir -p "$WORK_DIR/logs"
    id="$(pvesh get /cluster/nextid)"

    if [ "$builder" = freebsd ]; then
        [ -n "$ISO_FBSD" ] || { warn "$name: FreeBSD ISO missing — skipping"; VM_STATE[$name]="skipped (no ISO)"; return 0; }
        build_freebsd_iso || { VM_STATE[$name]="failed (ISO remaster)"; return 0; }
        qm create "$id" --name "$name" --tags shastenm \
            --memory "$mem" --cores 2 --cpu host --ostype other \
            --scsihw virtio-scsi-single --scsi0 "$PVE_STORAGE:$size,discard=on,iothread=1" \
            --net0 "virtio,bridge=$PVE_BRIDGE" --vga std \
            --ide2 "$PVE_ISO_STORAGE:iso/$ISO_FBSD_AUTO,media=cdrom" \
            --ide0 "$PVE_ISO_STORAGE:iso/shastenm-rice.iso,media=cdrom" \
            --boot 'order=scsi0;ide2' >/dev/null
        ok "Created VM $id $name — installs FreeBSD by itself, reboots, then installs the dotfiles"
        VM_STATE[$name]="selfinstall"
    else
        local need_k free_k
        need_k=$(( 14 * 1048576 ))
        free_k="$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}')"
        if [ "$free_k" -lt "$need_k" ]; then
            warn "$name: only $((free_k/1048576))G free in $WORK_DIR (needs ~14G to build) — skipping"
            VM_STATE[$name]="skipped (host disk full)"; return 0
        fi
        local img="$WORK_DIR/$name.raw"
        section "Building $name (log: $log)"
        set +e
        ( set -euo pipefail; trap img_cleanup EXIT; "$builder" "$img" "$size" ) > >(tee "$log") 2>&1
        rc=$?
        set -e
        sleep 1
        if [ "$rc" -ne 0 ]; then
            warn "$name build failed (code $rc) — see $log"
            VM_STATE[$name]="failed — see $log"
            rm -f "${img:?}"; return 0
        fi
        info "Importing $name disk into $PVE_STORAGE"
        qm create "$id" --name "$name" --tags shastenm \
            --memory "$mem" --cores 2 --cpu host --ostype l26 \
            --scsihw virtio-scsi-single --scsi0 "$PVE_STORAGE:0,import-from=$img,discard=on,iothread=1" \
            --net0 "virtio,bridge=$PVE_BRIDGE" --vga std \
            --boot 'order=scsi0' >/dev/null
        rm -f "${img:?}"
        ok "Created VM $id $name — OS installed; dotfiles install on its first boot"
        VM_STATE[$name]="ready"
    fi
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
    info "Dotfiles root : $DOTFILES_ROOT"
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
        if [ -n "$VOID_ROOTFS" ]; then
            pve_auto_vm "void-shastenm" build_void_image "$size" "$mem"
        else
            warn "void-shastenm: Void ROOTFS missing — skipping"; VM_STATE[void-shastenm]="skipped (no ROOTFS)"
        fi
        if [ -n "$ISO_SLACK" ]; then
            pve_auto_vm "slackware-shastenm" build_slackware_image "$size" "$mem"
        else
            warn "slackware-shastenm: Slackware DVD missing — skipping"; VM_STATE[slackware-shastenm]="skipped (no DVD)"
        fi
        pve_auto_vm "freebsd-shastenm" freebsd "$size" "$mem"

        if [ "$PVE_START" -eq 1 ]; then
            local v
            for v in "${VM_IDS[@]}"; do
                if ! qm status "${v%%:*}" | grep -q running; then
                    qm start "${v%%:*}" && ok "Started ${v#*:} (VM ${v%%:*})" || warn "Couldn't start ${v#*:}"
                fi
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
                echo "  $n — installing FreeBSD by itself (~5-10 min), reboots, installs the"
                echo "                     dotfiles, then reboots again" ;;
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
