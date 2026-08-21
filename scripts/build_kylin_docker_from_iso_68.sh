#!/usr/bin/env bash
# Build Kylin Server V11 aarch64 Docker image from local ISO on 68.
set -euo pipefail

ISO="${ISO:-/mnt/local/kylin-v11.iso}"
ISO_RAW="${ISO_RAW:-/mnt/local/Kylin-Server-V11-2503-Release-General-20250715-ARM64 (1).iso}"
MNT="${MNT:-/mnt/local/kylin-iso-mnt}"
WORKDIR="${WORKDIR:-/mnt/local/kylin-docker-build}"
ROOTFS="${ROOTFS:-${WORKDIR}/rootfs}"
LIVE_SQ="${LIVE_SQ:-${WORKDIR}/install-sq}"
LIVE_MNT="${LIVE_MNT:-${WORKDIR}/live-root}"
IMAGE_NAME="${IMAGE_NAME:-kylin-server}"
IMAGE_TAG="${IMAGE_TAG:-v11-2503-arm64}"
DNF_GROUP="${DNF_GROUP:-@server-product-environment}"

log() { echo "[kylin-docker] $*"; }

cleanup_mounts() {
  umount "${LIVE_MNT}/mnt/installroot" 2>/dev/null || true
  umount "${LIVE_MNT}/mnt/iso" 2>/dev/null || true
  umount "${LIVE_MNT}/sys" 2>/dev/null || true
  umount "${LIVE_MNT}/proc" 2>/dev/null || true
  umount "${LIVE_MNT}/dev" 2>/dev/null || true
  umount "${ROOTFS}/run" 2>/dev/null || true
  umount "${ROOTFS}/sys" 2>/dev/null || true
  umount "${ROOTFS}/proc" 2>/dev/null || true
  umount "${ROOTFS}/dev" 2>/dev/null || true
  umount "${LIVE_MNT}" 2>/dev/null || true
  umount "${MNT}" 2>/dev/null || true
}

trap cleanup_mounts EXIT

mkdir -p "$WORKDIR" "$MNT" "$LIVE_SQ" "$LIVE_MNT"
[[ -f "$ISO" ]] || ln -sf "$ISO_RAW" "$ISO"

if ! mountpoint -q "$MNT"; then
  log "mount ISO -> $MNT"
  mount -o loop,ro "$ISO" "$MNT"
fi

if ! mountpoint -q "$LIVE_MNT"; then
  log "extract installer live rootfs (for dnf bootstrap)"
  if [[ ! -f "${LIVE_SQ}/LiveOS/rootfs.img" ]]; then
    rm -rf "$LIVE_SQ"
    unsquashfs -f -d "$LIVE_SQ" "${MNT}/images/install.img"
  fi
  mount -o loop "$LIVE_SQ/LiveOS/rootfs.img" "$LIVE_MNT"
fi

mount --bind /dev "${LIVE_MNT}/dev"
mount --bind /proc "${LIVE_MNT}/proc"
mount --bind /sys "${LIVE_MNT}/sys"

DNF="${LIVE_MNT}/usr/bin/dnf"
[[ -x "$DNF" ]] || { log "dnf not found in live root"; exit 1; }

log "prepare installroot $ROOTFS"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{dev,proc,sys,run,tmp,var/tmp}
mkdir -p "${LIVE_MNT}/mnt/iso" "${LIVE_MNT}/mnt/installroot"

mount --bind /dev "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"
mount --bind "$MNT" "${LIVE_MNT}/mnt/iso"
mount --bind "$ROOTFS" "${LIVE_MNT}/mnt/installroot"
mount --bind /proc "${ROOTFS}/proc"
mount --bind /sys "${ROOTFS}/sys"

log "dnf install $DNF_GROUP (may take several minutes)"
chroot "$LIVE_MNT" /usr/bin/dnf \
  --installroot=/mnt/installroot \
  --releasever=V11 \
  --nogpgcheck \
  --setopt=install_weak_deps=False \
  -y \
  --repofrompath="kylin-iso,file:///mnt/iso" \
  install "$DNF_GROUP"

log "post-install cleanup"
rm -f "${ROOTFS}"/etc/yum.repos.d/kylin-iso.repo
rm -rf "${ROOTFS}"/var/cache/dnf/* "${ROOTFS}"/var/cache/yum/* 2>/dev/null || true
rm -f "${ROOTFS}"/etc/machine-id
touch "${ROOTFS}"/etc/machine-id
rm -rf "${ROOTFS}"/root/.bash_history

cat > "${ROOTFS}/etc/yum.repos.d/kylin-iso.repo" <<EOF
[kylin-iso]
name=Kylin ISO Local
baseurl=file://${MNT}
enabled=0
gpgcheck=0
EOF

log "docker import"
TAR="${WORKDIR}/kylin-rootfs.tar"
rm -f "$TAR"
tar -C "$ROOTFS" --numeric-owner -cpf "$TAR" .
docker import "$TAR" "${IMAGE_NAME}:${IMAGE_TAG}"
docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${IMAGE_NAME}:latest"

log "done"
docker images "${IMAGE_NAME}"
docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" cat /etc/os-release
docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" uname -m
