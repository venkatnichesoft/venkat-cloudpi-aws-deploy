#!/usr/bin/env python3
"""
deploy_aws_ec2.py
Creates an AWS EC2 instance equivalent to the Azure cloudpi-deploy-azure-vm setup.

Azure → AWS:
  VM + Managed Identity  → EC2 + IAM Instance Profile
  Azure Key Vault        → AWS Secrets Manager
  NSG (80/443)           → Security Group
  Azure Public IP        → Elastic IP

Prerequisites:
  pip install boto3
  aws configure  (or set AWS_* env vars / use an instance role)

Usage:
  python deploy_aws_ec2.py
  REGION=us-west-2 INSTANCE_TYPE=t3.xlarge python deploy_aws_ec2.py
"""

import json
import os
import sys
import time
import textwrap

import boto3
from botocore.exceptions import ClientError


# ─── Configuration ────────────────────────────────────────────────────────────
REGION               = os.getenv("REGION",               "us-east-1")
INSTANCE_TYPE        = os.getenv("INSTANCE_TYPE",        "t3.large")   # 2 vCPU / 8 GB
KEY_PAIR_NAME        = os.getenv("KEY_PAIR_NAME",        "cloudpi-key")
TAG_NAME             = os.getenv("TAG_NAME",             "cloudpi-vm")
SECRET_NAME          = os.getenv("SECRET_NAME",          "cloudpi-secrets")
ROLE_NAME            = os.getenv("ROLE_NAME",            "cloudpi-ec2-role")
INSTANCE_PROFILE     = os.getenv("INSTANCE_PROFILE",     "cloudpi-ec2-profile")
POLICY_NAME          = os.getenv("POLICY_NAME",          "CloudPiSecretsPolicy")
SG_NAME              = os.getenv("SG_NAME",              "cloudpi-sg")
AMI_ID               = os.getenv("AMI_ID",               "")           # auto-resolved if blank


# ─── Helpers ──────────────────────────────────────────────────────────────────
def info(msg):    print(f"[INFO]  {msg}")
def ok(msg):      print(f"[OK]    {msg}")
def warn(msg):    print(f"[WARN]  {msg}")
def die(msg):     sys.exit(f"[ERROR] {msg}")


def get_clients():
    session = boto3.Session(region_name=REGION)
    return {
        "ec2":  session.client("ec2"),
        "iam":  session.client("iam"),
        "sts":  session.client("sts"),
    }


# ─── 1. Resolve latest Ubuntu 22.04 LTS AMI ───────────────────────────────────
def resolve_ami(ec2) -> str:
    if AMI_ID:
        return AMI_ID
    info(f"Resolving latest Ubuntu 22.04 LTS AMI in {REGION}...")
    resp = ec2.describe_images(
        Owners=["099720109477"],
        Filters=[
            {"Name": "name",                  "Values": ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]},
            {"Name": "state",                 "Values": ["available"]},
            {"Name": "architecture",          "Values": ["x86_64"]},
            {"Name": "virtualization-type",   "Values": ["hvm"]},
        ],
    )
    images = sorted(resp["Images"], key=lambda i: i["CreationDate"], reverse=True)
    if not images:
        die("Could not resolve Ubuntu 22.04 AMI.")
    ami = images[0]["ImageId"]
    ok(f"AMI resolved: {ami}")
    return ami


# ─── 2. IAM Role + Instance Profile (≈ Azure Managed Identity) ────────────────
def ensure_iam_role(iam, sts) -> str:
    trust = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "ec2.amazonaws.com"},
            "Action": "sts:AssumeRole",
        }],
    })

    info(f"Ensuring IAM role '{ROLE_NAME}'...")
    try:
        iam.get_role(RoleName=ROLE_NAME)
        warn(f"IAM role '{ROLE_NAME}' already exists — skipping creation.")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        iam.create_role(
            RoleName=ROLE_NAME,
            AssumeRolePolicyDocument=trust,
            Description="CloudPi EC2 role - read/write AWS Secrets Manager (equiv. Azure Key Vault)",
        )
        ok("IAM role created.")

    account_id = sts.get_caller_identity()["Account"]

    # Equivalent to:
    #   Azure "Key Vault Secrets User"    → GetSecretValue
    #   Azure "Key Vault Secrets Officer" → CreateSecret + PutSecretValue + UpdateSecret
    secrets_policy = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "ReadSecrets",
                "Effect": "Allow",
                "Action": [
                    "secretsmanager:GetSecretValue",
                    "secretsmanager:DescribeSecret",
                    "secretsmanager:ListSecretVersionIds",
                ],
                "Resource": f"arn:aws:secretsmanager:{REGION}:{account_id}:secret:{SECRET_NAME}*",
            },
            {
                "Sid": "WriteSecrets",
                "Effect": "Allow",
                "Action": [
                    "secretsmanager:CreateSecret",
                    "secretsmanager:PutSecretValue",
                    "secretsmanager:UpdateSecret",
                    "secretsmanager:TagResource",
                ],
                "Resource": f"arn:aws:secretsmanager:{REGION}:{account_id}:secret:{SECRET_NAME}*",
            },
        ],
    })

    iam.put_role_policy(
        RoleName=ROLE_NAME,
        PolicyName=POLICY_NAME,
        PolicyDocument=secrets_policy,
    )
    ok(f"IAM inline policy '{POLICY_NAME}' attached.")

    info(f"Ensuring instance profile '{INSTANCE_PROFILE}'...")
    try:
        iam.get_instance_profile(InstanceProfileName=INSTANCE_PROFILE)
        warn(f"Instance profile '{INSTANCE_PROFILE}' already exists — skipping.")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        iam.create_instance_profile(InstanceProfileName=INSTANCE_PROFILE)
        iam.add_role_to_instance_profile(
            InstanceProfileName=INSTANCE_PROFILE,
            RoleName=ROLE_NAME,
        )
        ok("Instance profile created and role attached.")
        info("Waiting 10 s for IAM propagation...")
        time.sleep(10)

    return INSTANCE_PROFILE


# ─── 3. Security Group (≈ Azure NSG: allow 80 + 443 inbound) ──────────────────
def ensure_security_group(ec2) -> str:
    info(f"Ensuring security group '{SG_NAME}'...")

    vpc_resp = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])
    vpcs = vpc_resp.get("Vpcs", [])
    if not vpcs:
        die("No default VPC found. Set VPC_ID env var and update this script.")
    vpc_id = vpcs[0]["VpcId"]

    existing = ec2.describe_security_groups(
        Filters=[
            {"Name": "group-name", "Values": [SG_NAME]},
            {"Name": "vpc-id",     "Values": [vpc_id]},
        ]
    )["SecurityGroups"]

    if existing:
        sg_id = existing[0]["GroupId"]
        warn(f"Security group '{SG_NAME}' already exists ({sg_id}) — reusing.")
        return sg_id

    sg = ec2.create_security_group(
        GroupName=SG_NAME,
        Description="CloudPi: allow HTTP (80) and HTTPS (443) inbound",
        VpcId=vpc_id,
    )
    sg_id = sg["GroupId"]

    rules = [
        {"IpProtocol": "tcp", "FromPort": 80,  "ToPort": 80,  "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "HTTP - Lets Encrypt ACME"}]},
        {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "HTTPS - application traffic"}]},
        {"IpProtocol": "tcp", "FromPort": 22,  "ToPort": 22,  "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "SSH - restrict to your IP in production"}]},
    ]
    ec2.authorize_security_group_ingress(GroupId=sg_id, IpPermissions=rules)
    ok(f"Security group created: {sg_id}")
    return sg_id


# ─── 4. User Data (bootstraps the EC2 instance on first boot) ─────────────────
def build_user_data() -> str:
    return textwrap.dedent("""\
        #!/bin/bash
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y
        apt-get upgrade -y

        # Create service user (mirrors 'azureadmin' on Azure)
        if ! id "cloudpiadmin" &>/dev/null; then
          useradd -m -s /bin/bash cloudpiadmin
          usermod -aG sudo cloudpiadmin
        fi
        echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cloudpiadmin
        chmod 440 /etc/sudoers.d/cloudpiadmin


        # Docker Engine + Compose plugin
        apt-get install -y ca-certificates curl gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \\
          | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \\
          https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \\
          > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        usermod -aG docker cloudpiadmin
        systemctl enable --now docker

        # Certbot (Let's Encrypt)
        apt-get install -y certbot

        # AWS CLI v2
        apt-get install -y unzip
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
        unzip -q /tmp/awscliv2.zip -d /tmp
        /tmp/aws/install
        rm -rf /tmp/awscliv2.zip /tmp/aws

        # jq + git
        apt-get install -y jq git python3-pip python3-boto3

        # Clone CloudPi deployment repo
        sudo -u cloudpiadmin git clone https://github.com/venkatnichesoft/venkat-cloudpi-aws-deploy.git \\
          /home/cloudpiadmin/cloudpi || true

        # Enable SSH for cloudpiadmin using the same EC2 key pair
        mkdir -p /home/cloudpiadmin/.ssh
        cp /home/ubuntu/.ssh/authorized_keys /home/cloudpiadmin/.ssh/authorized_keys
        chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/.ssh
        chmod 700 /home/cloudpiadmin/.ssh
        chmod 600 /home/cloudpiadmin/.ssh/authorized_keys

        # tmpfs for secrets (equiv. Azure /run/secrets-tmp)
        mkdir -p /run/secrets-tmp
        mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
        echo 'tmpfs /run/secrets-tmp tmpfs size=2m,mode=0700 0 0' >> /etc/fstab

        touch /var/log/cloudpi-bootstrap-done
        echo "CloudPi bootstrap complete at $(date)" >> /var/log/cloudpi-bootstrap.log
    """)


# ─── 5. Launch EC2 Instance ────────────────────────────────────────────────────
def launch_instance(ec2, ami_id: str, sg_id: str, profile_name: str) -> str:
    info(f"Launching EC2 instance ({INSTANCE_TYPE}, AMI: {ami_id})...")

    launch_kwargs = {
        "ImageId":           ami_id,
        "InstanceType":      INSTANCE_TYPE,
        "MinCount":          1,
        "MaxCount":          1,
        "SecurityGroupIds":  [sg_id],
        "UserData":          build_user_data(),
        "IamInstanceProfile": {"Name": profile_name},
        "BlockDeviceMappings": [{
            "DeviceName": "/dev/sda1",
            "Ebs": {"VolumeSize": 30, "VolumeType": "gp3", "DeleteOnTermination": True},
        }],
        "MetadataOptions": {
            "HttpTokens":   "required",   # IMDSv2 enforced
            "HttpEndpoint": "enabled",
        },
        "TagSpecifications": [{
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name",    "Value": TAG_NAME},
                {"Key": "Project", "Value": "CloudPi"},
            ],
        }],
    }

    if KEY_PAIR_NAME.lower() != "none":
        launch_kwargs["KeyName"] = KEY_PAIR_NAME

    resp = ec2.run_instances(**launch_kwargs)
    instance_id = resp["Instances"][0]["InstanceId"]
    ok(f"Instance launched: {instance_id}")
    return instance_id


# ─── 6. Allocate Elastic IP and associate with instance ───────────────────────
def allocate_and_associate_eip(ec2, instance_id: str) -> str:
    info("Waiting for instance to reach 'running' state...")
    waiter = ec2.get_waiter("instance_running")
    waiter.wait(InstanceIds=[instance_id])

    info("Allocating Elastic IP (AWS assigns the address)...")
    # Reuse an unassociated EIP if the account limit is reached
    try:
        alloc = ec2.allocate_address(Domain="vpc")
    except ClientError as e:
        if "AddressLimitExceeded" not in str(e):
            raise
        warn("EIP limit reached — checking for unassociated Elastic IPs to reuse...")
        existing = ec2.describe_addresses(Filters=[{"Name": "domain", "Values": ["vpc"]}])
        free = [a for a in existing["Addresses"] if "AssociationId" not in a]
        if not free:
            die("EIP limit reached and no unassociated Elastic IPs available. "
                "Release an EIP in the AWS console or request a limit increase.")
        alloc = free[0]
        ok(f"Reusing unassociated Elastic IP: {alloc['PublicIp']}  (Allocation ID: {alloc['AllocationId']})")
    alloc_id  = alloc["AllocationId"]
    public_ip = alloc["PublicIp"]
    ok(f"Elastic IP: {public_ip}  (Allocation ID: {alloc_id})")

    ec2.associate_address(InstanceId=instance_id, AllocationId=alloc_id)
    ok(f"Elastic IP {public_ip} associated with instance {instance_id}")
    ok("This IP is permanent — it persists through reboots and stop/start.")
    return public_ip


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    clients = get_clients()
    ec2, iam, sts = clients["ec2"], clients["iam"], clients["sts"]

    ami_id      = resolve_ami(ec2)
    profile     = ensure_iam_role(iam, sts)
    sg_id       = ensure_security_group(ec2)
    instance_id = launch_instance(ec2, ami_id, sg_id, profile)
    public_ip   = allocate_and_associate_eip(ec2, instance_id)

    separator = "═" * 59
    print(f"""
{separator}
  CloudPi EC2 Deployment Complete
{separator}
  Instance ID    : {instance_id}
  Public IP      : {public_ip}
  Instance Type  : {INSTANCE_TYPE}
  Region         : {REGION}
  IAM Role       : {ROLE_NAME}
  Secret Name    : {SECRET_NAME}  (AWS Secrets Manager)
  Security Group : {sg_id}

  Next steps:
  1. SSH:      ssh -i ~/.ssh/{KEY_PAIR_NAME}.pem cloudpiadmin@{public_ip}
  2. Secrets:  python setup_aws_secrets.py upload
  3. Services: python setup_docker_compose_service.py
  4. TLS cert: sudo certbot certonly --standalone -d your.domain.com
{separator}
""")


if __name__ == "__main__":
    main()
