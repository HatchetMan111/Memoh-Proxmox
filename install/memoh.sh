#!/usr/bin/env bash
#
# Memoh Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Memoh – Open-Source Multi-Agent Platform (jede Agent bekommt einen eigenen Computer)
# Upstream: https://github.com/felinics/Memoh
# Stack:    Go + TypeScript (offizielle Docker-Images) + PostgreSQL 18 + pgvector
# Läuft:    vollständig lokal im LXC, keine Cloud nötig (eigene API-Keys mitbringen)
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Memoh-Proxmox/main/install/memoh.sh)"
#   CT_ID=150 CORES=4 RAM=8192 DISK=30 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Memoh-Proxmox/main/install/memoh.sh)"
#   bash memoh.sh --ctid 150 --cores 4 --memory 8192 --disk 30 --bridge vmbr0 --debug
#
# WICHTIG: Memoh braucht mehr als die 1–2-GB-Faustregel. Der Upstream-Server läuft mit
# privileged:true + pid:host + mem_limit 8g + eigenem embedded containerd (Docker-in-Docker
# für Agent-Workspaces). Darum: PRIVILEGIERTER LXC mit nesting, 4 vCPU / 8 GB / 30 GB Minimum.
# Unprivilegiert oder mit 2 GB startet memoh-server nicht. Für Produktion ist eine VM robuster
# (siehe memoh-vm.sh + memoh-setup.sh im selben Repo).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="memoh"                                   # Container-Hostname + Service-Name
API_PORT="8080"                               # Memoh API (Upstream server:8080)
WEB_PORT="8082"                               # Memoh Web UI (Upstream web:8082)
SERVER_IMAGE="memohai/server:latest"
WEB_IMAGE="memohai/web:latest"

DEFAULT_CORES="4"                             # vCPU (unter 4 wird containerd+pgvector langsam)
DEFAULT_RAM="8192"                            # RAM in MB (Server allein hat mem_limit 8g!)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="30"                             # Disk in GB (Images + Workspaces, min. 30)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie (Docker-getestet)
UNPRIVILEGED="0"                              # 0 = privilegiert (Pflicht für Memoh, siehe oben)
FEATURES="nesting=1,keyctl=1"                 # nesting/keyctl = Docker-im-LXC nötig

# Umgebungs-Overrides: CT_ID=150 CORES=6 RAM=12288 DISK=40 ./memoh.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash memoh.sh [OPTIONEN]
  CT_ID=150 bash memoh.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Memoh-Proxmox/main/install/memoh.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES}, Minimum 4)
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 8192)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK}, Minimum 30)
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

[[ "$RAM" -ge 8192 ]] || { msg_error "RAM muss >= 8192 sein (memoh-server hat mem_limit 8g). Gewählt: $RAM"; exit 1; }
[[ "$CORES" -ge 4 ]] || msg_warn "Unter 4 vCPU wird es langsam (gewählt: $CORES)."
[[ "$DISK" -ge 30 ]] || { msg_error "Disk muss >= 30 GB sein (Images + Workspaces). Gewählt: $DISK"; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
TEMPLATE="$(pveam available --section system 2>/dev/null | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.[gx]z" | sort -V | tail -n1 || true)"
[[ -n "${TEMPLATE:-}" ]] || { msg_error "Kein ${DEFAULT_OS}-Template gefunden."; exit 1; }
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle privilegierten CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  # Unconfined AppArmor: nötig für Docker-in-Docker (embedded containerd im memoh-server)
  grep -q "lxc.apparmor.profile" "/etc/pve/lxc/${CT_ID}.conf" 2>/dev/null \
    || echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/${CT_ID}.conf"
  msg_ok "CT $CT_ID erstellt (privilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Docker + Memoh im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Docker im Container ..."
pct exec "$CT_ID" -- bash -c "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl openssl ca-certificates sudo
  if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \\\"\\\$VERSION_CODENAME\\\") stable\" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  docker compose version
  id memoh >/dev/null 2>&1 || useradd -m -s /bin/bash memoh
  usermod -aG docker memoh
  echo 'memoh ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/memoh
" 2>&1 | tail -n 20

msg_info "Installiere Memoh (Basis-Stack, silent, ohne Connect-It/Tunnel) ..."
pct exec "$CT_ID" -- su - memoh -c "
  set -euo pipefail
  export MEMOH_CONNECT_IT_MODE=disabled MEMOH_INSTALL_MODE=auto
  curl -fsSL https://memoh.sh | sh -s -- -y
" 2>&1 | tail -n 30

# systemd-Unit aus diesem Repo übernehmen (fällt auf Inline-Unit zurück)
SERVICE_URL="${MEMOH_SERVICE_URL:-https://raw.githubusercontent.com/HatchetMan111/Memoh-Proxmox/main/systemd/memoh.service}"
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/memoh.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "memoh.service aus Repo übernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/memoh.service <<'UNIT'
[Unit]
Description=Memoh Multi-Agent Platform (Docker Compose)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=memoh
WorkingDirectory=/home/memoh/memoh
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now memoh

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active memoh || { msg_error "systemd-Service memoh ist nicht active."; pct exec "$CT_ID" -- systemctl status memoh --no-pager || true; exit 1; }
msg_ok "Service läuft (systemctl is-active memoh = active)."
sleep 20  # Erststart zieht Images (1–2 Min beim allerersten Lauf möglich)
pct exec "$CT_ID" -- curl -fs -m 15 "http://localhost:${API_PORT}/" >/dev/null \
  || { msg_error "API antwortet nicht auf localhost:${API_PORT}."; pct exec "$CT_ID" -- docker compose -f /home/memoh/memoh/docker-compose.yml logs --tail=50 server || true; exit 1; }
msg_ok "API antwortet (HTTP 200 auf localhost:${API_PORT})."
pct exec "$CT_ID" -- curl -fs -m 15 "http://localhost:${WEB_PORT}/" >/dev/null \
  || { msg_error "Web UI antwortet nicht auf localhost:${WEB_PORT}."; pct exec "$CT_ID" -- docker compose -f /home/memoh/memoh/docker-compose.yml logs --tail=50 web || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${WEB_PORT})."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Memoh – Open-Source Multi-Agent Platform"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, privilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${WEB_PORT}"
echo "  API          : http://${CT_IP}:${API_PORT}"
echo "  Login        : aus Installer-Output (silent: zufällig generiert – im Log suchen)"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unverändert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status memoh  (im Container via: pct enter $CT_ID)"
echo "  Stack        : cd ~/memoh && docker compose ps / docker compose logs -f (als memoh)"
echo "  Update       : Skript erneut laufen lassen (idempotent, Upgrade-Modus)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 90 && curl -fs http://${CT_IP}:${WEB_PORT} >/dev/null"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
