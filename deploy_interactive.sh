#!/usr/bin/env bash
# deploy_interactive.sh — CloudPi AWS EC2 Interactive Deployment
# Single guided session covering all steps from DEPLOYMENT_RUNBOOK.md.
# Re-runnable: completed steps are recorded in .deploy_state.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy_state"
SECRETS_JSON="$SCRIPT_DIR/cloudpi-secrets.json"
export SCRIPT_DIR

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── UI helpers ─────────────────────────────────────────────────────────────────
header() {
    echo
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
    printf "${BOLD}${CYAN}  Step %-3s %s${NC}\n" "$1" "$2"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
}
ok()   { echo -e "${GREEN}  ✓  ${*}${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  ${*}${NC}"; }
die()  { echo -e "${RED}  ✗  ${*}${NC}"; exit 1; }
info() { echo    "     ${*}"; }

confirm() {   # confirm "prompt" [Y|N]  → 0=yes 1=no
    local msg="${1:-Continue?}" def="${2:-Y}"
    local opts; [[ "$def" == "Y" ]] && opts="[Y/n]" || opts="[y/N]"
    printf "\n${YELLOW}  ▶  %s %s: ${NC}" "$msg" "$opts"
    read -r _ca
    _ca="${_ca:-$def}"
    [[ "$_ca" =~ ^[Yy]$ ]]
}

ask() {       # ask VARNAME "prompt" [default]
    local _v="$1" _p="$2" _d="${3:-}"
    [[ -n "$_d" ]] && printf "     %s [%s]: " "$_p" "$_d" \
                    || printf "     %s: " "$_p"
    read -r _in
    printf -v "$_v" '%s' "${_in:-$_d}"
}

ask_pass() {  # ask_pass VARNAME "prompt"
    local _v="$1" _p="$2"
    printf "     %s (hidden): " "$_p"
    read -rsp "" _sp; echo
    printf -v "$_v" '%s' "$_sp"
}

# ── State helpers ──────────────────────────────────────────────────────────────
touch "$STATE_FILE"

st_get() { grep -E "^${1}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
st_set() {
    local k="$1" v="$2"
    { grep -vE "^${k}=" "$STATE_FILE" 2>/dev/null || true; echo "${k}=${v}"; } \
        > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
st_done() { [[ "$(st_get "$1")" == "done" ]]; }

# Returns 0 (run) or 1 (skip)
should_run() {
    local k="$1" label="${2:-step}"
    if st_done "$k"; then
        warn "Already completed: $label"
        if ! confirm "Re-run this step?" N; then
            return 1
        fi
    fi
    return 0
}

# ── SSH shorthands (available once KEY_FILE / PUBLIC_IP are known) ─────────────
SSH_OPTS=(-o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=15)

ssh_run() {   # ssh_run "remote commands"
    ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" "$@"
}
scp_up() {    # scp_up local_file remote_path
    scp -i "$KEY_FILE" "${SSH_OPTS[@]}" "$1" "cloudpiadmin@${PUBLIC_IP}:$2"
}

# Placeholders so `set -u` doesn't complain before steps 5/6 populate them
KEY_FILE=""; PUBLIC_IP=""

# ══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}${CYAN}  CloudPi AWS EC2 — Interactive Deployment${NC}"
echo -e "  Script dir : $SCRIPT_DIR"
echo -e "  State file : $STATE_FILE"
echo -e "  Secrets    : $SECRETS_JSON"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
header 1 "Prerequisites"

_missing=0
for _cmd in python3 pip3 ssh openssl curl; do
    command -v "$_cmd" &>/dev/null && ok "$_cmd found" || { warn "$_cmd NOT found"; _missing=1; }
done
(( _missing )) && die "Install missing tools before continuing."
ok "All prerequisites met."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — AWS Credentials
# ══════════════════════════════════════════════════════════════════════════════
header 2 "AWS Credentials"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    warn "AWS_ACCESS_KEY_ID not set in environment."
    ask AWS_ACCESS_KEY_ID    "AWS Access Key ID"
    ask_pass AWS_SECRET_ACCESS_KEY "AWS Secret Access Key"
    ask AWS_DEFAULT_REGION   "AWS Region" "us-east-1"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi
: "${AWS_DEFAULT_REGION:=us-east-1}"
export AWS_DEFAULT_REGION

info "Verifying credentials..."
_acct=$(python3 -c "
import boto3, sys
try:
    r = boto3.client('sts', region_name='${AWS_DEFAULT_REGION}').get_caller_identity()
    print(r['Account'])
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
") || die "AWS credential check failed. Check key/secret/region."
ok "AWS account: $_acct  |  Region: $AWS_DEFAULT_REGION"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Python Dependencies
# ══════════════════════════════════════════════════════════════════════════════
header 3 "Python Dependencies"

if should_run STEP_3 "pip install boto3 cryptography"; then
    pip3 install --quiet boto3 cryptography
    ok "boto3 + cryptography installed."
    st_set STEP_3 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Prepare cloudpi-secrets.json
# ══════════════════════════════════════════════════════════════════════════════
header 4 "Prepare cloudpi-secrets.json"

if should_run STEP_4 "secrets file ready"; then
    if [[ -f "$SECRETS_JSON" ]]; then
        info "Existing keys in $SECRETS_JSON:"
        python3 -c "
import json, os
d = json.load(open(os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'))
[print('       •', k) for k in d]
"
        echo
        echo "     Options:"
        echo "       1) Use existing file as-is  (default)"
        echo "       2) Regenerate random secrets (CLIENT_* values are preserved)"
        ask _schoice "Choice" "1"
    else
        warn "cloudpi-secrets.json not found — will generate."
        _schoice="2"
    fi

    if [[ "${_schoice:-1}" == "2" ]]; then
        python3 - <<'PYEOF'
import json, secrets, uuid, os
from cryptography.fernet import Fernet
from pathlib import Path

p = Path(os.environ['SCRIPT_DIR']) / 'cloudpi-secrets.json'
ex = json.loads(p.read_text()) if p.exists() else {}

db_pw   = ex.get("DB_PASSWORD")      or secrets.token_urlsafe(16)
db_root = ex.get("DB_ROOT_PASSWORD") or secrets.token_urlsafe(16)

new_s = {
    "DB_PASSWORD":               db_pw,
    "DB_ROOT_PASSWORD":          db_root,
    "DB_NAME":                   "pidb",
    "DB_HOST":                   "cloudpi-db",
    "DB_USER":                   "masteradmin",
    "MYSQL_PASSWORD":            db_pw,
    "MYSQL_ROOT_PASSWORD":       db_root,
    "MYSQL_DATABASE":            "pidb",
    "MYSQL_USER":                "masteradmin",
    "SECRET_KEY":                secrets.token_hex(32),
    "REDIS_PASSWORD":            secrets.token_hex(16),
    "CRYPTO_SECRET":             secrets.token_hex(16),
    "ENCRYPTION_KEY":            Fernet.generate_key().decode(),
    "CREDENTIAL_ENCRYPTION_KEY": Fernet.generate_key().decode(),
    "HMAC_SECRET_KEY":           secrets.token_hex(32),
    "PAR_SECRET_KEY":            Fernet.generate_key().decode(),
    "WORKSPACE_ID":              ex.get("WORKSPACE_ID") or str(uuid.uuid4()),
    "CLIENT_NAME":               ex.get("CLIENT_NAME",           "CloudPi"),
    "CLIENT_CODE":               ex.get("CLIENT_CODE",           "CPI"),
    "CLIENT_DOMAIN":             ex.get("CLIENT_DOMAIN",         "PLACEHOLDER"),
    "REACT_APP_ORIGIN_URL":      ex.get("REACT_APP_ORIGIN_URL",  "http://localhost:3000"),
    "CLIENT_EMAIL":              ex.get("CLIENT_EMAIL",          ""),
    "CLIENT_CONTACT_NAME":       ex.get("CLIENT_CONTACT_NAME",   ""),
    "CLIENT_CONTACT_NUMBER":     ex.get("CLIENT_CONTACT_NUMBER", ""),
    "FISCAL_YEAR":               ex.get("FISCAL_YEAR",           "JAN-DEC"),
}
p.write_text(json.dumps(new_s, indent=2))
print("     Fresh secrets generated (random keys, CLIENT_* values preserved).")
PYEOF
        ok "Secrets file generated."
    else
        ok "Using existing secrets file."
    fi

    # Prompt for blank client fields
    _cl_name=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json')).get('CLIENT_NAME',''))")
    _cl_email=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json')).get('CLIENT_EMAIL',''))")
    [[ -z "$_cl_name"  || "$_cl_name"  == "CloudPi" ]] && ask _cl_name  "Client name"  "CloudPi"
    [[ -z "$_cl_email" ]]                               && ask _cl_email "Client email" ""
    python3 - <<PYEOF
import json, os
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
d['CLIENT_NAME']  = '${_cl_name}'
d['CLIENT_EMAIL'] = '${_cl_email}'
open(p,'w').write(json.dumps(d, indent=2))
PYEOF
    st_set STEP_4 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — SSH Key Pair
# ══════════════════════════════════════════════════════════════════════════════
header 5 "SSH Key Pair"

KEY_FILE="$(st_get KEY_FILE)"
[[ -z "$KEY_FILE" ]] && KEY_FILE="$HOME/.ssh/cloudpi-key.pem"

if [[ -f "$KEY_FILE" ]]; then
    ok "Key found: $KEY_FILE"
else
    warn "No key at: $KEY_FILE"
    echo "     Options:"
    echo "       1) Create new 'cloudpi-key' pair in AWS  (default)"
    echo "       2) Specify path to existing .pem file"
    ask _kopt "Choice" "1"
    if [[ "${_kopt:-1}" == "1" ]]; then
        python3 - <<PYEOF
import boto3, os, sys
ec2 = boto3.client('ec2', region_name=os.environ.get('AWS_DEFAULT_REGION','us-east-1'))
key_path = os.path.expanduser('$KEY_FILE')
try:
    kp = ec2.create_key_pair(KeyName='cloudpi-key')
    os.makedirs(os.path.dirname(key_path), exist_ok=True)
    open(key_path, 'w').write(kp['KeyMaterial'])
    os.chmod(key_path, 0o400)
    print(f'     Key saved: {key_path}')
except Exception as e:
    if 'Duplicate' in str(e):
        print('ERROR: Key "cloudpi-key" already exists in AWS — provide the .pem file.')
        sys.exit(1)
    raise
PYEOF
        ok "Key pair created."
    else
        ask KEY_FILE "Path to .pem file"
        [[ -f "$KEY_FILE" ]] || die "File not found: $KEY_FILE"
    fi
fi
st_set KEY_FILE "$KEY_FILE"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Provision EC2
# ══════════════════════════════════════════════════════════════════════════════
header 6 "Provision EC2 Infrastructure"

PUBLIC_IP="$(st_get PUBLIC_IP)"

if should_run STEP_6 "EC2 provisioned (IP: ${PUBLIC_IP:-none})"; then
    echo "     This creates: IAM role, security group (22/80/443),"
    echo "     EC2 t3.large + 30 GB gp3, Elastic IP."
    echo
    echo "     Options:"
    echo "       1) Run deploy_aws_ec2.py now  (default)"
    echo "       2) Enter an existing EC2 IP   (skip provisioning)"
    ask _popt "Choice" "1"

    if [[ "${_popt:-1}" == "1" ]]; then
        info "Running deploy_aws_ec2.py ..."
        _out=$(python3 "$SCRIPT_DIR/deploy_aws_ec2.py" 2>&1 | tee /dev/stderr)
        PUBLIC_IP=$(echo "$_out" | grep "Public IP" | awk '{print $NF}')
        [[ -n "$PUBLIC_IP" ]] || die "Could not capture Public IP from output."
    else
        ask PUBLIC_IP "Existing EC2 Public IP" "${PUBLIC_IP:-}"
        [[ -n "$PUBLIC_IP" ]] || die "No IP provided."
    fi
    st_set PUBLIC_IP "$PUBLIC_IP"
    st_set STEP_6 done
    ok "EC2 ready. Public IP: $PUBLIC_IP"
fi

# Reload from state (in case step was skipped)
PUBLIC_IP="$(st_get PUBLIC_IP)"
KEY_FILE="$(st_get KEY_FILE)"
[[ -n "$PUBLIC_IP" ]] || die "PUBLIC_IP not set — re-run step 6."
[[ -n "$KEY_FILE"  ]] || die "KEY_FILE not set — re-run step 5."
info "IP: $PUBLIC_IP   Key: $KEY_FILE"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Update CLIENT_DOMAIN with real IP
# ══════════════════════════════════════════════════════════════════════════════
header 7 "Update CLIENT_DOMAIN in Secrets"

if should_run STEP_7 "CLIENT_DOMAIN updated"; then
    _cur=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json')).get('CLIENT_DOMAIN',''))")
    info "Current CLIENT_DOMAIN: $_cur"
    ask _new_domain "Set CLIENT_DOMAIN to" "$PUBLIC_IP"
    python3 - <<PYEOF
import json, os
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
d['CLIENT_DOMAIN'] = '${_new_domain}'
open(p,'w').write(json.dumps(d, indent=2))
print(f"     Updated CLIENT_DOMAIN → ${_new_domain}")
PYEOF
    st_set STEP_7 done
    ok "CLIENT_DOMAIN = ${_new_domain}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Wait for EC2 Bootstrap (~3-5 min)
# ══════════════════════════════════════════════════════════════════════════════
header 8 "Wait for EC2 Bootstrap"

if should_run STEP_8 "bootstrap complete"; then
    info "Polling for /var/log/cloudpi-bootstrap-done on $PUBLIC_IP ..."
    info "SSH check: ssh -i $KEY_FILE $SSH_OPTS cloudpiadmin@${PUBLIC_IP} '[ -f /var/log/cloudpi-bootstrap-done ]'"
    _n=0; _max=10; _start=$SECONDS
    until ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" \
        "[ -f /var/log/cloudpi-bootstrap-done ]" 2>/dev/null; do
        if (( ++_n >= _max )); then
            echo
            warn "Bootstrap has not completed after ${_max} min (or SSH check is failing)."
            info "To debug, run: ssh -i $KEY_FILE cloudpiadmin@${PUBLIC_IP} '[ -f /var/log/cloudpi-bootstrap-done ] && echo done || echo missing'"
            info "Enter minutes to extend, or 0 to mark complete if you've verified bootstrap manually."
            ask _extend "Extend wait by how many minutes?" "10"
            _extra=${_extend:-10}
            if (( _extra == 0 )); then
                warn "Marking bootstrap complete based on manual verification."
                break
            fi
            _max=$(( _max + _extra ))
            info "Extended timeout — will wait up to ${_max} min total."
        fi

        _elapsed=$(( SECONDS - _start ))
        _em=$(( _elapsed / 60 )); _es=$(( _elapsed % 60 ))
        printf "     [%02d:%02d elapsed] Attempt %d/%d — bootstrap not done yet, next check in 60s\n" \
            "$_em" "$_es" "$_n" "$_max"

        if ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" "echo ok" 2>/dev/null | grep -q ok; then
            info "  → SSH connection OK — bootstrap is still running on EC2"
        else
            warn "  → SSH connection FAILED — verify key path ($KEY_FILE) and IP ($PUBLIC_IP)"
        fi

        info "  → Last line of /var/log/cloudpi-bootstrap.log on EC2:"
        ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" \
            "sudo tail -1 /var/log/cloudpi-bootstrap.log 2>/dev/null || echo '(log not yet available)'" \
            2>/dev/null | sed 's/^/       /' || true

        sleep 60
    done
    echo
    ok "Bootstrap complete."
    st_set STEP_8 done
fi

# ── Ensure cloudpiadmin has passwordless sudo ─────────────────────────────────
# All subsequent SSH steps run sudo non-interactively; this check runs once
# after bootstrap and auto-fixes via ubuntu (same key, always has NOPASSWD).
info "Checking passwordless sudo for cloudpiadmin ..."
if ssh_run "sudo -n true" 2>/dev/null; then
    ok "cloudpiadmin already has passwordless sudo."
else
    warn "cloudpiadmin requires a sudo password — granting NOPASSWD via ubuntu ..."
    ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "ubuntu@${PUBLIC_IP}" \
        "echo 'cloudpiadmin ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/cloudpiadmin > /dev/null && sudo chmod 440 /etc/sudoers.d/cloudpiadmin"
    ssh_run "sudo -n true" || die "Failed to grant passwordless sudo to cloudpiadmin. Check the instance manually."
    ok "Passwordless sudo granted to cloudpiadmin."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — Upload Secrets to AWS Secrets Manager
# ══════════════════════════════════════════════════════════════════════════════
header 9 "Upload Secrets to AWS Secrets Manager"

if should_run STEP_9 "secrets uploaded"; then
    python3 "$SCRIPT_DIR/setup_aws_secrets.py" upload --file "$SECRETS_JSON"
    st_set STEP_9 done
    ok "Secrets uploaded."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — Configure EC2 Instance (via SSH)
# ══════════════════════════════════════════════════════════════════════════════
header 10 "Configure EC2 Instance"

# ── 10a  Deploy type ──────────────────────────────────────────────────────────
if should_run STEP_10A "install type chosen"; then
    echo "     Install type:"
    echo "       1) Fresh install — git clone from GitHub  (default)"
    echo "       2) Migration     — rsync from existing server"
    echo "       3) Upload local cloudpi-files folder → EC2"
    ask _dt "Choice" "1"
    st_set DEPLOY_TYPE "${_dt:-1}"
    st_set STEP_10A done
fi
DEPLOY_TYPE="$(st_get DEPLOY_TYPE)"; DEPLOY_TYPE="${DEPLOY_TYPE:-1}"

# ── 10b  Copy / clone files ───────────────────────────────────────────────────
if should_run STEP_10B "files on EC2"; then
    if [[ "$DEPLOY_TYPE" == "3" ]]; then
        info "=== Upload local cloudpi-files → EC2 /home/cloudpiadmin/cloudpi ==="
        ask _local_src "Local source folder" "$SCRIPT_DIR/cloudpi-files"
        [[ -d "$_local_src" ]] || die "Local folder not found: $_local_src"

        # Ensure target exists and cloudpiadmin owns it (including certs/ so rsync can write)
        ssh_run bash -s <<'REMOTE'
sudo mkdir -p /home/cloudpiadmin/cloudpi/certs
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
REMOTE

        info "Uploading $_local_src → cloudpiadmin@${PUBLIC_IP}:/home/cloudpiadmin/cloudpi/ ..."
        rsync -az --quiet \
            --exclude='.git/' \
            --exclude='.DS_Store' \
            --exclude='*.bak' \
            --exclude='__pycache__/' \
            --exclude='*.pyc' \
            -e "ssh -i \"$KEY_FILE\" -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=15" \
            "$_local_src/" \
            "cloudpiadmin@${PUBLIC_IP}:/home/cloudpiadmin/cloudpi/" \
            2>&1 | grep -v "^$" || true

        # Restore cert ownership for the container (must be UID 1000)
        ssh_run "sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi && \
                 sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs"
        ok "Files uploaded from $_local_src."
    elif [[ "$DEPLOY_TYPE" == "2" ]]; then
        info "=== Migration path: existing server → EC2 ==="
        ask _az_ip   "Existing server public IP"       ""
        ask _az_user "Existing server SSH username"    ""
        ask _az_key  "Path to existing server SSH key" ""

        info "Copying existing server key to EC2 ..."
        scp_up "$_az_key" "/home/cloudpiadmin/.ssh/migration_key"
        ssh_run "chmod 400 ~/.ssh/migration_key"

        info "Rsyncing from existing server → EC2 (may take a few minutes) ..."
        ssh_run bash -s <<REMOTE
sudo mkdir -p /home/cloudpiadmin/cloudpi
sudo rsync -avz -e "ssh -i /home/cloudpiadmin/.ssh/migration_key -o StrictHostKeyChecking=no" \
    ${_az_user}@${_az_ip}:/home/${_az_user}/cloudpi/ \
    /home/cloudpiadmin/cloudpi/
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
REMOTE
        ok "Files migrated from existing server."
    else
        info "=== Fresh install: verifying git clone ==="
        ssh_run bash -s <<'REMOTE'
if sudo test -d /home/cloudpiadmin/cloudpi; then
    echo "     CloudPi directory already present."
else
    sudo -u cloudpiadmin git clone \
        https://github.com/PurpleDataInc-TX/cloudpi-deploy-azure-vm.git \
        /home/cloudpiadmin/cloudpi || true
fi
REMOTE
        ok "CloudPi directory ready."
    fi
    st_set STEP_10B done
fi

# ── 10c  docker-compose.yml ───────────────────────────────────────────────────
if should_run STEP_10C "docker-compose.yml configured"; then
    info "Current image tags on EC2:"
    ssh_run "grep 'image:' /home/cloudpiadmin/cloudpi/docker-compose.yml 2>/dev/null || echo '     (none found)'"
    echo
    echo "     Options:"
    echo "       1) Generate new docker-compose.yml from template  (default)"
    echo "       2) Update image tags only in existing docker-compose.yml"
    echo "       3) Skip"
    ask _copt "Choice" "1"

    if [[ "${_copt:-1}" == "3" ]]; then
        ok "docker-compose.yml step skipped."
    else
        ask _ver "Target release version (e.g. v1.1.044)" "v1.1.042"

        if [[ "${_copt:-1}" == "2" ]]; then
            info "Updating image tags in existing docker-compose.yml to ${_ver} ..."
            ssh_run bash -s <<REMOTE
set -euo pipefail
FILE=/home/cloudpiadmin/cloudpi/docker-compose.yml
if [ ! -f "\$FILE" ]; then
    echo "ERROR: docker-compose.yml not found at \$FILE"
    exit 1
fi
sudo sed -i "s|cloudpi1/cloudpi:Cloudpi_db_[a-zA-Z0-9._-]*|cloudpi1/cloudpi:Cloudpi_db_${_ver}|g" "\$FILE"
sudo sed -i "/Cloudpi_db_/!s|cloudpi1/cloudpi:Cloudpi_[a-zA-Z0-9._-]*|cloudpi1/cloudpi:Cloudpi_${_ver}|g" "\$FILE"
echo "     Updated tags:"
grep 'image:' "\$FILE"
REMOTE
            ok "Image tags updated to ${_ver}."
        else
            _compose_tmp=$(mktemp /tmp/cloudpi-compose.XXXXXX.yml)
            cat > "$_compose_tmp" <<COMPOSE
version: "3.8"

secrets:
  cloudpi_secrets:
    file: /run/secrets-tmp/cloudpi.secrets
  db_password:
    file: /run/secrets-tmp/db_password
  db_root_password:
    file: /run/secrets-tmp/db_root_password

services:
  db:
    image: cloudpi1/cloudpi:Cloudpi_db_${_ver}
    container_name: cloudpi-db
    restart: unless-stopped
    env_file:
      - .env
      - /run/secrets-tmp/cloudpi.secrets
    volumes:
      - cloudpi_db_data:/var/lib/mysql
    networks:
      - cloudpi_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    image: cloudpi1/cloudpi:Cloudpi_${_ver}
    container_name: cloudpi-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - .env
      - /run/secrets-tmp/cloudpi.secrets
    secrets:
      - cloudpi_secrets
    volumes:
      - ./certs:/home/certs
      - cloudpi_backups:/app/backups
    ports:
      - "80:80"
      - "443:443"
    networks:
      - cloudpi_network
    healthcheck:
      test: ["CMD", "curl", "-fsk", "https://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

volumes:
  cloudpi_db_data:
  cloudpi_backups:

networks:
  cloudpi_network:
    driver: bridge
COMPOSE

            scp_up "$_compose_tmp" "/tmp/docker-compose.yml"
            rm -f "$_compose_tmp"
            ssh_run "sudo mv /tmp/docker-compose.yml /home/cloudpiadmin/cloudpi/docker-compose.yml && \
                     sudo chown cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi/docker-compose.yml"
            ok "docker-compose.yml generated (version: ${_ver})."
        fi
    fi
    st_set STEP_10C done
fi

# ── 10d  .env file ────────────────────────────────────────────────────────────
if should_run STEP_10D ".env file"; then
    _env_tmp=$(mktemp /tmp/cloudpi.env.XXXXXX)
    cat > "$_env_tmp" <<ENV
HOST=${PUBLIC_IP}
HTTPS=true
SUBDOMAIN=${PUBLIC_IP}
CERT_PATH=/home/certs/cert.pem
KEY_PATH=/home/certs/privkey.pem
CA_BUNDLE_PATH=/home/certs/ca_bundle.pem
ENV
    scp_up "$_env_tmp" "/tmp/cloudpi.env"
    rm -f "$_env_tmp"
    ssh_run "sudo mv /tmp/cloudpi.env /home/cloudpiadmin/cloudpi/.env && \
             sudo chown cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi/.env"
    ok ".env file created."
    st_set STEP_10D done
fi

# ── 10e  TLS certificates (self-signed) ──────────────────────────────────────
if should_run STEP_10E "TLS certificates"; then
    info "Generating self-signed certificate for CN=${PUBLIC_IP} ..."
    ssh_run bash -s <<REMOTE
set -euo pipefail
sudo mkdir -p /home/cloudpiadmin/cloudpi/certs
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /home/cloudpiadmin/cloudpi/certs/privkey.pem \
    -out    /home/cloudpiadmin/cloudpi/certs/cert.pem \
    -subj   "/CN=${PUBLIC_IP}" 2>&1 | tail -2
sudo cp /home/cloudpiadmin/cloudpi/certs/cert.pem \
        /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/cert.pem
sudo chmod 640 /home/cloudpiadmin/cloudpi/certs/privkey.pem
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
REMOTE
    ok "TLS certificates created."
    st_set STEP_10E done
fi

# ── 10f  Secrets fetch script ─────────────────────────────────────────────────
if should_run STEP_10F "secrets fetch script installed"; then
    _fetch_tmp=$(mktemp /tmp/cloudpi-fetch.XXXXXX.sh)
    cat > "$_fetch_tmp" <<'FETCHSCRIPT'
#!/bin/bash
set -euo pipefail

mkdir -p /run/secrets-tmp
mount | grep -q secrets-tmp || mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
chgrp cloudpiadmin /run/secrets-tmp
chmod 750 /run/secrets-tmp

/usr/local/bin/aws secretsmanager get-secret-value \
    --region us-east-1 --secret-id cloudpi-secrets \
    --query SecretString --output text \
    | python3 -c 'import json,sys; [print(k+"="+v) for k,v in json.load(sys.stdin).items()]' \
    > /run/secrets-tmp/cloudpi.secrets

python3 -c "
import json, pathlib
data = json.loads(open('/dev/stdin').read())
pathlib.Path('/run/secrets-tmp/db_password').write_text(data.get('MYSQL_PASSWORD',''))
pathlib.Path('/run/secrets-tmp/db_root_password').write_text(data.get('MYSQL_ROOT_PASSWORD',''))
" < <(/usr/local/bin/aws secretsmanager get-secret-value \
    --region us-east-1 --secret-id cloudpi-secrets \
    --query SecretString --output text)

chmod 640 /run/secrets-tmp/cloudpi.secrets /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
chown cloudpiadmin:cloudpiadmin /run/secrets-tmp/cloudpi.secrets \
    /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
FETCHSCRIPT

    scp_up "$_fetch_tmp" "/tmp/cloudpi-fetch-secrets.sh"
    rm -f "$_fetch_tmp"
    ssh_run "sudo mv /tmp/cloudpi-fetch-secrets.sh /usr/local/bin/cloudpi-fetch-secrets.sh && \
             sudo chmod +x /usr/local/bin/cloudpi-fetch-secrets.sh"
    ok "Secrets fetch script installed."
    st_set STEP_10F done
fi

# ── 10g  Docker Hub login ─────────────────────────────────────────────────────
if should_run STEP_10G "Docker Hub login"; then
    info "Logging in to Docker Hub (account: cloudpi1) for private images."
    ask_pass _docker_pat "Docker Hub Personal Access Token"
    echo "$_docker_pat" | ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" \
        "sudo docker login -u cloudpi1 --password-stdin"
    ssh_run bash -s <<'REMOTE'
sudo mkdir -p /home/cloudpiadmin/.docker
sudo cp /root/.docker/config.json /home/cloudpiadmin/.docker/config.json
sudo chown cloudpiadmin:cloudpiadmin /home/cloudpiadmin/.docker/config.json
REMOTE
    ok "Docker Hub login complete."
    st_set STEP_10G done
fi

# ── 10h  setup_docker_compose_service.py ─────────────────────────────────────
if should_run STEP_10H "systemd services installed"; then
    info "Uploading setup_docker_compose_service.py ..."
    scp_up "$SCRIPT_DIR/setup_docker_compose_service.py" "/tmp/setup_docker_compose_service.py"
    info "Running setup_docker_compose_service.py (installs systemd units) ..."
    ssh_run "sudo python3 /tmp/setup_docker_compose_service.py"

    info "Starting cloudpi-fetch-secrets (pulls secrets from AWS Secrets Manager) ..."
    if ssh_run "sudo systemctl start cloudpi-fetch-secrets" 2>/dev/null; then
        ok "cloudpi-fetch-secrets started."
    else
        warn "cloudpi-fetch-secrets failed to start — checking logs:"
        ssh_run "sudo journalctl -u cloudpi-fetch-secrets --no-pager -n 20" 2>/dev/null || true
        warn "Secrets fetch failed. Verify the EC2 IAM role has Secrets Manager access and step 9 (secrets upload) completed."
        warn "You can retry manually on EC2: sudo systemctl start cloudpi-fetch-secrets"
    fi

    info "Starting cloudpi-docker-compose ..."
    if ssh_run "sudo systemctl start cloudpi-docker-compose" 2>/dev/null; then
        ok "cloudpi-docker-compose started."
    else
        warn "cloudpi-docker-compose failed to start — checking logs:"
        ssh_run "sudo journalctl -u cloudpi-docker-compose --no-pager -n 20" 2>/dev/null || true
    fi

    st_set STEP_10H done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — First Boot & Verification
# ══════════════════════════════════════════════════════════════════════════════
header 11 "First Boot & Verification"

# ── 11a  Wait for containers ──────────────────────────────────────────────────
if should_run STEP_11A "containers healthy"; then
    info "Waiting for cloudpi-db (healthy) and cloudpi-app (Up) — up to 10 min ..."
    _n=0; _max=60; _timed_out=0
    until ssh_run "sudo docker ps --format '{{.Names}}:{{.Status}}' 2>/dev/null \
        | grep -q 'cloudpi-db.*healthy'" 2>/dev/null; do
        if (( ++_n >= _max )); then
            _timed_out=1
            break
        fi

        # Every 3 attempts (~30s) print a diagnostic snapshot
        if (( _n % 3 == 0 )); then
            echo
            info "--- Diagnostics (attempt ${_n}/${_max}) ---"
            info "Secrets in tmpfs:"
            ssh_run "ls /run/secrets-tmp/ 2>/dev/null || echo '     (empty — fetch-secrets has not run)'"
            info "Fetch-secrets service:"
            ssh_run "sudo systemctl is-active cloudpi-fetch-secrets 2>/dev/null || echo '     inactive/failed'"
            info "Container status:"
            ssh_run "sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo '     (none)'"
            info "Last 5 lines of cloudpi-db log:"
            ssh_run "sudo docker logs cloudpi-db --tail 5 2>/dev/null || echo '     (not running)'"
        else
            printf "\r     Attempt %d/%d ..." "$_n" "$_max"
        fi
        sleep 10
    done
    echo

    if (( _timed_out )); then
        warn "Timed out — cloudpi-db never became healthy. Final state:"
        ssh_run "sudo docker ps -a"
        warn "Fix the issue above, then re-run this step."
        warn "Common cause: cloudpi-fetch-secrets failed → re-run step 10h to reinstall the systemd unit."
    else
        ssh_run "sudo docker ps"
        ok "Containers healthy."
        st_set STEP_11A done
    fi
fi

# ── 11b  MySQL cloudpiadmin user ──────────────────────────────────────────────
if should_run STEP_11B "MySQL cloudpiadmin user created"; then
    info "Creating/verifying MySQL cloudpiadmin user (passwords from Secrets Manager) ..."
    # Fetch passwords on EC2 using its IAM role — avoids passing them in plaintext
    if ssh_run bash -s <<'REMOTE'
_sm_json=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region us-east-1 --secret-id cloudpi-secrets \
    --query SecretString --output text)
_db_pw=$(echo "$_sm_json"   | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
_db_root=$(echo "$_sm_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_ROOT_PASSWORD'])")

sudo docker exec -e "MYSQL_PWD=${_db_root}" cloudpi-db \
    mysql -u masteradmin pidb -e "
CREATE USER IF NOT EXISTS 'cloudpiadmin'@'%' IDENTIFIED BY '${_db_pw}';
GRANT ALL PRIVILEGES ON pidb.* TO 'cloudpiadmin'@'%';
GRANT PROCESS, SHOW_ROUTINE, SYSTEM_USER ON *.* TO 'cloudpiadmin'@'%';
FLUSH PRIVILEGES;
"
echo "     MySQL cloudpiadmin user ready."
REMOTE
    then
        ok "MySQL user configured."
        st_set STEP_11B done
    else
        warn "MySQL user setup failed — root password mismatch (DB initialized without secrets)."
        warn "Fix on EC2:"
        info "  cd /home/cloudpiadmin/cloudpi"
        info "  sudo /usr/local/bin/cloudpi-fetch-secrets.sh   # verify secrets are fetched"
        info "  docker compose down -v                          # wipe DB volume"
        info "  docker compose up -d                           # restart with correct passwords"
        warn "Then re-run this step (step 11b)."
    fi
fi

# ── 11c  Test login ───────────────────────────────────────────────────────────
if should_run STEP_11C "API login verified"; then
    info "Testing https://${PUBLIC_IP}/CPiN/v1/user/login ..."
    _http=$(curl -sk -o /dev/null -w "%{http_code}" \
        -X POST "https://${PUBLIC_IP}/CPiN/v1/user/login" \
        -H 'Content-Type: application/json' \
        -d '{"email":"admin@cloudpi.ai","password":"admin123"}' || echo "000")
    if [[ "$_http" == "200" ]]; then
        ok "Login successful (HTTP 200)."
    else
        warn "Login returned HTTP $_http — app may still be starting up."
        info "Retry: curl -sk -X POST https://${PUBLIC_IP}/CPiN/v1/user/login -H 'Content-Type: application/json' -d '{\"email\":\"admin@cloudpi.ai\",\"password\":\"admin123\"}'"
    fi
    st_set STEP_11C done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — Post-Install (optional)
# ══════════════════════════════════════════════════════════════════════════════
header 12 "Post-Install (Optional)"

if confirm "Reset the default admin@cloudpi.ai password?" N; then
    ask_pass _new_admin_pw "New admin password"
    # bcrypt the password inside the app container, then update MySQL
    _bcrypt=$(ssh_run "sudo docker exec cloudpi-app node -e \
        \"const b=require('bcrypt');b.hash('${_new_admin_pw}',10).then(h=>console.log(h));\"")
    ssh_run bash -s <<REMOTE
_db_root=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region us-east-1 --secret-id cloudpi-secrets \
    --query SecretString --output text \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_ROOT_PASSWORD'])")
sudo docker exec -e "MYSQL_PWD=\${_db_root}" cloudpi-db \
    mysql -u masteradmin pidb -e "UPDATE user SET password='${_bcrypt}' WHERE email='admin@cloudpi.ai';"
REMOTE
    ok "Admin password updated."
fi

if confirm "Update CLIENT_DOMAIN in the database?" N; then
    _cl_domain=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json'))['CLIENT_DOMAIN'])")
    ask _new_cl_domain "New CLIENT_DOMAIN value" "$_cl_domain"
    ssh_run bash -s <<REMOTE
_db_root=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region us-east-1 --secret-id cloudpi-secrets \
    --query SecretString --output text \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_ROOT_PASSWORD'])")
sudo docker exec -e "MYSQL_PWD=\${_db_root}" cloudpi-db \
    mysql -u masteradmin pidb -e "UPDATE client SET domain='${_new_cl_domain}' WHERE id=1;"
REMOTE
    ok "CLIENT_DOMAIN updated in database."
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Deployment complete!${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${NC}"
echo -e "  URL    : ${CYAN}https://${PUBLIC_IP}/${NC}"
echo -e "  SSH    : ${CYAN}ssh -i ${KEY_FILE} cloudpiadmin@${PUBLIC_IP}${NC}"
echo -e "  Logs   : sudo docker logs -f cloudpi-app"
echo -e "  State  : $STATE_FILE  (delete to start fresh)"
echo
