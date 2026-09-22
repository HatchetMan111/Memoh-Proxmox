#!/usr/bin/env bash
# Memoh Basis-Setup IN der VM (als normaler User, NICHT als root).
# Installiert Docker + Compose-Plugin und danach den offiziellen Memoh-Stack:
#   postgres + pgvector + migrate + server + channel + web
# Ohne Connect-It (Port 8421) und ohne Webhook-Tunnel – exakt deine Wahl "Nur Basis".
#
# Gebrauch (per SSH in der VM, z.B. ssh memoh@<VM-IP>):
#   bash memoh-setup.sh
#   ADMIN_USER=admin ADMIN_PASS='...' PG_PASS='...' bash memoh-setup.sh  # optional Vorgaben
set -euo pipefail

[ "$(id -u)" != "0" ] || { echo "[XX] Nicht als root ausführen – als normaler User (z.B. memoh). Der Installer nutzt sudo intern."; exit 1; }

ADMIN_USER="${ADMIN_USER:-admin}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/memoh}"

log() { echo "[*] $*"; }
ok()  { echo "[OK] $*"; }
die() { echo "[XX] $*" >&2; exit 1; }

log "1/4 Pakete + Docker prüfen ..."
sudo apt-get update
sudo apt-get install -y git curl openssl ca-certificates gpg
if ! command -v docker >/dev/null; then
  log "Installiere Docker (offizielles Repo) ..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker info >/dev/null 2>&1 || sudo usermod -aG docker "$USER"
docker compose version >/dev/null || die "Docker Compose v2 fehlt."
ok "Docker + Compose bereit: $(docker compose version --short)"

# Falls Gruppe gerade erst hinzugefügt wurde: sg docker für den Rest des Skripts
if ! docker info >/dev/null 2>&1; then
  log "Aktiviere docker-Gruppe via sg (einmalig) ..."
  exec sg docker -c "bash $0"
fi

log "2/4 Firewall-Hinweis (falls ufw aktiv) ..."
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 8080/tcp comment 'Memoh API' || true
  sudo ufw allow 8082/tcp comment 'Memoh Web UI' || true
  sudo ufw allow 1455/tcp comment 'Memoh API alt' || true
  sudo ufw allow 30000/udp comment 'Memoh WebRTC Display' || true
fi

log "3/4 Memoh installieren (Basis, ohne Connect-It/Tunnel) ..."
export MEMOH_CONNECT_IT_MODE=disabled
export MEMOH_INSTALL_MODE="${MEMOH_INSTALL_MODE:-auto}"
# -y nur wenn explizit gewünscht; interaktiv stellt der Installer Rückfragen (Workspace, Passwörter).
if [ "${SILENT_INSTALL:-false}" = "true" ]; then
  curl -fsSL https://memoh.sh | sh -s -- -y
else
  curl -fsSL https://memoh.sh | sh
fi

log "4/4 Verifikation ..."
sleep 5
# Installationsort bestimmen (frische One-Click-Installation räumt das Clone-Verzeichnis weg)
if [ -d "$INSTALL_DIR/docker-compose.yml" ] || [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  cd "$INSTALL_DIR"
elif [ -d "$HOME/memoh" ]; then
  cd "$HOME/memoh"
fi
docker compose ps
curl -fs -m 10 http://localhost:8080/ >/dev/null 2>&1 && ok "API antwortet auf :8080" || echo "[!!] API noch nicht bereit – docker compose logs -f server prüfen (Erststart 1-2 Min)."
curl -fs -m 10 http://localhost:8082/ >/dev/null 2>&1 && ok "Web UI antwortet auf :8082" || echo "[!!] Web UI noch nicht bereit – docker compose logs -f web prüfen."

echo ""
echo "════════════════ MEMOH LÄUFT ════════════════"
echo "  Web UI : http://$(hostname -I | awk '{print $1}'):8082"
echo "  API    : http://$(hostname -I | awk '{print $1}'):8080"
echo "  Login  : $ADMIN_USER / (bei interaktiver Installation selbst vergeben, sonst aus Installer-Output)"
echo "  Stack  : docker compose ps / docker compose logs -f"
echo "  Update : curl -fsSL https://memoh.sh | sh   (Upgrade-Modus, config + DB bleiben)"
echo "  Stopp  : docker compose down   |   Start: docker compose up -d"
echo "═════════════════════════════════════════════"
