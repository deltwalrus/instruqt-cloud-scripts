#!/usr/bin/env bash
set -euxo pipefail

################################################################################
# SCRIPT: Launch t4g.micro ARM-based EC2 instance with a security group that
#         opens SSH/HTTP/HTTPS + additional ports. 
#         If you already have at least one key pair, it uses the first found.
#         Otherwise, it creates a brand-new one.
################################################################################

echo "Verifying AWS credentials..."
aws sts get-caller-identity
echo "Credentials valid."

CURRENT_REGION="$(aws configure get region || true)"
if [[ -z "$CURRENT_REGION" ]]; then
  echo "No AWS region configured. Please set one via 'aws configure set region <REGION>' or export AWS_REGION."
  exit 1
fi
echo "Current AWS region: $CURRENT_REGION"

###############################################################################
# 1) Check for existing key pairs
###############################################################################
EXISTING_KEY_NAME="$(
  aws ec2 describe-key-pairs \
    --query 'KeyPairs[0].KeyName' \
    --output text 2>/dev/null || true
)"

# We'll store the "in-use" key name in KEY_NAME. If none found, we create one.
KEY_NAME=""
KEY_FILE=""

if [[ -n "$EXISTING_KEY_NAME" && "$EXISTING_KEY_NAME" != "None" ]]; then
  echo "Existing key pair found: $EXISTING_KEY_NAME"
  KEY_NAME="$EXISTING_KEY_NAME"
  echo "Using that key pair. (Script assumes you have its .pem file locally.)"
else
  echo "No existing key pairs found. Creating a new key pair..."
  KEY_NAME="arm-ec2-$(date +%s)"
  KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$KEY_FILE"

  chmod 400 "$KEY_FILE"
  echo "Created new key pair '$KEY_NAME' and saved private key to $KEY_FILE"
fi

###############################################################################
# 2) Ensure default VPC exists, get the VPC ID
###############################################################################
echo "Ensuring a default VPC in $CURRENT_REGION..."
aws ec2 create-default-vpc || true

DEFAULT_VPC_ID="$(
  aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text
)"
echo "Default VPC: $DEFAULT_VPC_ID"

###############################################################################
# 3) Create a custom security group in that VPC
###############################################################################
SG_NAME="arm-ec2-sg-$(date +%s)"
echo "Creating new security group '$SG_NAME' in VPC $DEFAULT_VPC_ID..."
SG_ID="$(
  aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for ARM-based EC2 with common inbound ports" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --query 'GroupId' \
    --output text
)"
echo "Security group created: $SG_ID"

###############################################################################
# 4) Open inbound SSH, HTTP, HTTPS, plus 7 additional commonly-used ports
###############################################################################
echo "Authorizing inbound rules in $SG_ID (0.0.0.0/0, not recommended for production)..."

declare -a PORTS_TO_OPEN=(22 80 443 3306 5432 6379 27017 5000 8080 8443)

for PORT in "${PORTS_TO_OPEN[@]}"; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$PORT" \
    --cidr 0.0.0.0/0
done
echo "Inbound rules added for ports: ${PORTS_TO_OPEN[*]}"

###############################################################################
# 5) Find the latest Amazon Linux 2 ARM64 AMI
###############################################################################
echo "Finding latest Amazon Linux 2 ARM64 AMI in $CURRENT_REGION..."
AMI_ID="$(
  aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-arm64-gp2" \
              "Name=architecture,Values=arm64" \
              "Name=root-device-type,Values=ebs" \
              "Name=virtualization-type,Values=hvm" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text
)"
echo "Using AMI ID: $AMI_ID"

###############################################################################
# 6) Launch the instance using the discovered or newly created key pair
###############################################################################
echo "Launching t4g.micro instance with key pair '$KEY_NAME' & SG '$SG_ID'..."

INSTANCE_ID="$(
  aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "t4g.micro" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --count 1 \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ARM-based-EC2}]' \
    --query 'Instances[0].InstanceId' \
    --output text
)"
echo "Launched instance: $INSTANCE_ID"

###############################################################################
# 7) Wait for 'running'
###############################################################################
echo "Waiting for instance '$INSTANCE_ID' to reach 'running' state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "Instance is now running."

###############################################################################
# 8) Retrieve public IP & DNS
###############################################################################
PUBLIC_IP="$(
  aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text
)"
PUBLIC_DNS="$(
  aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicDnsName' \
    --output text
)"

###############################################################################
# 9) Print the SSH command
###############################################################################
echo "================================================================="
echo "EC2 instance launched in region: $CURRENT_REGION"
echo "Security group:  $SG_NAME ($SG_ID)"
echo "Opened ports:     ${PORTS_TO_OPEN[*]}"
echo "Instance ID:      $INSTANCE_ID"
echo "AMI (ARM64):      $AMI_ID"
echo "Public IP:        $PUBLIC_IP"
echo "Public DNS:       $PUBLIC_DNS"
echo "================================================================="

if [[ -n "$KEY_FILE" ]]; then
  # We created a new key pair
  SSH_CMD="ssh -i \"$KEY_FILE\" ec2-user@$PUBLIC_IP"
  echo
  echo "A new key pair '$KEY_NAME' was created and saved to:"
  echo "  $KEY_FILE"
  echo "Use the following SSH command:"
  echo "  $SSH_CMD"
else
  # Using an existing key pair. The user must have the .pem locally.
  SSH_CMD="ssh -i \"/path/to/${KEY_NAME}.pem\" ec2-user@$PUBLIC_IP"
  echo
  echo "Using existing key pair '$KEY_NAME'."
  echo "You must already have its private key locally!"
  echo "SSH command might look like:"
  echo "  $SSH_CMD"
fi

echo
echo "When done, terminate with:"
echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID"
echo "================================================================="

cat <<EOF > /tmp/ec2-instance-info.txt
EC2 ARM-based instance in region $CURRENT_REGION:

Key Pair:    $KEY_NAME
Security Group: $SG_NAME ($SG_ID)
Opened Ports:   ${PORTS_TO_OPEN[*]}
Instance ID:    $INSTANCE_ID
AMI:            $AMI_ID
Public IP:      $PUBLIC_IP
Public DNS:     $PUBLIC_DNS

EOF

if [[ -n "$KEY_FILE" ]]; then
  cat <<EOF >> /tmp/ec2-instance-info.txt
A new key pair was created and saved to: $KEY_FILE

SSH command:
  ssh -i "$KEY_FILE" ec2-user@$PUBLIC_IP
EOF
else
  cat <<EOF >> /tmp/ec2-instance-info.txt
Using an existing key pair "$KEY_NAME".
Ensure you have the private key .pem locally.

Example SSH command:
  ssh -i "/path/to/${KEY_NAME}.pem" ec2-user@$PUBLIC_IP
EOF
fi

cat <<EOF >> /tmp/ec2-instance-info.txt

Terminate:
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID
EOF

echo "Wrote instance info to /tmp/ec2-instance-info.txt"
