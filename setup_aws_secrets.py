#!/usr/bin/env python3
"""
setup_aws_secrets.py
AWS equivalent of setup-keyvault-secrets.sh

Uploads / fetches / rotates CloudPi secrets in AWS Secrets Manager.
On EC2, the instance role provides credentials automatically (IMDSv2) —
no explicit login needed, equivalent to 'az login --identity' on Azure.

Usage:
  python setup_aws_secrets.py upload   # write secrets to Secrets Manager
  python setup_aws_secrets.py fetch    # pull secrets to /run/secrets-tmp
  python setup_aws_secrets.py rotate   # re-fetch after a secret rotation
  python setup_aws_secrets.py show     # print current secret keys (no values)
"""

import argparse
import getpass
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError


# ─── Configuration ────────────────────────────────────────────────────────────
REGION       = os.getenv("REGION",       "us-east-1")
SECRET_NAME  = os.getenv("SECRET_NAME",  "cloudpi-secrets")
SECRETS_DIR  = Path(os.getenv("SECRETS_DIR",  "/run/secrets-tmp"))
SECRETS_FILE = Path(os.getenv("SECRETS_FILE", str(SECRETS_DIR / "cloudpi.secrets")))
SERVICE_USER = os.getenv("SERVICE_USER", "cloudpiadmin")
SECRET_FILE  = None  # set by --file CLI arg


# ─── Helpers ──────────────────────────────────────────────────────────────────
def info(msg):  print(f"[INFO]  {msg}")
def ok(msg):    print(f"[OK]    {msg}")
def die(msg):   sys.exit(f"[ERROR] {msg}")


def get_sm_client():
    return boto3.client("secretsmanager", region_name=REGION)


def is_root() -> bool:
    return os.geteuid() == 0


def ensure_tmpfs():
    """Mount tmpfs at SECRETS_DIR if not already mounted — mirrors Azure /run/secrets-tmp."""
    if not SECRETS_DIR.exists():
        SECRETS_DIR.mkdir(parents=True, mode=0o700)

    # Check if already a tmpfs mount
    try:
        result = subprocess.run(
            ["mountpoint", "-q", str(SECRETS_DIR)],
            capture_output=True
        )
        if result.returncode == 0:
            return  # already mounted
    except FileNotFoundError:
        pass  # mountpoint not available on all systems

    info(f"Mounting tmpfs at {SECRETS_DIR}...")
    subprocess.run(
        ["mount", "-t", "tmpfs", "-o", "size=2m,mode=0700", "tmpfs", str(SECRETS_DIR)],
        check=True,
    )
    ok("tmpfs mounted.")


def restrict_file(path: Path):
    """chmod 600 + chown to SERVICE_USER — mirrors Azure script file permissions."""
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    try:
        import pwd
        entry = pwd.getpwnam(SERVICE_USER)
        os.chown(path, entry.pw_uid, entry.pw_gid)
    except (KeyError, AttributeError):
        pass  # user may not exist on dev machine


# ─── Secret fields (mirrors the Azure .env required variables) ────────────────
SECRET_FIELDS = [
    ("DB_PASSWORD",           "Database password",                  True),
    ("DB_ROOT_PASSWORD",      "Database root password",             True),
    ("APP_SECRET_KEY",        "Application secret key",             True),
    ("CLIENT_NAME",           "Client name",                        False),
    ("CLIENT_CODE",           "Client code",                        False),
    ("CLIENT_DOMAIN",         "Client domain (e.g. acme.com)",      False),
    ("CLIENT_EMAIL",          "Client email",                       False),
    ("CLIENT_CONTACT_NAME",   "Client contact name",                False),
    ("CLIENT_CONTACT_NUMBER", "Client contact number (+1 555...)",  False),
    ("FISCAL_YEAR",           "Fiscal year (e.g. JAN-DEC)",         False),
]


def prompt_secrets() -> dict:
    print("\nEnter CloudPi secrets (passwords hidden, others visible):\n")
    values = {}
    for key, label, is_password in SECRET_FIELDS:
        prompt_text = f"  {label} [{key}]: "
        values[key] = getpass.getpass(prompt_text) if is_password else input(prompt_text)
    return values


# ─── Commands ─────────────────────────────────────────────────────────────────
def cmd_upload():
    """Write secrets to AWS Secrets Manager (equiv. 'az keyvault secret set')."""
    sm = get_sm_client()
    if SECRET_FILE:
        with open(SECRET_FILE) as f:
            secret_values = json.load(f)
        info(f"Loaded {len(secret_values)} secrets from {SECRET_FILE}")
    else:
        secret_values = prompt_secrets()

    info(f"Uploading secrets to AWS Secrets Manager ('{SECRET_NAME}')...")
    secret_string = json.dumps(secret_values)

    try:
        sm.describe_secret(SecretId=SECRET_NAME)
        info("Secret exists — updating...")
        sm.put_secret_value(SecretId=SECRET_NAME, SecretString=secret_string)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        info(f"Creating secret '{SECRET_NAME}'...")
        sm.create_secret(
            Name=SECRET_NAME,
            Description="CloudPi application secrets",
            SecretString=secret_string,
            Tags=[{"Key": "Project", "Value": "CloudPi"}],
        )

    ok("Secrets uploaded to AWS Secrets Manager.")
    print(f"\n  Stored keys: {', '.join(secret_values.keys())}")


def cmd_fetch():
    """
    Pull secrets from Secrets Manager → tmpfs file.
    On EC2, the instance role credentials are used automatically via IMDSv2.
    Equivalent to: az keyvault secret show --vault-name ... --name cloudpi-secrets
    """
    if is_root():
        ensure_tmpfs()

    sm = get_sm_client()
    info(f"Fetching secret '{SECRET_NAME}' from AWS Secrets Manager...")

    try:
        resp = sm.get_secret_value(SecretId=SECRET_NAME)
    except ClientError as e:
        die(f"Could not fetch secret: {e.response['Error']['Message']}")

    secret_data = json.loads(resp["SecretString"])

    # Write KEY=value pairs — matches docker-compose secrets file format
    lines = "\n".join(f"{k}={v}" for k, v in secret_data.items()) + "\n"
    SECRETS_FILE.write_text(lines, encoding="utf-8")

    # chmod 600 + chown — mirrors Azure script permissions
    restrict_file(SECRETS_FILE)

    ok(f"Secrets written to {SECRETS_FILE}")
    ok("Storage: tmpfs (RAM-only — cleared on reboot, never persisted to disk).")


def cmd_rotate():
    """Re-fetch after a secret rotation and optionally reload the Docker service."""
    info("Re-fetching rotated secrets...")
    if SECRETS_FILE.exists():
        SECRETS_FILE.unlink()

    cmd_fetch()

    # Reload containers so they pick up the new secrets
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "cloudpi-docker-compose"],
            capture_output=True, text=True
        )
        if result.stdout.strip() == "active":
            info("Reloading cloudpi-docker-compose service...")
            subprocess.run(["systemctl", "reload", "cloudpi-docker-compose"], check=True)
            ok("Service reloaded.")
    except FileNotFoundError:
        pass  # systemctl not available (dev machine)

    ok("Rotation complete.")


def cmd_show():
    """Print current secret keys (never prints values)."""
    sm = get_sm_client()
    info(f"Reading secret metadata for '{SECRET_NAME}'...")

    try:
        resp = sm.get_secret_value(SecretId=SECRET_NAME)
    except ClientError as e:
        die(f"Could not read secret: {e.response['Error']['Message']}")

    keys = list(json.loads(resp["SecretString"]).keys())
    print(f"\n  Secret '{SECRET_NAME}' contains {len(keys)} key(s):")
    for k in keys:
        print(f"    • {k}")
    print()


# ─── Main ─────────────────────────────────────────────────────────────────────
COMMANDS = {
    "upload": cmd_upload,
    "fetch":  cmd_fetch,
    "rotate": cmd_rotate,
    "show":   cmd_show,
}

def main():
    global REGION, SECRET_NAME, SECRET_FILE

    parser = argparse.ArgumentParser(
        description="Manage CloudPi secrets in AWS Secrets Manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n".join(f"  {k:8} {v.__doc__.strip().splitlines()[0]}" for k, v in COMMANDS.items()),
    )
    parser.add_argument(
        "action",
        choices=list(COMMANDS.keys()),
        help="Action to perform",
    )
    parser.add_argument("--region",      default=REGION,      help=f"AWS region (default: {REGION})")
    parser.add_argument("--secret-name", default=SECRET_NAME, help=f"Secret name (default: {SECRET_NAME})")
    parser.add_argument("--file",        default=None,        help="JSON file with secrets (skips interactive prompts)")
    args = parser.parse_args()

    REGION      = args.region
    SECRET_NAME = args.secret_name
    SECRET_FILE = args.file

    COMMANDS[args.action]()


if __name__ == "__main__":
    main()
