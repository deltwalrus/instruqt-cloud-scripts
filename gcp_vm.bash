#!/usr/bin/env bash
set -euxo pipefail

###
# NB! WIP script, not yet fully debugged
###

# Determine project, zone, and region from your gcloud config
PROJECT=$(gcloud config get-value project)
ZONE=$(gcloud config get-value compute/zone || true)
if [ -z "$ZONE" ]; then
  # Default zone if none is set – choose one that supports ARM (e.g., us-east1-a)
  ZONE="us-east1-a"
fi
REGION=$(gcloud config get-value compute/region || true)
if [ -z "$REGION" ]; then
  # Derive region from zone (e.g. us-east1 from us-east1-a)
  REGION="${ZONE%-*}"
fi

echo "GCP Project: $PROJECT"
echo "Zone: $ZONE, Region: $REGION"

# Create a firewall rule to allow inbound traffic on common ports
FIREWALL_NAME="arm-vm-fw-$(date +%s)"
PORTS="22,80,443,3306,5432,6379,27017,5000,8080,8443"
echo "Creating firewall rule $FIREWALL_NAME to allow TCP ports: $PORTS"
gcloud compute firewall-rules create "$FIREWALL_NAME" \
  --allow tcp:$PORTS \
  --target-tags "arm-vm" \
  --quiet

# Create the ARM-based VM.
# Use an Ampere-based machine type: t2a-standard-1.
# Use the "cos-arm64-stable" image from the cos-cloud project.
INSTANCE_NAME="arm-vm-$(date +%s)"
echo "Creating instance $INSTANCE_NAME (machine type: t2a-standard-1)..."
gcloud compute instances create "$INSTANCE_NAME" \
  --machine-type=t2a-standard-1 \
  --image-family=cos-arm64-stable \
  --image-project=cos-cloud \
  --tags=arm-vm \
  --quiet

# (Optionally wait a bit for the instance to be ready)
echo "Waiting for instance to be provisioned..."
sleep 30

# Retrieve the external IP address
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo "Instance $INSTANCE_NAME is running with external IP: $EXTERNAL_IP"

# Print SSH instructions
SSH_CMD="gcloud compute ssh $INSTANCE_NAME --zone $ZONE"
echo "================================================================"
echo "GCP ARM-based VM details:"
echo "  Project:       $PROJECT"
echo "  Instance Name: $INSTANCE_NAME"
echo "  Zone:          $ZONE"
echo "  Region:        $REGION"
echo "  External IP:   $EXTERNAL_IP"
echo "================================================================"
echo "To SSH into your VM, run:"
echo "  $SSH_CMD"
echo "================================================================"

cat <<EOF > /tmp/gcp-instance-info.txt
GCP ARM-based VM details:

Project:       $PROJECT
Instance Name: $INSTANCE_NAME
Zone:          $ZONE
Region:        $REGION
External IP:   $EXTERNAL_IP

To SSH, run:
  $SSH_CMD

To delete the instance and firewall rule:
  gcloud compute instances delete $INSTANCE_NAME --zone $ZONE --quiet
  gcloud compute firewall-rules delete $FIREWALL_NAME --quiet
EOF

echo "Instance info saved to /tmp/gcp-instance-info.txt."
