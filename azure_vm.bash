#!/usr/bin/env bash
set -euxo pipefail

###############################################################################
# Azure ARM-based VM Launch Script (using standard service principal credentials)
#
# This script logs in non-interactively using service principal credentials.
# The credentials are obtained via:
#   SPN_ID:       eval echo "${INSTRUQT_AZURE_SUBSCRIPTION_${INSTRUQT_AZURE_SUBSCRIPTIONS}_SPN_ID}"
#   SPN_PASSWORD: eval echo "${INSTRUQT_AZURE_SUBSCRIPTION_${INSTRUQT_AZURE_SUBSCRIPTIONS}_SPN_PASSWORD}"
#   TENANT_ID:    eval echo "${INSTRUQT_AZURE_SUBSCRIPTION_${INSTRUQT_AZURE_SUBSCRIPTIONS}_TENANT_ID}"
#
# If any of these are empty, the script exits with an error.
#
# The script then determines (or discovers) an existing resource group,
# creates/updates networking (VNET, subnet, NSG with inbound rules), a public IP,
# NIC, and finally creates an ARM-based VM.
#
# Finally, it prints an SSH command and writes instance details to
# /tmp/azure-instance-info.txt.
###############################################################################

# Ensure INSTRUQT_AZURE_SUBSCRIPTIONS is set
if [[ -z "${INSTRUQT_AZURE_SUBSCRIPTIONS:-}" ]]; then
  echo "Error: INSTRUQT_AZURE_SUBSCRIPTIONS is not set."
  exit 1
fi

# Use indirect expansion to retrieve the credentials.
SPN_ID_VAR="INSTRUQT_AZURE_SUBSCRIPTION_${INSTRUQT_AZURE_SUBSCRIPTIONS}_SPN_ID"
SPN_PASSWORD_VAR="INSTRUQT_AZURE_SUBSCRIPTION_${INSTRUQT_AZURE_SUBSCRIPTIONS}_SPN_PASSWORD"
TENANT_ID_VAR="INSTRUQT_AZURE_SUBSCRIPTION_${INSTRUQT_AZURE_SUBSCRIPTIONS}_TENANT_ID"

SPN_ID=$(eval echo "\${${SPN_ID_VAR}:-}")
SPN_PASSWORD=$(eval echo "\${${SPN_PASSWORD_VAR}:-}")
TENANT_ID=$(eval echo "\${${TENANT_ID_VAR}:-}")

if [[ -z "$SPN_ID" || -z "$SPN_PASSWORD" || -z "$TENANT_ID" ]]; then
  echo "Error: One or more required service principal variables are not set."
  echo "Ensure that the following variables are defined:"
  echo "  ${SPN_ID_VAR}"
  echo "  ${SPN_PASSWORD_VAR}"
  echo "  ${TENANT_ID_VAR}"
  exit 1
fi

echo "Logging in non-interactively using service principal credentials..."
# Use long-form options and quote the password to handle complex characters.
az login --service-principal --username "$SPN_ID" --password "$SPN_PASSWORD" --tenant "$TENANT_ID" --output none

# Set default location (from AZURE_LOCATION env variable or default to eastus)
LOCATION="${AZURE_LOCATION:-eastus}"
echo "Using Azure location: $LOCATION"

###############################################################################
# Determine resource group to use.
#   - If AZURE_RESOURCE_GROUP is set, use that.
#   - Else, list resource groups and pick the first one.
#   - If none exist, create a new one.
###############################################################################
if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
  RG_NAME="$AZURE_RESOURCE_GROUP"
  echo "Using resource group from AZURE_RESOURCE_GROUP: $RG_NAME"
else
  echo "AZURE_RESOURCE_GROUP not set. Checking for existing resource groups..."
  EXISTING_RG=$(az group list --query "[0].name" --output tsv || true)
  if [[ -n "$EXISTING_RG" ]]; then
    RG_NAME="$EXISTING_RG"
    echo "Found existing resource group: $RG_NAME"
  else
    RG_NAME="ArmResourceGroup-$(date +%s)"
    echo "No existing resource group found; creating new one: $RG_NAME"
    az group create --name "$RG_NAME" --location "$LOCATION" --output none
  fi
fi

###############################################################################
# Create (or update) virtual network and subnet in the resource group.
###############################################################################
VNET_NAME="ArmVNet-$RG_NAME"
SUBNET_NAME="ArmSubnet"
echo "Creating/updating virtual network $VNET_NAME and subnet $SUBNET_NAME..."
az network vnet create --resource-group "$RG_NAME" --name "$VNET_NAME" --subnet-name "$SUBNET_NAME" --location "$LOCATION" --output none

###############################################################################
# Create a network security group (NSG) in the resource group.
###############################################################################
NSG_NAME="ArmNSG-$RG_NAME-$(date +%s)"
echo "Creating network security group $NSG_NAME..."
az network nsg create --resource-group "$RG_NAME" --name "$NSG_NAME" --location "$LOCATION" --output none

###############################################################################
# Create NSG rules for common inbound ports.
###############################################################################
PORTS=(22 80 443 3306 5432 6379 27017 5000 8080 8443)
PRIORITY=1000
for PORT in "${PORTS[@]}"; do
  echo "Allowing inbound TCP port $PORT..."
  az network nsg rule create --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" \
    --name "AllowTCP${PORT}" \
    --priority "$PRIORITY" \
    --direction Inbound --access Allow --protocol Tcp --destination-port-range "$PORT" \
    --output none
  PRIORITY=$((PRIORITY+10))
done

###############################################################################
# Create a public IP address in the resource group.
###############################################################################
PUBIP_NAME="ArmPublicIP-$RG_NAME-$(date +%s)"
echo "Creating public IP $PUBIP_NAME..."
az network public-ip create --resource-group "$RG_NAME" --name "$PUBIP_NAME" --allocation-method Static --sku Basic --output none

###############################################################################
# Create a network interface (NIC) with the NSG and public IP.
###############################################################################
NIC_NAME="ArmNIC-$RG_NAME-$(date +%s)"
echo "Creating network interface $NIC_NAME..."
az network nic create --resource-group "$RG_NAME" --name "$NIC_NAME" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_NAME" --public-ip-address "$PUBIP_NAME" \
  --output none

###############################################################################
# Ensure an SSH key exists at ~/.ssh/id_rsa; generate one if missing.
###############################################################################
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  echo "No SSH key found at ~/.ssh/id_rsa. Generating one..."
  ssh-keygen -t rsa -b 2048 -f "$HOME/.ssh/id_rsa" -N ""
fi
SSH_KEY_VALUE="$HOME/.ssh/id_rsa.pub"
echo "Using SSH key: $SSH_KEY_VALUE"

###############################################################################
# Create an ARM-based VM.
# Using Standard_A1_v5 (Ampere Altra) and Ubuntu 22.04 LTS.
###############################################################################
VM_NAME="ArmVM-$RG_NAME-$(date +%s)"
echo "Creating Azure ARM-based VM $VM_NAME..."
az vm create --resource-group "$RG_NAME" --name "$VM_NAME" \
  --nics "$NIC_NAME" \
  --image Canonical:UbuntuServer:22_04-lts:latest \
  --size Standard_A1_v5 \
  --admin-username azureuser \
  --ssh-key-value "$SSH_KEY_VALUE" \
  --output none

echo "Waiting for VM to be provisioned..."
sleep 30

###############################################################################
# Retrieve the public IP address of the VM.
###############################################################################
EXTERNAL_IP=$(az vm list-ip-addresses --resource-group "$RG_NAME" --name "$VM_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
echo "VM $VM_NAME is running with public IP: $EXTERNAL_IP"

###############################################################################
# Print the SSH command and output instance info.
###############################################################################
SSH_CMD="ssh azureuser@$EXTERNAL_IP"
echo "================================================================"
echo "Azure ARM-based VM details:"
echo "  Resource Group: $RG_NAME"
echo "  VM Name:        $VM_NAME"
echo "  Location:       $LOCATION"
echo "  Public IP:      $EXTERNAL_IP"
echo "================================================================"
echo "To SSH into your VM, run:"
echo "  $SSH_CMD"
echo "================================================================"
echo "To delete all resources, run:"
echo "  az group delete --name $RG_NAME --yes --no-wait"
echo "================================================================"

cat <<EOF2 > /tmp/azure-instance-info.txt
Azure ARM-based VM details:

Resource Group: $RG_NAME
VM Name:        $VM_NAME
Location:       $LOCATION
Public IP:      $EXTERNAL_IP

SSH command:
  $SSH_CMD

To delete all resources, run:
  az group delete --name $RG_NAME --yes --no-wait
EOF2

echo "Instance info saved to /tmp/azure-instance-info.txt."
