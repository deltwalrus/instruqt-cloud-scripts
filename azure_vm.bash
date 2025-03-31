#!/usr/bin/env bash
set -euxo pipefail

###############################################################################
# Azure ARM-based VM Launch Script (using standard service principal credentials)
#
# This script logs in non-interactively using service principal credentials.
# It assumes that the following environment variables are already set:
#   ARM_CLIENT_ID
#   ARM_CLIENT_SECRET
#   ARM_TENANT_ID
#
# Deployment variables are defined at the top for ease of editing.
###############################################################################

# Deployment variables
# If AZURE_RESOURCE_GROUP is not set, a new RG will be created.
resourceGroup="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-eastus}"
vmName="MyUbuntuVM"
adminUsername="instruqt"
defaultImage="Canonical:ubuntu-24_04-lts:server-arm64:latest"
image="${IMAGE_NAME:-$defaultImage}"
defaultVmSize="Standard_A1_v5"
vmSize="${VM_SIZE:-$defaultVmSize}"

###############################################################################
# Login using service principal credentials (assumed to be in the env)
###############################################################################
az login --service-principal --username "$ARM_CLIENT_ID" --password "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" --output none
echo "Logged in with service principal. Using Azure location: $location"

###############################################################################
# Determine (or create) resource group.
# If AZURE_RESOURCE_GROUP is set, we use that; otherwise, create a new RG.
###############################################################################
if [[ -n "$resourceGroup" ]]; then
  RG_NAME="$resourceGroup"
  echo "Using resource group from AZURE_RESOURCE_GROUP: $RG_NAME"
else
  RG_NAME="ArmResourceGroup-$(date +%s)"
  echo "No AZURE_RESOURCE_GROUP set; creating new resource group: $RG_NAME"
  az group create --name "$RG_NAME" --location "$location" --output none
fi

###############################################################################
# Create (or update) virtual network and subnet in the resource group.
###############################################################################
VNET_NAME="ArmVNet-$RG_NAME"
SUBNET_NAME="ArmSubnet"
echo "Creating/updating virtual network $VNET_NAME and subnet $SUBNET_NAME..."
az network vnet create --resource-group "$RG_NAME" --name "$VNET_NAME" --subnet-name "$SUBNET_NAME" --location "$location" --output none

###############################################################################
# Create a network security group (NSG) in the resource group.
###############################################################################
NSG_NAME="ArmNSG-$RG_NAME-$(date +%s)"
echo "Creating network security group $NSG_NAME..."
az network nsg create --resource-group "$RG_NAME" --name "$NSG_NAME" --location "$location" --output none

###############################################################################
# Create NSG rule for inbound SSH (port 22).
###############################################################################
echo "Allowing inbound SSH (TCP port 22) in NSG $NSG_NAME..."
az network nsg rule create --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" \
  --name AllowSSH --protocol tcp --priority 1000 --destination-port-range 22 --output none

###############################################################################
# Create a public IP address in the resource group using --sku standard.
###############################################################################
PUBIP_NAME="ArmPublicIP-$RG_NAME-$(date +%s)"
echo "Creating public IP $PUBIP_NAME..."
az network public-ip create --resource-group "$RG_NAME" --name "$PUBIP_NAME" --allocation-method Static --sku standard --output none

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
# Ensure an SSH key exists at ~/.ssh/id_rsa.pub; generate one if missing.
###############################################################################
if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
  echo "No SSH public key found at ~/.ssh/id_rsa.pub. Generating one..."
  ssh-keygen -t rsa -b 2048 -f "$HOME/.ssh/id_rsa" -N ""
fi
SSH_KEY_VALUE="$HOME/.ssh/id_rsa.pub"
echo "Using SSH key: $SSH_KEY_VALUE"

###############################################################################
# Create an ARM-based VM using the specified image and machine size.
###############################################################################
echo "Creating Azure ARM-based VM $vmName..."
az vm create \
  --resource-group "$RG_NAME" \
  --name "$vmName" \
  --nics "$NIC_NAME" \
  --image "$image" \
  --size "$vmSize" \
  --admin-username "$adminUsername" \
  --ssh-key-value "$(cat "$SSH_KEY_VALUE")" \
  --output none

###############################################################################
# Retrieve Public IP.
###############################################################################
publicIp=$(az vm show --resource-group "$RG_NAME" --name "$vmName" -d --query publicIps -o tsv)

###############################################################################
# Output deployment information.
###############################################################################
echo "================================================================"
echo "Azure ARM-based Ubuntu VM Details:"
echo "  Resource Group: $RG_NAME"
echo "  Location:       $location"
echo "  VM Name:        $vmName"
echo "  Image:          $image"
echo "  VM Size:        $vmSize"
echo "  Public IP:      $publicIp"
echo "================================================================"
echo "To SSH into your VM, run:"
echo "  ssh $adminUsername@$publicIp"
echo "================================================================"
echo "To delete all resources, run:"
echo "  az group delete --name $RG_NAME --yes --no-wait"
echo "================================================================"

cat <<EOF2 > /tmp/azure-instance-info.txt
Azure ARM-based VM details:

Resource Group: $RG_NAME
VM Name:        $vmName
Location:       $location
Image:          $image
VM Size:        $vmSize
Public IP:      $publicIp

SSH command:
  ssh $adminUsername@$publicIp

To delete all resources, run:
  az group delete --name $RG_NAME --yes --no-wait
EOF2

echo "Instance info saved to /tmp/azure-instance-info.txt."
