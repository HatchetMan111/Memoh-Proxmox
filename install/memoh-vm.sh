#!/usr/bin/env bash
# Memoh VM auf Proxmox erstellen (Host als root).
# Standard: VMID 200, 4 vCPU / 8192 MB RAM / 40 GB Disk, Debian 13 Cloud-Image, vmbr0 DHCP.
# Nur Basis-Stack (kein Connect-It, kein Webhook-Tunnel) – wird in der VM per memoh-setup.sh installiert.
#
# Warum VM statt LXC:
#   memoh-server läuft mit privileged:true + pid:host + eigenem embedded containerd
#   (Docker-in-Docker für Agent-Workspaces). In LXC geht das nur privilegiert mit
#   nesting=1,keyctl=1 und ist fragil/unsicher. In einer KVM-VM läuft es stabil.
#
# Gebrauch (auf dem Proxmox-Host als root):
#   bash memoh-vm.sh
#   VMID=201 CORES=6 RAM=12288 DISK=60 bash memoh-vm.sh
#   bash memoh-vm.sh --vmid 200 --cores 4 --memory 8192 --disk 40 --storage local-lvm --bridge vmbr0
#   bash memoh-vm.sh --ciuser memoh --sshkey ~/.ssh/id_rsa.pub --ip 192.168.1.50/24 --gateway 192.168.1.1
#   bash memoh-vm.sh --debug
set -euo pipefail

VMID="${VMID:-200}"
NAME="${NAME:-memoh}"
CORES="${CORES:-4}"
RAM="${RAM:-8192}"
DISK="${DISK:-40}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CIUSER="${CIUSER:-memoh}"
SSHKEY="${SSHKEY:-}"
IPCFG="${IPCFG:-dhcp}"
GATEWAY="${GATEWAY:-}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2}"
IMAGE_DIR="/var/lib/vz/template/qcow"
LOG="/tmp/memoh-vm-install-$(date +%Y%m%d-%H%M%S).log"

log()  { echo "[*] $*" | tee -a "$LOG"; }
ok()   { echo "[OK] $*" | tee -a "$LOG"; }
warn() { echo "[!!] $*" | tee -a "$LOG" >&2; }
die()  { echo "[XX] $*" | tee -a "$LOG" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --ciuser) CIUSER="$2"; shift 2;;
    --sshkey) SSHKEY="$2"; shift 2;;
    --ip) IPCFG="ip=$2"; shift 2;;
    --gateway|--gw) GATEWAY="$2"; shift 2;;
    --debug) set -x; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) die "Unbekanntes Flag: $1 (siehe --help)";;
  esac
done

[ "$(id -u)" = "0" ] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v qm >/dev/null || die "qm nicht gefunden – kein Proxmox-Host?"
command -v pvesm >/dev/null || die "pvesm nicht gefunden."
command -v wget >/dev/null || command -v curl >/dev/null || die "wget oder curl erforderlich."

# VMID-Kollision -> nächste freie ID nehmen
if qm status "$VMID" >/dev/null 2>&1; then
  FREE_ID="$(pvesh get /cluster/nextid)"
  warn "VMID $VMID belegt – weiche auf freie ID $FREE_ID aus."
  VMID="$FREE_ID"
fi

pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage '$STORAGE' existiert nicht (pvesm ls)."
[ "$RAM" -ge 8192 ] || warn "Memoh Server hat mem_limit 8g – unter 8192 MB wird es eng (gewählt: $RAM)."
[ "$CORES" -ge 4 ] || warn "Unter 4 vCPU wird pgvector + containerd langsam (gewählt: $CORES)."
[ "$DISK" -ge 40 ] || warn "Unter 40 GB wird es mit Images + Workspaces eng (gewählt: $DISK)."

mkdir -p "$IMAGE_DIR"
IMAGE_FILE="$IMAGE_DIR/debian-${DEBIAN_VERSION}-generic-amd64-memoh.qcow2"
if [ ! -s "$IMAGE_FILE" ]; then
  log "Lade Debian $DEBIAN_VERSION Cloud-Image ..."
  if command -v wget >/dev/null; then wget -O "$IMAGE_FILE" "$IMAGE_URL"; else curl -fsSL -o "$IMAGE_FILE" "$IMAGE_URL"; fi
else
  ok "Cloud-Image vorhanden: $IMAGE_FILE"
fi

CIPASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
IPCONFIG="ip=dhcp"
[ "$IPCFG" != "dhcp" ] && IPCONFIG="$IPCFG"
[ -n "$GATEWAY" ] && IPCONFIG="$IPCONFIG,gw=$GATEWAY"

log "Erstelle VM $VMID ($NAME): $CORES vCPU / $RAM MB / ${DISK}G auf $STORAGE, Bridge $BRIDGE ..."
qm create "$VMID" \
  --name "$NAME" --ostype l26 \
  --cores "$CORES" --memory "$RAM" --balloon 0 \
  --agent enabled=1 \
  --onboot 1 \
  --scsihw virtio-scsi-pci \
  --net0 "virtio,bridge=$BRIDGE" \
  --ide2 "$STORAGE:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket --vga serial0 \
  --ciuser "$CIUSER" --cipassword "$CIPASS" \
  --ipconfig0 "$IPCONFIG" \
  --nameserver "1.1.1.1 8.8.8.8" 2>&1 | tee -a "$LOG"

if [ -n "$SSHKEY" ]; then
  [ -f "$SSHKEY" ] || die "SSH-Key nicht gefunden: $SSHKEY"
  qm set "$VMID" --sshkey "$SSHKEY" 2>&1 | tee -a "$LOG"
fi

log "Importiere Disk (${DISK}G) ..."
qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" 2>&1 | tee -a "$LOG"
# importdisk legt unused0 an – als scsi0 übernehmen (Name je nach Storage-Typ)
UNUSED="$(qm config "$VMID" | grep -oP '^unused0: \K[^,]+' | head -n1)"
[ -n "${UNUSED:-}" ] || die "unused0 nach importdisk nicht gefunden."
qm set "$VMID" --scsi0 "$UNUSED" 2>&1 | tee -a "$LOG"
qm resize "$VMID" scsi0 "${DISK}G" 2>&1 | tee -a "$LOG"

log "Starte VM ..."
qm start "$VMID" 2>&1 | tee -a "$LOG"

log "Warte auf QEMU-Guest-Agent (max. 5 Min) ..."
VMIP=""
for i in $(seq 1 60); do
  sleep 5
  if VMIP="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | grep -oP '"ip-address"\s*:\s*"\K(?!127\.|::1|fe80)[0-9a-fA-F:.]+' | head -n1)"; [ -n "${VMIP:-}" ]; then
    break
  fi
done

echo ""
echo "════════════════ MEMOH VM ERSTELLT ════════════════"
echo "  VM     : $VMID ($NAME) – $CORES vCPU / $RAM MB / ${DISK}G"
echo "  Bridge : $BRIDGE – ${IPCONFIG}"
echo "  IP     : ${VMIP:-<noch keine – qm guest cmd $VMID network-get-interfaces>}"
echo "  User   : $CIUSER / Passwort: $CIPASS  (nur jetzt angezeigt!)"
echo "  Log    : $LOG"
echo ""
echo "  Nächster Schritt (in der VM als $CIUSER, NICHT als root):"
echo "    ssh ${CIUSER}@${VMIP:-<VM-IP>}"
echo "    bash memoh-setup.sh   # installiert Docker + Memoh Basis-Stack"
echo ""
echo "  Danach: http://<VM-IP>:8082 (Web UI), http://<VM-IP>:8080 (API), Login admin/admin123 ändern!"
echo "  Deinstall: qm stop $VMID && qm destroy $VMID"
echo "════════════════════════════════════════════════════"
