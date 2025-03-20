#!/usr/bin/env bash
set -euxo pipefail

###
# Unless the account is a service principal, you cannot authenticate to Azure automatically by script, manual user intervemtion is required.
#
# Therefore, the user should be instructed to run this script and copy/paste the code to authenticate, then they can return to the track and proceed.
# 
# Commenting out the cat command to create a file from this script on the sandbox container, this allows GitHub to syntax highlight for ease of reading. Uncomment the next 4 code lines to use as required.
###

# cat << 'EOF' > ~/azure_launch_script.sh 
#
##!/usr/bin/env bash
#set -euxo pipefail

# Non-interactive login using service principal if credentials exist;
# Otherwise, fall back to interactive login.
if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]]; then
  echo "Logging in non-interactively using service principal..."
  az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID" --output none
else
  echo "No service principal credentials found; please complete interactive login."
  az login --output none
fi

# Set default location from AZURE_LOCATION env var or default to eastus.
LOCATION="${AZURE_LOCATION:-eastus}"
echo "Using Azure location: $LOCATION"

# Create a resource group with a unique name.
RG_NAME="ArmResourceGroup-$(date +%s)"
echo "Creating resource group $RG_NAME in $LOCATION..."
az group create --name "$RG_NAME" --location "$LOCATION" --output none

# Create a virtual network and subnet.
VNET_NAME="ArmVNet-$RG_NAME"
SUBNET_NAME="ArmSubnet"
echo "Creating virtual network $VNET_NAME and subnet $SUBNET_NAME..."
az network vnet create --resource-group "$RG_NAME" --name "$VNET_NAME" --subnet-name "$SUBNET_NAME" --output none

# Create a network security group.
NSG_NAME="ArmNSG-$RG_NAME"
echo "Creating network security group $NSG_NAME..."
az network nsg create --resource-group "$RG_NAME" --name "$NSG_NAME" --output none

# Define common ports: SSH, HTTP, HTTPS, plus other common ports.
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

# Create a public IP address.
PUBIP_NAME="ArmPublicIP-$RG_NAME"
echo "Creating public IP $PUBIP_NAME..."
az network public-ip create --resource-group "$RG_NAME" --name "$PUBIP_NAME" --allocation-method Static --sku Basic --output none

# Create a network interface (NIC) with the NSG and public IP.
NIC_NAME="ArmNIC-$RG_NAME"
echo "Creating network interface $NIC_NAME..."
az network nic create --resource-group "$RG_NAME" --name "$NIC_NAME" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_NAME" --public-ip-address "$PUBIP_NAME" \
  --output none

# Ensure an SSH key exists at ~/.ssh/id_rsa; generate one if missing.
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  echo "No SSH key found at ~/.ssh/id_rsa. Generating one..."
  ssh-keygen -t rsa -b 2048 -f "$HOME/.ssh/id_rsa" -N ""
fi
SSH_KEY_VALUE="$HOME/.ssh/id_rsa.pub"
echo "Using SSH key: $SSH_KEY_VALUE"

# Create an ARM-based VM.
# Using Standard_A1_v5 (Ampere Altra) and Ubuntu 22.04 LTS.
VM_NAME="ArmVM-$RG_NAME"
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

# Get the public IP address of the VM.
EXTERNAL_IP=$(az vm list-ip-addresses --resource-group "$RG_NAME" --name "$VM_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
echo "VM $VM_NAME is running with public IP: $EXTERNAL_IP"

# Print SSH command.
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
echo "To delete the resources, run:"
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
EOF

chmod +x ~/azure_launch_script.sh
echo "Azure launch script has been written to ~/azure_launch_script.sh."
echo "Run it interactively when you log in."
