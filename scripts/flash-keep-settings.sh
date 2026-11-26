#!/usr/bin/env bash
# flash-keep-settings.sh -- full-flash a Thingino image onto a camera over SSH and keep its settings,
# also when the camera runs older firmware with a different flash layout (no backup partition, an old
# sysupgrade without -K). Run on a PC with ssh access to the camera.
#
#   scripts/flash-keep-settings.sh [options] <full-image.bin> <camera-ip>
#     --keep identity   (default) logins, Wi-Fi, hostname, time zone, SSH keys, presets: the camera comes
#                       back on the network; application configs start from the new image's defaults
#     --keep all        everything in the camera's /etc/cfg-backup.list (same firmware family only)
#     --dry-run         build and verify everything, upload nothing
#     --force           flash even if the camera's IMAGE_ID does not match the image name
#     --keep-copy DIR   save the image that was flashed (with the settings in it) to DIR
#
# Login: ssh keys, or the root password in $CAMERA_PASSWORD (uses sshpass; never printed).
#
# How: the settings are packed in the cfg-backup format (64-byte THNG_BCKUP header + tar[.gz]) and written
# into the image's own "backup" partition, found from the mtdparts= string in the image's U-Boot
# environment. The camera then writes the whole image from offset 0 (sysupgrade full upgrade), and the new
# firmware's S37cfg-autorestore restores the settings on first boot.
set -euo pipefail

KEEP=identity DRY=0 FORCE=0 COPYDIR=""
while [ $# -gt 0 ]; do
	case "$1" in
	--keep) KEEP=$2; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	--force) FORCE=1; shift ;;
	--keep-copy) COPYDIR=$2; shift 2 ;;
	-h | --help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) break ;;
	esac
done
[ $# -eq 2 ] || { sed -n '5,5p' "$0" | sed 's/^# *//'; exit 2; }
IMG=$1 IP=$2
case "$KEEP" in identity | all) ;; *) echo "--keep identity|all" >&2; exit 2 ;; esac
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SSHOPT=(-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=5)
if [ -n "${CAMERA_PASSWORD:-}" ]; then
	command -v sshpass >/dev/null || die "CAMERA_PASSWORD is set but sshpass is not installed"
	export SSHPASS=$CAMERA_PASSWORD
	cam() { sshpass -e ssh "${SSHOPT[@]}" "root@$IP" "$@"; }
else
	cam() { ssh "${SSHOPT[@]}" -o BatchMode=yes "root@$IP" "$@"; }
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# --- 1. camera identity and flash size ---------------------------------------------------------------------
say "camera $IP"
id=$(cam 'sed -n "s/^IMAGE_ID=//p" /etc/os-release' | tr -d '"\r')
flash=$(cam "awk '/\"all\"\$/{print \$2}' /proc/mtd")
[ -n "$id" ] && [ -n "$flash" ] || die "cannot read IMAGE_ID / flash size from the camera"
flash=$((0x$flash))
img_size=$(wc -c <"$IMG")
echo "    IMAGE_ID $id, flash $((flash / 1048576)) MiB; image $(basename "$IMG") $((img_size / 1048576)) MiB"
[ "$img_size" -eq "$flash" ] || die "image size $img_size does not match the camera flash ($flash)"
case "$(basename "$IMG")" in
*"$id"*) ;;
*) [ "$FORCE" = 1 ] || die "image name does not contain the camera's IMAGE_ID '$id' (use --force if you are sure)" ;;
esac

# --- 2. backup partition of the IMAGE ------------------------------------------------------------------------
parts=$(LC_ALL=C grep -a -o 'mtdparts=[a-z_]*:[0-9a-zA-Z@(),]*' "$IMG" | grep '(backup)' | head -1 || true)
[ -n "$parts" ] || die "the image has no backup partition in its mtdparts; it cannot carry settings"
off=0 bsize=0
IFS=, read -r -a plist <<<"${parts#*:}"
for p in "${plist[@]}"; do
	name=${p#*(}; name=${name%)}
	sz=${p%%(*}; sz=${sz%%@*}
	case "$sz" in *k) sz=$((${sz%k} * 1024)) ;; *[mM]) sz=$((${sz%[mM]} * 1048576)) ;; *) die "cannot parse '$p'" ;; esac
	if [ "$name" = backup ]; then bsize=$sz; break; fi
	off=$((off + sz))
done
[ "$bsize" -gt 0 ] || die "no backup partition found in '$parts'"
echo "    image backup partition: offset $off, $bsize bytes"

# --- 3. settings from the camera ------------------------------------------------------------------------------
IDENTITY="/etc/passwd /etc/passwd- /etc/shadow /etc/shadow- /etc/wpa_supplicant.conf /etc/hostname /etc/TZ /etc/timezone /etc/tz.user.json /etc/timezone.source /etc/ntp.source /etc/default/ntp.conf /etc/dropbear /root/.ssh/authorized_keys /etc/presets"
if [ "$KEEP" = identity ]; then
	list=$IDENTITY
else
	list=$(cam 'f=/etc/cfg-backup.list; [ -f $f ] && { echo $f; sed "s/#.*//" $f; }' | tr -s ' \n' ' ')
	[ -n "$list" ] || die "the camera has no /etc/cfg-backup.list; use --keep identity"
fi
say "collecting settings ($KEEP)"
cam "cd / && F=''; for p in $list; do [ -e \"\$p\" ] && F=\"\$F \${p#/}\"; done; [ -n \"\$F\" ] && tar -cf - \$F" >"$W/payload.tar"
[ -s "$W/payload.tar" ] || die "nothing collected from the camera"
echo "    $(tar -tf "$W/payload.tar" | grep -vc '/$') files: $(tar -tf "$W/payload.tar" | grep -v '/$' | tr '\n' ' ')"
gzip -9 -n -c "$W/payload.tar" >"$W/payload"
sz=$(wc -c <"$W/payload")
md5=$(md5sum "$W/payload" | cut -d' ' -f1)
[ "$((sz + 64))" -le "$bsize" ] || die "settings ($sz bytes) do not fit the image's backup partition ($bsize)"
{ printf 'THNG_BCKUP\nsize=%d\nmd5=%s\n' "$sz" "$md5"; } >"$W/header"
pad=$((64 - $(wc -c <"$W/header")))
head -c "$pad" /dev/zero | tr '\0' '\n' >>"$W/header"
cat "$W/header" "$W/payload" >"$W/blob"

# --- 4. image with the settings in its backup partition --------------------------------------------------------
cp "$IMG" "$W/fw.bin"
head -c "$bsize" /dev/zero | tr '\0' '\377' | dd of="$W/fw.bin" bs=1 seek="$off" conv=notrunc status=none
dd if="$W/blob" of="$W/fw.bin" bs=1 seek="$off" conv=notrunc status=none
[ "$(head -c 10 <(tail -c +$((off + 1)) "$W/fw.bin"))" = "THNG_BCKUP" ] || die "splice check failed"
[ "$(wc -c <"$W/fw.bin")" -eq "$img_size" ] || die "image size changed while splicing"
sha=$(sha256sum "$W/fw.bin" | cut -d' ' -f1)
echo "    settings ($sz bytes gzip) written at $off; image sha256 $sha"
if [ -n "$COPYDIR" ]; then
	mkdir -p "$COPYDIR"
	cp "$W/fw.bin" "$COPYDIR/$(basename "$IMG" .bin)-$(date +%Y%m%d-%H%M%S)-with-settings.bin"
	chmod 600 "$COPYDIR"/*-with-settings.bin
fi
[ "$DRY" = 1 ] && { say "dry run: nothing uploaded"; exit 0; }

# --- 5. upload, verify, flash --------------------------------------------------------------------------------
# Low-RAM cameras (64 MB, ~37 MB usable): /tmp is RAM, and older sysupgrade keeps the streamer running while it
# flashes. With an 8 MB image in /tmp that can run the camera out of memory part-way through the flash.
# Stop the streamer and other heavy daemons first, then require the image + 12 MiB of headroom.
say "freeing memory on the camera (streamer and helpers stopped; the flash reboots it anyway)"
cam 'for s in /etc/init.d/S31prudynt /etc/init.d/S31raptor /etc/init.d/S32raptor-motion /etc/init.d/S33raptor-privacy /etc/init.d/S9*; do [ -x "$s" ] && "$s" stop >/dev/null 2>&1; done; sync; echo 3 > /proc/sys/vm/drop_caches' || true
avail_kb=$(cam "awk '/^MemAvailable:/{print \$2}' /proc/meminfo")
[ -n "$avail_kb" ] || avail_kb=$(cam "awk '/^MemFree:/{f=\$2} /^Cached:/{c=\$2} END{print f+c}' /proc/meminfo")
need_kb=$((img_size / 1024 + 12288))
echo "    memory available ${avail_kb} KiB, need ${need_kb} KiB"
[ "$avail_kb" -gt "$need_kb" ] || die "not enough free memory on the camera (${avail_kb} KiB < ${need_kb} KiB); reboot it and retry"
free_kb=$(cam "df -k /tmp | awk 'NR==2{print \$4}'")
[ "$free_kb" -gt $((img_size / 1024 + 2048)) ] || die "only ${free_kb} KiB free in /tmp on the camera"
say "uploading"
cam 'cat > /tmp/fw.bin' <"$W/fw.bin"
[ "$(cam 'sha256sum /tmp/fw.bin' | cut -d' ' -f1)" = "$sha" ] || die "sha256 mismatch on the camera; not flashing"
say "flashing (the camera reboots when done; settings are restored on first boot)"
cam 'nohup sysupgrade -x /tmp/fw.bin >/tmp/sysupgrade.log 2>&1 &' || true
