#!/bin/bash
###############################################################
#  TITRE: LXC Container Management Script
#
#  AUTEUR:   Arion
#  VERSION: 2.0
#  CREATION:  
#  MODIFIE: Converted from Podman to LXC
#
#  DESCRIPTION: Script to manage LXC containers for development/testing
###############################################################
# set -eo pipefail

# Variables ###################################################
CONTAINER_USER=user
CONTAINER_HOME=/home/${CONTAINER_USER}
ANSIBLE_DIR="inventory/container_inv"
LXC_TEMPLATE="debian"
LXC_RELEASE="bullseye"

# Functions ###################################################
help(){
  echo "
  Usage: $0 
  -c \"<name1> <name2> <name3>\" : create containers with specified names
  -n <number> : create <number> containers with auto-generated names
  -i : information (ip and name)
  -s : start all containers created by this script
  -t : same to stop all containers
  -d : same for drop all containers
  -a : create an inventory for ansible with all ips

  Examples:
    $0 -c \"web db cache\"          # Creates containers: web, db, cache
    $0 -c \"server1 server2\"       # Creates containers: server1, server2
    $0 -n 3                        # Creates 3 containers: ${CONTAINER_USER}-debian-1, ${CONTAINER_USER}-debian-2, ${CONTAINER_USER}-debian-3
    "
}

createContainers(){
  CONTAINER_NAMES="$1"
  CONTAINER_HOME=/home/${CONTAINER_USER}
  
  # Check if LXC is installed and configured
  if ! command -v lxc-create &> /dev/null; then
    echo "Error: LXC is not installed. Please install lxc package first."
    exit 1
  fi
  
  # Convert space-separated names to array
  read -ra NAME_ARRAY <<< "$CONTAINER_NAMES"
  
  # Create containers for each name
  for name in "${NAME_ARRAY[@]}"; do
    # Clean the name (remove special characters, convert to lowercase)
    CLEAN_NAME=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
    CONTAINER_NAME="${CONTAINER_USER}-${CLEAN_NAME}"
    
    # Check if container already exists
    if sudo lxc-ls | grep -q "^${CONTAINER_NAME}$"; then
      echo "Warning: Container $CONTAINER_NAME already exists, skipping..."
      continue
    fi
    
    echo "Creating container: $CONTAINER_NAME"
    
    # Create LXC container
    sudo lxc-create -t download -n $CONTAINER_NAME -- --dist $LXC_TEMPLATE --release $LXC_RELEASE --arch amd64
    
    # Start container
    sudo lxc-start -n $CONTAINER_NAME -d
    
    # Wait for container to be fully started
    sleep 5
    
    # Update package list and install SSH server
    sudo lxc-attach -n $CONTAINER_NAME -- apt-get update
    sudo lxc-attach -n $CONTAINER_NAME -- apt-get install -y openssh-server sudo
    
    # Create user
    sudo lxc-attach -n $CONTAINER_NAME -- useradd -m -s /bin/bash ${CONTAINER_USER}
    sudo lxc-attach -n $CONTAINER_NAME -- sh -c "echo '${CONTAINER_USER}:password' | chpasswd"
    
    # Configure SSH
    sudo lxc-attach -n $CONTAINER_NAME -- mkdir -p ${CONTAINER_HOME}/.ssh
    sudo lxc-attach -n $CONTAINER_NAME -- chmod 700 ${CONTAINER_HOME}/.ssh
    sudo lxc-attach -n $CONTAINER_NAME -- chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh
    
    # Copy SSH public key if it exists
    if [ -f ${HOME}/.ssh/id_rsa.pub ]; then
      sudo cp ${HOME}/.ssh/id_rsa.pub /var/lib/lxc/$CONTAINER_NAME/rootfs${CONTAINER_HOME}/.ssh/authorized_keys
      sudo lxc-attach -n $CONTAINER_NAME -- chmod 600 ${CONTAINER_HOME}/.ssh/authorized_keys
      sudo lxc-attach -n $CONTAINER_NAME -- chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh/authorized_keys
    fi
    
    # Configure sudo
    sudo lxc-attach -n $CONTAINER_NAME -- sh -c "echo '${CONTAINER_USER} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers"
    
    # Start SSH service
    sudo lxc-attach -n $CONTAINER_NAME -- systemctl enable ssh
    sudo lxc-attach -n $CONTAINER_NAME -- systemctl start ssh
    
    # Configure network (enable DHCP)
    sudo lxc-attach -n $CONTAINER_NAME -- dhclient eth0 2>/dev/null || true
    
    echo "Container $CONTAINER_NAME created successfully"
  done
  
  infosContainers
  exit 0
}

createContainersByNumber(){
  CONTAINER_NUMBER=$1
  CONTAINER_HOME=/home/${CONTAINER_USER}
  
  # Check if LXC is installed and configured
  if ! command -v lxc-create &> /dev/null; then
    echo "Error: LXC is not installed. Please install lxc package first."
    exit 1
  fi
  
  # Calculate the ID to use
  id_already=$(sudo lxc-ls | grep -c "^${CONTAINER_USER}-debian-" 2>/dev/null || echo "0")
  id_min=$((id_already + 1))
  id_max=$((id_already + ${CONTAINER_NUMBER}))
  
  # Create containers in loop
  for i in $(seq $id_min $id_max); do
    CONTAINER_NAME="${CONTAINER_USER}-debian-$i"
    echo "Creating container: $CONTAINER_NAME"
    
    # Create LXC container
    sudo lxc-create -t download -n $CONTAINER_NAME -- --dist $LXC_TEMPLATE --release $LXC_RELEASE --arch amd64
    
    # Start container
    sudo lxc-start -n $CONTAINER_NAME -d
    
    # Wait for container to be fully started
    sleep 5
    
    # Update package list and install SSH server
    sudo lxc-attach -n $CONTAINER_NAME -- apt-get update
    sudo lxc-attach -n $CONTAINER_NAME -- apt-get install -y openssh-server sudo
    
    # Create user
    sudo lxc-attach -n $CONTAINER_NAME -- useradd -m -s /bin/bash ${CONTAINER_USER}
    sudo lxc-attach -n $CONTAINER_NAME -- sh -c "echo '${CONTAINER_USER}:password' | chpasswd"
    
    # Configure SSH
    sudo lxc-attach -n $CONTAINER_NAME -- mkdir -p ${CONTAINER_HOME}/.ssh
    sudo lxc-attach -n $CONTAINER_NAME -- chmod 700 ${CONTAINER_HOME}/.ssh
    sudo lxc-attach -n $CONTAINER_NAME -- chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh
    
    # Copy SSH public key if it exists
    if [ -f ${HOME}/.ssh/id_rsa.pub ]; then
      sudo cp ${HOME}/.ssh/id_rsa.pub /var/lib/lxc/$CONTAINER_NAME/rootfs${CONTAINER_HOME}/.ssh/authorized_keys
      sudo lxc-attach -n $CONTAINER_NAME -- chmod 600 ${CONTAINER_HOME}/.ssh/authorized_keys
      sudo lxc-attach -n $CONTAINER_NAME -- chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh/authorized_keys
    fi
    
    # Configure sudo
    sudo lxc-attach -n $CONTAINER_NAME -- sh -c "echo '${CONTAINER_USER} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers"
    
    # Start SSH service
    sudo lxc-attach -n $CONTAINER_NAME -- systemctl enable ssh
    sudo lxc-attach -n $CONTAINER_NAME -- systemctl start ssh
    
    # Configure network (enable DHCP)
    sudo lxc-attach -n $CONTAINER_NAME -- dhclient eth0 2>/dev/null || true
    
    echo "Container $CONTAINER_NAME created successfully"
  done
  
  infosContainers
  exit 0
}

infosContainers(){
  echo ""
  echo "Informations des conteneurs : "
  echo ""
  
  # List all containers with their status and IP
  for container in $(sudo lxc-ls | grep "^${CONTAINER_USER}-"); do
    if sudo lxc-info -n $container | grep -q "RUNNING"; then
      IP=$(sudo lxc-info -n $container -iH 2>/dev/null || echo "No IP")
      echo "$container -- Status: RUNNING -- IP: $IP"
    else
      echo "$container -- Status: STOPPED -- IP: N/A"
    fi
  done
  
  echo ""
  exit 0
}

dropContainers(){
  echo "Dropping all containers..."
  
  for container in $(sudo lxc-ls | grep "^${CONTAINER_USER}-"); do
    echo "$container - stopping and destroying..."
    sudo lxc-stop -n $container -k 2>/dev/null || true
    sudo lxc-destroy -n $container
  done
  
  infosContainers
}

startContainers(){
  echo "Starting all containers..."
  
  for container in $(sudo lxc-ls | grep "^${CONTAINER_USER}-"); do
    echo "$container - starting..."
    sudo lxc-start -n $container -d 2>/dev/null || echo "$container already running or failed to start"
  done
  
  # Wait a moment for containers to get IP addresses
  sleep 3
  infosContainers
}

stopContainers(){
  echo "Stopping all containers..."
  
  for container in $(sudo lxc-ls | grep "^${CONTAINER_USER}-"); do
    echo "$container - stopping..."
    sudo lxc-stop -n $container 2>/dev/null || echo "$container already stopped"
  done
  
  infosContainers
}

createAnsible(){
  echo ""
  echo "Creating Ansible inventory..."
  
  mkdir -p ${ANSIBLE_DIR}
  echo "all:" > ${ANSIBLE_DIR}/00_inventory.yml
  echo "  vars:" >> ${ANSIBLE_DIR}/00_inventory.yml
  echo "    ansible_python_interpreter: /usr/bin/python3" >> ${ANSIBLE_DIR}/00_inventory.yml
  echo "    ansible_user: ${CONTAINER_USER}" >> ${ANSIBLE_DIR}/00_inventory.yml
  echo "  hosts:" >> ${ANSIBLE_DIR}/00_inventory.yml
  
  # Add running containers to inventory
  for container in $(sudo lxc-ls | grep "^${CONTAINER_USER}-"); do
    if sudo lxc-info -n $container | grep -q "RUNNING"; then
      IP=$(sudo lxc-info -n $container -iH 2>/dev/null)
      if [ -n "$IP" ] && [ "$IP" != "No IP" ]; then
        echo "    $IP:" >> ${ANSIBLE_DIR}/00_inventory.yml
      fi
    fi
  done
  
  mkdir -p ${ANSIBLE_DIR}/host_vars
  mkdir -p ${ANSIBLE_DIR}/group_vars
  
  echo "Ansible inventory created in ${ANSIBLE_DIR}/00_inventory.yml"
  echo ""
}

# Let's Go !! #################################################
if [ "$#" -eq 0 ]; then
  help
fi

while getopts ":c:ahitsd" options; do
  case "${options}" in 
    a)
      createAnsible
      ;;
    c)
      createContainers ${OPTARG}
      ;;
    i)
      infosContainers
      ;;
    s)
      startContainers
      ;;
    t)
      stopContainers
      ;;
    d)
      dropContainers
      ;;
    h)
      help
      exit 1
      ;;
    *)
      help
      exit 1
      ;;
  esac
done