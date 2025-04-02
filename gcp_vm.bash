#!/usr/bin/env bash
set -euxo pipefail

# Retrieve project from gcloud config.
PROJECT=$(gcloud config get-value project)

# Set zone to us-central1-a and derive region.
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"

echo "GCP Project: $PROJECT"
echo "Zone: $ZONE, Region: $REGION"

# Define the ports you want to allow.
PORTS=(22 80 443 3306 5432 6379 27017 5000 8080 8443)

# Build the allowed string (e.g. "tcp:22,tcp:80,tcp:443,...")
allowed=""
for port in "${PORTS[@]}"; do
  allowed="${allowed:+$allowed,}tcp:$port"
done
echo "Allowed protocols: $allowed"

# Create a firewall rule to allow inbound traffic on the allowed ports.
FIREWALL_NAME="arm-vm-fw-$(date +%s)"
echo "Creating firewall rule $FIREWALL_NAME for ports: ${PORTS[*]}"
gcloud compute firewall-rules create "$FIREWALL_NAME" \
  --allow "$allowed" \
  --target-tags "arm-vm" \
  --quiet

# Ensure the SSH key exists for gcloud at ~/.ssh/google_compute_engine.pub; generate one with empty passphrase if missing.
if [ ! -f "$HOME/.ssh/google_compute_engine.pub" ]; then
  echo "No SSH key found at ~/.ssh/google_compute_engine.pub. Generating one with an empty passphrase..."
  ssh-keygen -t rsa -b 3072 -N "" -f "$HOME/.ssh/google_compute_engine"
fi
PUB_KEY=$(cat "$HOME/.ssh/google_compute_engine.pub")

# Set Ubuntu image variables for ARM64.
IMAGE_FAMILY="ubuntu-2204-lts-arm64"
IMAGE_PROJECT="ubuntu-os-cloud"

# Create an ARM-based VM using the Ubuntu ARM image.
INSTANCE_NAME="arm-vm-$(date +%s)"
echo "Creating ARM-based instance $INSTANCE_NAME (machine type: t2a-standard-1)..."
gcloud compute instances create "$INSTANCE_NAME" \
  --zone "$ZONE" \
  --machine-type=t2a-standard-1 \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --tags=arm-vm \
  --metadata=ssh-keys="cos:${PUB_KEY}" \
  --quiet

# Wait until the instance gets an external IP.
EXTERNAL_IP=""
echo "Waiting for instance $INSTANCE_NAME to have an external IP..."
until [ -n "$EXTERNAL_IP" ]; do
  sleep 10
  EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone "$ZONE" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
done

echo "Instance $INSTANCE_NAME is running with external IP: $EXTERNAL_IP"

# Prepare the SSH command forcing login as 'cos'
SSH_CMD="gcloud compute ssh $INSTANCE_NAME --zone $ZONE --ssh-flag='-l cos'"
echo "================================================================"
echo "GCP ARM-based Ubuntu VM Details:"
echo "  Project:       $PROJECT"
echo "  Instance Name: $INSTANCE_NAME"
echo "  Zone:          $ZONE"
echo "  Region:        $REGION"
echo "  External IP:   $EXTERNAL_IP"
echo "================================================================"
echo "To SSH, run:"
echo "  $SSH_CMD"
echo "================================================================"

cat <<EOF > /tmp/gcp-instance-info.txt
GCP ARM-based VM Details:

Project:       $PROJECT
Instance Name: $INSTANCE_NAME
Zone:          $ZONE
Region:        $REGION
External IP:   $EXTERNAL_IP

To SSH, run:
  $SSH_CMD
EOF

echo "Instance info saved to /tmp/gcp-instance-info.txt."