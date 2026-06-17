#!/bin/bash
set -euo pipefail

mkdir -p /run/secrets-tmp
mount | grep -q secrets-tmp || mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
chgrp cloudpiadmin /run/secrets-tmp
chmod 750 /run/secrets-tmp

SECRET=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region us-east-1 --secret-id cloudpi-secrets \
    --query SecretString --output text)

echo "$SECRET" \
    | python3 -c 'import json,sys; [print(k+"="+v) for k,v in json.load(sys.stdin).items()]' \
    > /run/secrets-tmp/cloudpi.secrets

echo "$SECRET" | python3 -c "
import json, sys, pathlib
d = json.load(sys.stdin)
pathlib.Path('/run/secrets-tmp/db_password').write_text(d.get('MYSQL_PASSWORD',''))
pathlib.Path('/run/secrets-tmp/db_root_password').write_text(d.get('MYSQL_ROOT_PASSWORD',''))
"

chmod 640 /run/secrets-tmp/cloudpi.secrets
chmod 640 /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
chown cloudpiadmin:cloudpiadmin /run/secrets-tmp/cloudpi.secrets \
    /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
echo "Secrets fetched successfully."
