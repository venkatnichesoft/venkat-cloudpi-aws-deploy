#!/usr/bin/env python3
"""
setup_docker_compose_service.py
Registers CloudPi as a systemd service on the EC2 instance.
Python equivalent of setup-docker-compose-service.sh.

Installs two systemd units:
  cloudpi-fetch-secrets      — pulls secrets from AWS Secrets Manager → tmpfs
  cloudpi-docker-compose     — starts DB + App containers via Docker Compose

Dependency chain (same ordering as Azure version):
  cloudpi-fetch-secrets  →  cloudpi-docker-compose  →  docker.service

Usage (run on EC2 as root):
  sudo python setup_docker_compose_service.py
  sudo SERVICE_USER=cloudpiadmin CLOUDPI_DIR=/home/cloudpiadmin/cloudpi python setup_docker_compose_service.py
"""

import os
import pwd
import shutil
import subprocess
import sys
from pathlib import Path
from textwrap import dedent


# ─── Configuration ────────────────────────────────────────────────────────────
SERVICE_USER    = os.getenv("SERVICE_USER",  "cloudpiadmin")
CLOUDPI_DIR     = Path(os.getenv("CLOUDPI_DIR", f"/home/{SERVICE_USER}/cloudpi"))
REGION          = os.getenv("REGION",        "us-east-1")
SECRET_NAME     = os.getenv("SECRET_NAME",   "cloudpi-secrets")
SYSTEMD_DIR     = Path("/etc/systemd/system")
FETCH_SVC       = "cloudpi-fetch-secrets"
COMPOSE_SVC     = "cloudpi-docker-compose"


# ─── Helpers ──────────────────────────────────────────────────────────────────
def info(msg):  print(f"[INFO]  {msg}")
def ok(msg):    print(f"[OK]    {msg}")
def die(msg):   sys.exit(f"[ERROR] {msg}")


def run(cmd: list[str], **kwargs):
    subprocess.run(cmd, check=True, **kwargs)


def systemctl(*args):
    run(["systemctl", *args])


# ─── Preflight checks ─────────────────────────────────────────────────────────
def preflight():
    if os.geteuid() != 0:
        die("Run this script with sudo.")

    if not shutil.which("docker"):
        die("Docker not installed.")

    result = subprocess.run(
        ["docker", "compose", "version"],
        capture_output=True
    )
    if result.returncode != 0:
        die("Docker Compose plugin not installed.")

    if not CLOUDPI_DIR.is_dir():
        die(f"CloudPi directory not found: {CLOUDPI_DIR}")

    if not (CLOUDPI_DIR / "docker-compose.yml").is_file():
        die(f"docker-compose.yml not found in {CLOUDPI_DIR}")

    if not (CLOUDPI_DIR / ".env").is_file():
        die(f".env not found in {CLOUDPI_DIR}")

    try:
        pwd.getpwnam(SERVICE_USER)
    except KeyError:
        die(f"Service user '{SERVICE_USER}' does not exist.")

    ok("Preflight checks passed.")


# ─── 1. cloudpi-fetch-secrets.service ─────────────────────────────────────────
def write_fetch_secrets_service():
    """
    Fetches secrets from AWS Secrets Manager into tmpfs before Docker starts.
    Equivalent to 'az keyvault secret show ... | az login --identity' pattern.
    On EC2, the instance role provides credentials via IMDSv2 automatically.
    """
    unit = dedent(f"""\
        [Unit]
        Description=CloudPi — Fetch secrets from AWS Secrets Manager into tmpfs
        After=network-online.target
        Wants=network-online.target
        Before={COMPOSE_SVC}.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/bin/cloudpi-fetch-secrets.sh
        ExecStop=/bin/rm -f /run/secrets-tmp/cloudpi.secrets /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password

        [Install]
        WantedBy=multi-user.target
    """)

    path = SYSTEMD_DIR / f"{FETCH_SVC}.service"
    info(f"Writing {path}...")
    path.write_text(unit, encoding="utf-8")
    ok(f"{FETCH_SVC}.service written.")


# ─── 2. cloudpi-docker-compose.service ────────────────────────────────────────
def write_docker_compose_service():
    unit = dedent(f"""\
        [Unit]
        Description=CloudPi Docker Compose Application
        Requires=docker.service {FETCH_SVC}.service
        After=docker.service network-online.target {FETCH_SVC}.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        WorkingDirectory={CLOUDPI_DIR}
        User={SERVICE_USER}

        # Pull latest images silently before starting
        ExecStartPre=-/usr/bin/docker compose pull --quiet

        # Start — remove orphan containers from previous runs
        ExecStart=/usr/bin/docker compose up -d --remove-orphans

        # Stop
        ExecStop=/usr/bin/docker compose down

        # Reload = pull latest images then recreate containers
        ExecReload=/usr/bin/docker compose pull --quiet
        ExecReload=/usr/bin/docker compose up -d --remove-orphans

        TimeoutStartSec=300
        TimeoutStopSec=60

        Restart=on-failure
        RestartSec=10

        [Install]
        WantedBy=multi-user.target
    """)

    path = SYSTEMD_DIR / f"{COMPOSE_SVC}.service"
    info(f"Writing {path}...")
    path.write_text(unit, encoding="utf-8")
    ok(f"{COMPOSE_SVC}.service written.")


# ─── 3. Validate docker-compose.yml ───────────────────────────────────────────
def validate_compose():
    info("Validating docker-compose.yml (best-effort — secrets file may not exist yet)...")
    result = subprocess.run(
        ["docker", "compose", "-f", str(CLOUDPI_DIR / "docker-compose.yml"), "config", "--quiet"],
        cwd=str(CLOUDPI_DIR),
        capture_output=True,
    )
    if result.returncode == 0:
        ok("docker-compose.yml is valid.")
    else:
        stderr = result.stderr.decode().strip()
        if "not found" in stderr or "no such file" in stderr.lower():
            print(f"[WARN]  docker-compose.yml references files not yet present (e.g. secrets tmpfs).")
            print(f"[WARN]  This is expected before first boot — validation skipped.")
        else:
            print(f"[WARN]  docker-compose.yml validation warning: {stderr}")
            print(f"[WARN]  Check the file manually if containers fail to start.")


# ─── 4. Enable + start services ───────────────────────────────────────────────
def enable_and_start():
    info("Reloading systemd daemon...")
    systemctl("daemon-reload")

    for svc in (FETCH_SVC, COMPOSE_SVC):
        systemctl("enable", svc)
        ok(f"{svc} enabled for auto-start on boot.")

    # Start fetch-secrets first and wait for it to finish before starting compose.
    # This ensures /run/secrets-tmp/cloudpi.secrets exists before docker compose reads it.
    info(f"Starting {FETCH_SVC} (fetches secrets into tmpfs)...")
    try:
        systemctl("start", FETCH_SVC)
        ok(f"{FETCH_SVC} started — secrets are in tmpfs.")
    except subprocess.CalledProcessError:
        print(f"[WARN]  {FETCH_SVC} failed to start.")
        print(f"[WARN]  Check: journalctl -xeu {FETCH_SVC}")
        print(f"[WARN]  Skipping {COMPOSE_SVC} start — fix secrets first, then: systemctl start {COMPOSE_SVC}")
        return

    info(f"Starting {COMPOSE_SVC} (brings up Docker containers)...")
    try:
        systemctl("start", COMPOSE_SVC)
        ok(f"{COMPOSE_SVC} started.")
    except subprocess.CalledProcessError:
        print(f"[WARN]  {COMPOSE_SVC} failed to start now — it will run automatically on next boot.")
        print(f"[WARN]  Check: journalctl -xeu {COMPOSE_SVC}")


# ─── Status summary ───────────────────────────────────────────────────────────
def print_status():
    separator = "═" * 59
    print(f"""
{separator}
  CloudPi systemd services installed
{separator}
  {FETCH_SVC}
      pulls secrets from AWS Secrets Manager → tmpfs

  {COMPOSE_SVC}
      starts DB + App containers

  Useful commands:
    systemctl status {COMPOSE_SVC}
    journalctl -u {COMPOSE_SVC} -f
    systemctl reload {COMPOSE_SVC}   # pull latest + redeploy
{separator}
""")


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    preflight()
    write_fetch_secrets_service()
    write_docker_compose_service()
    validate_compose()
    enable_and_start()
    print_status()


if __name__ == "__main__":
    main()
