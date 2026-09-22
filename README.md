# Memoh auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/felinics/Memoh`
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft aus den offiziellen Images (`memohai/server`, `memohai/web`,
> `postgres:18-alpine`, `pgvector/pgvector:pg18`) – vollständig lokal, keine Cloud nötig
> (eigene LLM-API-Keys mitbringen).

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Memoh-Proxmox/main/install/memoh.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=4 RAM=8192 DISK=30 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Memoh-Proxmox/main/install/memoh.sh)"
bash memoh.sh --ctid 150 --cores 4 --memory 8192 --disk 30 --bridge vmbr0 --storage local-lvm
bash memoh.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/memoh-install-*.log
```

> Dieses Repo ist der Installer (`HatchetMan111/Memoh-Proxmox`).
> Die systemd-Unit liegt unter `systemd/memoh.service` desselben Repos und wird
> vom Installer von dort geladen (Fallback: Inline-Unit im Script).

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `memoh` |
| Zweck | Multi-Agent Platform – jeder Agent bekommt eigenen Computer (Dateisystem, Desktop, Browser, Memory) |
| Tech-Stack | Go + TypeScript (Docker) + PostgreSQL 18 + pgvector |
| Web UI | `http://<LXC-IP>:8082`, API `http://<LXC-IP>:8080` (bind `0.0.0.0` via Docker-Ports) |
| Standard-Ressourcen | 4 vCPU / 8192 MB RAM / 30 GB Disk (**bewusst über** der 1–2-GB-Faustregel: `memoh-server` hat `mem_limit 8g`, `privileged:true`, `pid:host`, embedded containerd) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **privilegiert** (`--unprivileged 0`), `nesting=1,keyctl=1`, `lxc.apparmor.profile: unconfined`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den **privilegierten** LXC `memoh` (`onboot: 1`, `nesting=1,keyctl=1`, AppArmor unconfined),
3. installiert im Container Docker + Compose-Plugin, legt User `memoh` an,
   startet den offiziellen Upstream-Installer silent (`MEMOH_CONNECT_IT_MODE=disabled`,
   Basis-Stack ohne Connect-It/Tunnel), schreibt `memoh.service`, `systemctl enable --now memoh`,
4. verifiziert `systemctl is-active memoh` + HTTP auf `localhost:8080` und `localhost:8082`
   und gibt beide finalen URLs + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active memoh = active).
[OK]    API antwortet (HTTP 200 auf localhost:8080).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8082).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Memoh – Open-Source Multi-Agent Platform
  Container    : CT 100 (Hostname: memoh, privilegiert, onboot=1)
  Ressourcen   : 4 vCPU / 8192 MB RAM / 30 GB Disk
  Web UI       : http://192.168.1.100:8082
  API          : http://192.168.1.100:8080
  ...
  Log          : /tmp/memoh-install-2026-....log
══════════════════════════════════════════════════════════
```

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 90
pct exec $CT -- systemctl is-active memoh
curl -fs http://<LXC-IP>:8082 >/dev/null && echo WEB_UI_OK
curl -fs http://<LXC-IP>:8080 >/dev/null && echo API_OK
```

## Update / Deinstall

```bash
bash memoh.sh --ctid 100            # Update: idempotent, Upstream-Upgrade-Modus (config + DB bleiben)
pct stop 100 && pct destroy 100     # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/memoh-install-*.log`.
- `bash memoh.sh --debug` für `bash -x`-Trace.
- Im Container (als `memoh`): `docker compose ps`, `docker compose logs -f server channel web`.

## Dateien

- `install/memoh.sh` – Proxmox-Einzeiler (Host, root).
- `install/memoh-vm.sh` + `install/memoh-setup.sh` – **Produktions-Alternative als VM** (robuster als privilegiertes LXC): erst VM erstellen, dann Setup in der VM.
- `systemd/memoh.service` – Compose-Wrapper (`After=network-online.target`, Docker-Abhängigkeit).
