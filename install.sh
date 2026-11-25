#!/usr/bin/env bash
# =============================================================================
#  install.sh - fully automatic Arch Linux install with roosta's 2017 dotfiles
#
#  Boot the Arch ISO, get online, then:   bash install.sh
#
#  It will, without asking:
#    1. pick the install disk (the biggest internal disk, never the USB stick
#       you booted from) and ERASE it - 10 second countdown, Ctrl-C to stop
#    2. partition it: UEFI -> 1 GiB EFI + root, BIOS -> 1 MiB BIOS-boot + root
#       (ext4; swap is zram, so no swap partition)
#    3. install Arch: base, kernel, firmware, CPU microcode, NetworkManager,
#       GRUB, sudo, zsh, git, base-devel; enable [multilib]
#    4. set up: hostname lintilla (roosta's machine - his polybar needs it),
#       timezone, en_US.UTF-8, US keyboard, user "ethan" / password "1234"
#       (in group wheel, sudo), root locked
#    5. run the bundled dots.sh as ethan inside the new system: roosta's
#       dotfiles as in his Nov 2017 screenshots (i3, polybar, termite, rofi,
#       wallpaper, right-click menus, ...) - packages, AUR, everything
#    6. log ethan in automatically on tty1, which starts X and i3, and reboot
#
#  Options (environment variables or flags):
#    --yes / YES=1            no 10 second countdown before erasing the disk
#    DISK=/dev/nvme0n1        install to this disk instead of picking one
#    TIMEZONE=Region/City     default: America/Indiana/Indianapolis
#    USERNAME=ethan PASSWORD=1234 INSTALL_HOSTNAME=lintilla
#    WIFI_SSID=... WIFI_PASS=...   connect to Wi-Fi first (wired needs nothing)
#    AUTOLOGIN=0              ask for the password at boot instead
#    NO_REBOOT=1              stay in the ISO at the end
#    DOTS_ARGS="..."          extra arguments for dots.sh (see dots.sh --help)
#
#  Log of everything: /root/install.log on the ISO, and
#  /var/log/install.log in the new system.
# =============================================================================

set -Eeuo pipefail

USERNAME="${USERNAME:-ethan}"
PASSWORD="${PASSWORD:-1234}"
HOSTNAME="${INSTALL_HOSTNAME:-lintilla}"   # (bash sets $HOSTNAME itself, so the option has another name)
TIMEZONE="${TIMEZONE:-America/Indiana/Indianapolis}"
LOCALE="en_US.UTF-8"
KEYMAP="us"
DISK="${DISK:-}"
YES="${YES:-0}"
AUTOLOGIN="${AUTOLOGIN:-1}"
NO_REBOOT="${NO_REBOOT:-0}"
DOTS_ARGS="${DOTS_ARGS:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
MNT=/mnt
LOG=/root/install.log

for a in "$@"; do
  case $a in
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,/^# ====/p' "$0" | sed -e '/^# ====/d' -e 's/^# \{0,2\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then C_Y=$'\033[0;33m'; C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_M=$'\033[1;35m'; C_N=$'\033[0m'
else C_Y=''; C_G=''; C_R=''; C_M=''; C_N=''; fi
log()  { printf '%s==> %s%s\n' "$C_Y" "$*" "$C_N"; }
ok()   { printf '%s✔  %s%s\n' "$C_G" "$*" "$C_N"; }
die()  { printf '%s✖  %s%s\n' "$C_R" "$*" "$C_N" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND (full log: $LOG)"' ERR

exec > >(tee -a "$LOG") 2>&1

# -----------------------------------------------------------------------------
# 0. Checks
# -----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run this as root from the Arch ISO"
command -v pacstrap >/dev/null && command -v arch-chroot >/dev/null \
  || die "pacstrap/arch-chroot not found - boot the Arch Linux ISO and run this there"
[[ $(uname -m) == x86_64 ]] || die "x86_64 only"

if [[ -n $WIFI_SSID ]]; then
  log "Connecting to Wi-Fi ${WIFI_SSID}..."
  dev="$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')"
  [[ -n $dev ]] || die "no Wi-Fi device found"
  iwctl --passphrase "$WIFI_PASS" station "$dev" connect "$WIFI_SSID" || die "Wi-Fi connect failed"
  sleep 5
fi
for _ in 1 2 3 4 5 6; do ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 && break; sleep 5; done
ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 \
  || die "no internet - plug in a cable, or: WIFI_SSID=name WIFI_PASS=secret bash install.sh"
timedatectl set-ntp true || true

if [[ -d /sys/firmware/efi/efivars ]]; then BOOTMODE=uefi; else BOOTMODE=bios; fi
ok "online, booted in ${BOOTMODE^^} mode"

# -----------------------------------------------------------------------------
# 1. Disk
# -----------------------------------------------------------------------------
iso_disk() {  # the disk the ISO was booted from (never install there)
  local src
  src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
  [[ -n $src ]] || src="$(findmnt -no SOURCE /run/archiso/img_dev 2>/dev/null || true)"
  [[ -n $src ]] && lsblk -no PKNAME "$src" 2>/dev/null | head -n 1
}

pick_disk() {  # biggest internal (non-removable, non-USB) disk that is not the ISO
  local skip; skip="$(iso_disk || true)"
  # key="value" output: empty columns (e.g. TRAN on virtual disks) stay in place
  lsblk -dbnpP -o NAME,SIZE,TYPE,RM,TRAN,RO 2>/dev/null \
    | sed -E 's/([A-Z]+)="([^"]*)"/\1=\2/g' \
    | while read -r name size type rm tran ro; do
        name=${name#NAME=}; size=${size#SIZE=}; type=${type#TYPE=}; rm=${rm#RM=}; tran=${tran#TRAN=}; ro=${ro#RO=}
        [[ $type == disk && $rm == 0 && $ro == 0 && $tran != usb && $name != "/dev/${skip}" ]] || continue
        [[ $name =~ ^/dev/(loop|zram|sr|fd) ]] && continue
        echo "$size $name"
      done | sort -nr | awk 'NR == 1 {print $2}'
}

if [[ -z $DISK ]]; then
  DISK="$(pick_disk)"
  [[ -n $DISK ]] || die "no internal disk found - set DISK=/dev/... (lsblk shows them)"
fi
[[ -b $DISK ]] || die "$DISK is not a disk"
[[ "/dev/$(iso_disk || true)" != "$DISK" ]] || die "$DISK is the USB stick the ISO runs from"
size_gb=$(( $(lsblk -dbno SIZE "$DISK") / 1000000000 ))
((size_gb >= 20)) || die "$DISK is only ${size_gb} GB - at least 20 GB is needed (roosta's package list is big)"
model="$(lsblk -dno MODEL "$DISK" 2>/dev/null | xargs || true)"

printf '\n%s' "$C_R"
echo "  ███  ALL DATA ON ${DISK} (${model:-disk}, ${size_gb} GB) WILL BE ERASED  ███"
printf '%s\n' "$C_N"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK" || true
if ((YES == 0)); then
  for i in 10 9 8 7 6 5 4 3 2 1; do printf '\r  erasing in %2d s - press Ctrl-C to stop ' "$i"; sleep 1; done
  echo
fi

# -----------------------------------------------------------------------------
# 2. Partition, format, mount
# -----------------------------------------------------------------------------
log "Partitioning ${DISK} (${BOOTMODE})..."
umount -R "$MNT" 2>/dev/null || true
swapoff -a 2>/dev/null || true
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do umount "$p" 2>/dev/null || true; done
wipefs -af "$DISK" >/dev/null
sgdisk --zap-all "$DISK" >/dev/null
if [[ $BOOTMODE == uefi ]]; then
  sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI -n 2:0:0 -t 2:8304 -c 2:root "$DISK" >/dev/null
else
  sgdisk -n 1:0:+1M -t 1:ef02 -c 1:BIOSBOOT -n 2:0:0 -t 2:8304 -c 2:root "$DISK" >/dev/null
fi
partprobe "$DISK" 2>/dev/null || true
udevadm settle
part() { if [[ $DISK =~ [0-9]$ ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi; }
P1="$(part 1)"; P2="$(part 2)"
for _ in 1 2 3 4 5; do [[ -b $P2 ]] && break; sleep 1; done
[[ -b $P2 ]] || die "partition $P2 did not appear"

log "Formatting..."
mkfs.ext4 -F -L arch "$P2" >/dev/null
mount "$P2" "$MNT"
if [[ $BOOTMODE == uefi ]]; then
  mkfs.fat -F 32 -n EFI "$P1" >/dev/null
  mount --mkdir "$P1" "$MNT/boot"
fi
ok "${DISK}: $( [[ $BOOTMODE == uefi ]] && echo "EFI ${P1} (1 GiB), " )root ${P2} (ext4)"

# -----------------------------------------------------------------------------
# 3. Base system
# -----------------------------------------------------------------------------
log "Installing the base system (pacstrap)..."
ucode=""
grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode
reflector --country US --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || true
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
pkgs=(base linux linux-firmware linux-headers base-devel sudo git zsh vim networkmanager
      grub efibootmgr os-prober zram-generator man-db man-pages
      mesa xorg-server xorg-xinit xorg-server-xvfb)
[[ -n $ucode ]] && pkgs+=("$ucode")
pacman -Sy --noconfirm archlinux-keyring >/dev/null || true
pacstrap -K "$MNT" "${pkgs[@]}"
genfstab -U "$MNT" >> "$MNT/etc/fstab"
ok "base system installed"

# -----------------------------------------------------------------------------
# 4. Configure (inside the new system)
# -----------------------------------------------------------------------------
log "Configuring: ${HOSTNAME}, ${TIMEZONE}, ${LOCALE}, user ${USERNAME}..."
cat > "$MNT/root/configure.sh" <<EOF
set -euo pipefail
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i 's/^#${LOCALE} UTF-8/${LOCALE} UTF-8/' /etc/locale.gen
locale-gen >/dev/null
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}\n' > /etc/hosts

# pacman: parallel downloads, colour, [multilib] (roosta's list has steam/wine)
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/; s/^#Color/Color/' /etc/pacman.conf
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
pacman -Sy --noconfirm >/dev/null

# swap in RAM (zram), SSD trim, network
printf '[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd\n' > /etc/systemd/zram-generator.conf
systemctl enable NetworkManager fstrim.timer >/dev/null 2>&1

# user: ${USERNAME}, wheel may sudo; root is locked
id -u "${USERNAME}" >/dev/null 2>&1 || useradd -m -G wheel,video,audio,input,storage -s /bin/zsh "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
passwd -l root >/dev/null
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# boot loader
if [[ "${BOOTMODE}" == uefi ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB >/dev/null
  grub-install --target=x86_64-efi --efi-directory=/boot --removable >/dev/null   # firmware fallback path
else
  grub-install --target=i386-pc "${DISK}" >/dev/null
fi
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
EOF
arch-chroot "$MNT" bash /root/configure.sh
rm -f "$MNT/root/configure.sh"
ok "system configured, GRUB installed"

# -----------------------------------------------------------------------------
# 5. roosta's dotfiles: the bundled dots.sh, run as the user in the new system
# -----------------------------------------------------------------------------
log "Installing roosta's dotfiles as ${USERNAME} (dots.sh - this takes a while)..."
home="$MNT/home/${USERNAME}"
sed -n '/^__DOTS_SH_BELOW__$/,/^__DOTS_SH_END__$/p' "$0" | sed '1d;$d' | base64 -d | gunzip > "$home/dots.sh"
chmod 755 "$home/dots.sh"
arch-chroot "$MNT" chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/dots.sh"
# sudo without a password while dots.sh runs (removed right after)
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "$MNT/etc/sudoers.d/99-installer"
chmod 440 "$MNT/etc/sudoers.d/99-installer"
set +e
# shellcheck disable=SC2086
arch-chroot "$MNT" runuser -l "${USERNAME}" -c "cd ~ && bash ./dots.sh ${DOTS_ARGS}"
dots_rc=$?
set -e
rm -f "$MNT/etc/sudoers.d/99-installer"
((dots_rc == 0)) && ok "dotfiles installed" \
  || printf '%s!  dots.sh ended with code %s - log in and run: bash ~/dots.sh%s\n' "$C_Y" "$dots_rc" "$C_N"

# -----------------------------------------------------------------------------
# 6. Log in automatically on tty1 (the repo's .zprofile then runs startx -> i3)
# -----------------------------------------------------------------------------
if ((AUTOLOGIN)); then
  mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
  cat > "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o '-p -f -- \\\\u' --noclear --autologin ${USERNAME} %I \$TERM
EOF
  ok "autologin: ${USERNAME} on tty1 -> X -> i3"
fi

cp "$LOG" "$MNT/var/log/install.log" 2>/dev/null || true
sync
umount -R "$MNT"

printf '\n%s' "$C_M"
cat <<EOF
Done. Arch Linux + roosta's 2017 dotfiles are on ${DISK}.
  user: ${USERNAME}   password: ${PASSWORD}   hostname: ${HOSTNAME}
  Remove the USB stick. After the reboot ${USERNAME} is logged in and i3 starts.
  Change the password once you are in:  passwd
EOF
printf '%s\n' "$C_N"
if ((NO_REBOOT == 0)); then
  for i in 10 9 8 7 6 5 4 3 2 1; do printf '\r  rebooting in %2d s (Ctrl-C to stay) ' "$i"; sleep 1; done
  echo
  reboot
fi
exit 0

# The bundled dots.sh (gzip + base64). Do not edit below this line.
: <<'__DOTS_SH_END__'
__DOTS_SH_BELOW__
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
MLGynwedxBtGQ5lgTBpy1PNcwsStxU0rm/DvUZVVuc2m5wwYLy/BgEN8WDqMGmY20oVV3WVrrQPU
uuz5GgXraFnCh7cGEZ0kcgGXCZo/o8mkg8ATVtlb2x/evH/1apnBCMfjnE+VgjE9tLuxqWdMxlt1
RW3KpizTtDfuHF82aVVe4R9esc1Ir1xZt/SsF3DeasghbIaKFVR49oaMjahTWDuxniVblmqkpk6y
lG5Zgi+HXEIEBbWDUkbm8E78WYvsFdJjR587kNYNu044jooQfiCxBtzm6SiIO7mIXbqXBcj+k6u+
d8xLaU2kcUqS9iMF8XKXLqrRTFVmqbzqF60veyYKM7fzWuxkqTZNYOHBLbxkcjjQ+Jd5TXPqgLnN
kyeqov8ixoi0TlJ1VWf0YJY8F1WtTLQrQfxA53CcsUGo6OZwjKJsHxvm1LEVeMuWXNTVxFkm2YL2
7W+/2/QNLkhqxN4PYXUDPZvhx4fDr18rVW9nYplthwMo3KCwX1aoEJDDigl3ar9tm7e0I+ra8RX/
tXRfx8PLAIcfHXs4NLUrk1AuHdTC4/CkWu9pFTqKL6MeXwn5V6q6QywodE7p7fIB8qCHCZPo/l0v
6PBOe7fZ2nizj/g3J9PB13jEezLNAL/6agj4whd3k53N51eDjefJ5sbqh5XPV/dOjwevNx786/Lp
ONk52d45XntwMZq+3fnt2Zevn9uX797cfbq0G+7ttZOPr05Xlt4/6O3vPbg/ehX2Cw/ufhidXryq
v1kdxjvti9dft7pb71/u/P5g/OnzeO1fL798ebkyeFR/24s+nCYfat2P9989Wo1H/3rRf3C/+2b3
xbs3D+qfxw8fdjf6+wXigAaj1S+jePrh43h//Oneo/cnT8d3H15+7uwtdXovVocvzq5O7n3888OD
46U/e2cfw/6bZ/uvOtHr+vndcPtT/emXkw/JTnRv+/OXwpfhyocPj74+m/YeTEZntOP33p+8vJqe
bXd60/sJ1bz24G79c9R7+2H4svP0t4uXb1Z/i19/Xd0+e7l2tTc9PXk/eLnxspO0d0bjwv3V7ue3
4ccP0b9+f/r1ze5rKnH1943Rzsb+4Mto+Ob05CS69+rRxtO3o348vPu6c/f3jbOTrf1x3P/z6sPG
3srJ6wcvPpz9/nxnY/uscLLz+/3NtycbL8KNrc7O07fvzto7n9/ffX/y7Pf9/ee99lLy/M8P/c3t
/a8Ptztb73pb0+fvv359VP+QjF/fX7v36uMkevXoU7L68v5er7BW+1d4fHn+/tPV6uYJzdxu9835
v87PVp7u/dlbGk6n0eXvn+8/2BosbU7udX7717P3yfOHG++3tjuno8mLe79fPR3t0UTuf77/5uOH
wv7Oq7Uvm1H4fPT7b5/Hrx/Fk9reb6OnL35/v/TyInrYvVu/DOPOq2dvu0vP3r35/OfvH3urvd/u
b9x/sbTzfNx5ePL0zcVGcv+yvXvvY2H0qP38S693Mvp49tuLZ3/WP7/88KI3uLof3d/bjjv93bXz
e73w/dpve+Hes5XhZf3NeXJ1v93Z+33j6tPw0e/h0+eT1/96tPbiJVGWwuT98603k0fTsPNnn3jl
2rut3m9b21//TGq/vw1Ptrbu//lm8PLN2m/d+3sbz1+v7J53Pz68nJz+Odl78+rjo+hiaf+3pc7G
6cXr11fjws7V5/OLt7/v/bn/7vzr12R4L1qpr33c2ZjufN06je496258fva8+669dK/TD9+vPBqs
vvxUf/Di7dP6n+Mv9+Lzd09f/La5dd7eWtlbKZy++O3N+42NjYLagdaJaGEFQQWMPZ1/M9NfDWpO
RajMDLlj4mSIm6Z8BVQ472KWbvwZ1iCvfUJrdckNxubXGgywV+e+V15pMNWuN74mp95qg93gAeqB
l4pus/gGPQPITo9N72fg970y6ClRSENy1+qPLh/chUG8Ng5XFpIPHhFdq6/h30ePdCDCdU8i+N1d
q62tsEiHAT2BK0RcGt25vJonmg0uox93OnS+3L9be6QSQ5MOdcV5SK0XgYpSm7jEGKOhiPGcqWW9
znesGowVQGaSnRGeM8FsuTIdSCAB2LJb8k8drmDgiQJu3ducjHtBm7r27y//9r5MY3WtV9e4amG/
SfMIk6RfpPLTMNFABdC/+cV9P9dJA+El4cEMdxUONbkucdL0OxPCkkslzjsttSMmTlRwMJCFEmAF
ohR6BVSysoqXGcB+3RcMM17RNG6+XabWqnZUWxt1LvSrBj5DptszrHIGXrZWPcm4XQO7wKYv8DTi
Vc6A55E4nqNAdU/Fecyl9X2vtHBNN6KoFXfE45pXkk7PG8E0gZq46wXPnCxSDuqgZvVoD9zxSsys
qrXIZdLi/R+XeP/unbxuqlqwCZbqD+sQXQJkujpOSmYO3brOVZfjDpdbX9UtxRYC9NI5um0ZqLJf
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
__DOTS_SH_END__
