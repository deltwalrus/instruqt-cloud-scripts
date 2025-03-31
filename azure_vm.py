#!/usr/bin/env python3
import os
import sys
import time

from azure.identity import ClientSecretCredential
from azure.mgmt.resource import ResourceManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.compute import ComputeManagementClient

# --- Utility functions ---
def get_env_variable(var_name, required=True, default=None):
    value = os.environ.get(var_name, default)
    if required and not value:
        print(f"Error: Environment variable {var_name} is required.", file=sys.stderr)
        sys.exit(1)
    return value

# --- Retrieve service principal credentials using indirect environment variable names ---
instr_sub = get_env_variable("INSTRUQT_AZURE_SUBSCRIPTIONS")
spn_id_var = f"INSTRUQT_AZURE_SUBSCRIPTION_{instr_sub}_SPN_ID"
spn_password_var = f"INSTRUQT_AZURE_SUBSCRIPTION_{instr_sub}_SPN_PASSWORD"
tenant_id_var = f"INSTRUQT_AZURE_SUBSCRIPTION_{instr_sub}_TENANT_ID"

spn_id = get_env_variable(spn_id_var)
spn_password = get_env_variable(spn_password_var)
tenant_id = get_env_variable(tenant_id_var)
subscription_id = get_env_variable("AZURE_SUBSCRIPTION_ID")
location = os.environ.get("AZURE_LOCATION", "eastus")

print(f"Using Azure location: {location}")

# --- Authenticate using the service principal credentials ---
credential = ClientSecretCredential(
    tenant_id=tenant_id,
    client_id=spn_id,
    client_secret=spn_password,
)

# Create management clients
resource_client = ResourceManagementClient(credential, subscription_id)
network_client = NetworkManagementClient(credential, subscription_id)
compute_client = ComputeManagementClient(credential, subscription_id)

# --- Determine Resource Group ---
rg_name = os.environ.get("AZURE_RESOURCE_GROUP")
if rg_name:
    print(f"Using resource group from AZURE_RESOURCE_GROUP: {rg_name}")
else:
    # List existing resource groups; if any exist, pick the first one.
    rgs = list(resource_client.resource_groups.list())
    if rgs:
        rg_name = rgs[0].name
        print(f"Found existing resource group: {rg_name}")
    else:
        # Create a new resource group
        rg_name = f"ArmResourceGroup-{int(time.time())}"
        print(f"No existing resource groups found; creating new one: {rg_name}")
        resource_client.resource_groups.create_or_update(rg_name, {"location": location})

# --- Create Virtual Network and Subnet ---
vnet_name = f"ArmVNet-{rg_name}"
subnet_name = "ArmSubnet"
address_prefix = "10.0.0.0/16"
subnet_prefix = "10.0.0.0/24"

print(f"Creating virtual network {vnet_name} and subnet {subnet_name}...")
vnet_params = {
    "location": location,
    "address_space": {"address_prefixes": [address_prefix]},
}
vnet_result = network_client.virtual_networks.begin_create_or_update(rg_name, vnet_name, vnet_params).result()

subnet_params = {"address_prefix": subnet_prefix}
subnet_result = network_client.subnets.begin_create_or_update(rg_name, vnet_name, subnet_name, subnet_params).result()

# --- Create Network Security Group (NSG) with inbound rules ---
nsg_name = f"ArmNSG-{rg_name}-{int(time.time())}"
print(f"Creating network security group {nsg_name}...")
nsg_params = {"location": location}
nsg_result = network_client.network_security_groups.begin_create_or_update(rg_name, nsg_name, nsg_params).result()

# Define the common ports to open
ports = [22, 80, 443, 3306, 5432, 6379, 27017, 5000, 8080, 8443]
priority = 1000
for port in ports:
    rule_name = f"AllowTCP{port}"
    print(f"Creating NSG rule {rule_name} for port {port}...")
    rule_params = {
        "protocol": "Tcp",
        "source_address_prefix": "*",
        "destination_address_prefix": "*",
        "access": "Allow",
        "direction": "Inbound",
        "priority": priority,
        "destination_port_range": str(port),
        "source_port_range": "*",
    }
    network_client.security_rules.begin_create_or_update(rg_name, nsg_name, rule_name, rule_params).result()
    priority += 10

# --- Create Public IP ---
pubip_name = f"ArmPublicIP-{rg_name}-{int(time.time())}"
print(f"Creating public IP {pubip_name}...")
pubip_params = {
    "location": location,
    "public_ip_allocation_method": "Static",
    "sku": {"name": "Basic"},
}
pubip_result = network_client.public_ip_addresses.begin_create_or_update(rg_name, pubip_name, pubip_params).result()

# --- Create Network Interface (NIC) ---
nic_name = f"ArmNIC-{rg_name}-{int(time.time())}"
print(f"Creating network interface {nic_name}...")
nic_params = {
    "location": location,
    "ip_configurations": [{
        "name": "ipconfig1",
        "subnet": {"id": subnet_result.id},
        "public_ip_address": {"id": pubip_result.id},
    }],
    "network_security_group": {"id": nsg_result.id},
}
nic_result = network_client.network_interfaces.begin_create_or_update(rg_name, nic_name, nic_params).result()

# --- Create Virtual Machine ---
vm_name = f"ArmVM-{rg_name}-{int(time.time())}"
print(f"Creating virtual machine {vm_name}...")

# Read the SSH public key from the local file (~/.ssh/id_rsa.pub)
ssh_key_path = os.path.expanduser("~/.ssh/id_rsa.pub")
if not os.path.exists(ssh_key_path):
    print(f"Error: SSH public key not found at {ssh_key_path}", file=sys.stderr)
    sys.exit(1)
with open(ssh_key_path, "r") as f:
    ssh_pub_key = f.read().strip()

vm_params = {
    "location": location,
    "hardware_profile": {"vm_size": "Standard_A1_v5"},
    "storage_profile": {
        "image_reference": {
            "publisher": "Canonical",
            "offer": "UbuntuServer",
            "sku": "22_04-lts",
            "version": "latest",
        }
    },
    "os_profile": {
        "computer_name": vm_name,
        "admin_username": "azureuser",
        "linux_configuration": {
            "disable_password_authentication": True,
            "ssh": {
                "public_keys": [{
                    "path": f"/home/azureuser/.ssh/authorized_keys",
                    "key_data": ssh_pub_key,
                }]
            },
        },
    },
    "network_profile": {
        "network_interfaces": [{
            "id": nic_result.id,
            "primary": True,
        }]
    },
}
vm_result = compute_client.virtual_machines.begin_create_or_update(rg_name, vm_name, vm_params).result()

# --- Retrieve Public IP Address ---
public_ip_address = network_client.public_ip_addresses.get(rg_name, pubip_name)
public_ip = public_ip_address.ip_address

# Wait until the public IP is assigned (polling for a few seconds)
timeout = 300  # seconds
interval = 10  # seconds
elapsed = 0
while not public_ip and elapsed < timeout:
    time.sleep(interval)
    elapsed += interval
    public_ip_address = network_client.public_ip_addresses.get(rg_name, pubip_name)
    public_ip = public_ip_address.ip_address

if not public_ip:
    print("Error: Timed out waiting for public IP assignment.", file=sys.stderr)
    sys.exit(1)

ssh_cmd = f"ssh azureuser@{public_ip}"
print("================================================================")
print("Azure ARM-based VM details:")
print(f"  Resource Group: {rg_name}")
print(f"  VM Name:        {vm_name}")
print(f"  Location:       {location}")
print(f"  Public IP:      {public_ip}")
print("================================================================")
print("To SSH into your VM, run:")
print(f"  {ssh_cmd}")
print("================================================================")

info = f"""
Azure ARM-based VM details:

Resource Group: {rg_name}
VM Name:        {vm_name}
Location:       {location}
Public IP:      {public_ip}

SSH command:
  {ssh_cmd}

To delete all resources, run:
  az group delete --name {rg_name} --yes --no-wait
"""
with open("/tmp/azure-instance-info.txt", "w") as f:
    f.write(info)

print("Instance info saved to /tmp/azure-instance-info.txt.")

