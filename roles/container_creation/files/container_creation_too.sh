#!/bin/sh

# CONTAINER_USER=$USER
createContainer() {
    CONTAINER_USER=$USER
    ANSIBLE_DIR="inventory/container_inv"
    CONTAINER_HOME=/home/${CONTAINER_USER}

    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 -c <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi

    for node_name in "$@"; do
        if [ -z "$node_name" ]; then
            echo "Node name cannot be empty. Please provide valid node names."
            exit 1
        fi

        # Check if container for the node already exists
        if lxc list --format csv | cut -d, -f1 | grep -q "^$node_name$"; then
            echo "Info: Container $node_name already exists. Skipping creation."
        else
            # Create container
            echo "Creating container $node_name..."
            if ! lxc launch ubuntu:24.04 "$node_name"; then
                echo "Error: Failed to create node $node_name. Please check your inputs and try again."
                exit 1
            fi
            echo "Success: Node $node_name created successfully."
            echo "Node $node_name is starting. Please wait..."
            sleep 10  # Wait for container to fully start and get IP
        fi

        # Wait for container to be ready
        echo "Waiting for container $node_name to be ready..."
        while ! lxc exec "$node_name" -- systemctl is-active --quiet systemd-resolved 2>/dev/null; do
            sleep 2
        done

        # Create user in container if it doesn't exist
        if ! lxc exec "$node_name" -- id "$CONTAINER_USER" 2>/dev/null; then
            echo "Creating user $CONTAINER_USER in container $node_name..."
            lxc exec "$node_name" -- useradd -m -s /bin/bash "$CONTAINER_USER"
            lxc exec "$node_name" -- passwd -d "$CONTAINER_USER"  # Remove password
        fi

        # Configure container
        lxc exec "$node_name" -- apt update
        lxc exec "$node_name" -- apt install -y openssh-server

        # Create .ssh directory
        lxc exec "$node_name" -- mkdir -p -m 0700 "${CONTAINER_HOME}/.ssh"
        lxc exec "$node_name" -- chown "${CONTAINER_USER}:${CONTAINER_USER}" "${CONTAINER_HOME}/.ssh"

        # Keys Adding
        if [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
            KEY_CONTENT=$(cat "${HOME}/.ssh/id_rsa.pub")
        else
            echo "Public key not found at ${HOME}/.ssh/id_rsa.pub. Please generate an SSH key pair first."
            exit 1
        fi

        if [ -z "$KEY_CONTENT" ]; then
            echo "Public key is empty. Please check your SSH key."
            exit 1
        fi

        # Add public key to container's authorized_keys
        echo "Adding public key to container $node_name..."
        lxc exec "$node_name" -- sh -c "echo '$KEY_CONTENT' > ${CONTAINER_HOME}/.ssh/authorized_keys"
        
        # Ensure the .ssh directory and authorized_keys file have the correct permissions
        lxc exec "$node_name" -- chmod 700 "${CONTAINER_HOME}/.ssh"
        lxc exec "$node_name" -- chmod 600 "${CONTAINER_HOME}/.ssh/authorized_keys"
        lxc exec "$node_name" -- chown -R "${CONTAINER_USER}:${CONTAINER_USER}" "${CONTAINER_HOME}/.ssh"

        # Configure SSH daemon
        lxc exec "$node_name" -- sh -c "echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config"
        lxc exec "$node_name" -- sh -c "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config"
        lxc exec "$node_name" -- sh -c "echo 'PermitRootLogin no' >> /etc/ssh/sshd_config"
        lxc exec "$node_name" -- sh -c "echo 'AllowUsers ${CONTAINER_USER}' >> /etc/ssh/sshd_config"
        lxc exec "$node_name" -- sh -c "echo 'X11Forwarding yes' >> /etc/ssh/sshd_config"
        lxc exec "$node_name" -- sh -c "echo 'UsePAM yes' >> /etc/ssh/sshd_config"
        lxc exec "$node_name" -- sh -c "echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> /etc/ssh/sshd_config"
        
        # Enable and start SSH service
        lxc exec "$node_name" -- systemctl enable ssh
        lxc exec "$node_name" -- systemctl restart ssh

        # User to be able to use sudo without password
        lxc exec "$node_name" -- mkdir -p /etc/sudoers.d
        lxc exec "$node_name" -- sh -c "echo '${CONTAINER_USER} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${CONTAINER_USER}"
        lxc exec "$node_name" -- chmod 440 "/etc/sudoers.d/${CONTAINER_USER}"
        
        echo "Container $node_name created and configured successfully."
    done

    # Create Ansible inventory
    if [ ! -d "${ANSIBLE_DIR}" ]; then
        mkdir -p "${ANSIBLE_DIR}"
    else
        rm -rf "${ANSIBLE_DIR}"/*
    fi
    
    echo "containers:" > "${ANSIBLE_DIR}/inventory.yml"
    echo "  vars:" >> "${ANSIBLE_DIR}/inventory.yml"
    echo "  hosts:" >> "${ANSIBLE_DIR}/inventory.yml"
    
    # Get container info and create inventory
    lxc list --format csv | while IFS=',' read -r name status ipv4 ipv6 type snapshots; do
        if [ -n "$ipv4" ] && [ "$status" = "RUNNING" ]; then
            clean_ip=$(echo "$ipv4" | sed 's/ (.*)//' | tr -d ' ')
            echo "    $name:" >> "${ANSIBLE_DIR}/inventory.yml"
            echo "      ansible_host: $clean_ip" >> "${ANSIBLE_DIR}/inventory.yml"
        fi
    done
    
    mkdir -p "${ANSIBLE_DIR}/host_vars"
    mkdir -p "${ANSIBLE_DIR}/group_vars"
}

dropContainer() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 -d <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi
    
    for node_name in "$@"; do
        if lxc list --format csv | cut -d, -f1 | grep -q "^$node_name$"; then
            echo "Stopping and destroying container $node_name..."
            lxc stop "$node_name" 2>/dev/null || true
            lxc delete "$node_name"
            echo "Container $node_name destroyed successfully."
        else
            echo "Container $node_name does not exist. Skipping destruction."
        fi
    done
}

dropAllContainers() {
    echo "Stopping and destroying all containers..."
    for node_name in $(lxc list --format csv | cut -d, -f1); do
        if [ -n "$node_name" ]; then
            echo "Destroying container $node_name..."
            lxc stop "$node_name" 2>/dev/null || true
            lxc delete "$node_name"
            echo "Container $node_name destroyed successfully."
        fi
    done
    echo "All containers have been destroyed."
}

startContainer() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 -s <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi
    
    for node_name in "$@"; do
        if lxc list --format csv | cut -d, -f1 | grep -q "^$node_name$"; then
            echo "Starting container $node_name..."
            lxc start "$node_name"
            echo "Container $node_name started successfully."
        else
            echo "Container $node_name does not exist. Skipping start."
        fi
    done
}

infoContainer() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 -i <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi
    
    for node_name in "$@"; do
        if lxc list --format csv | cut -d, -f1 | grep -q "^$node_name$"; then
            echo "Container $node_name info:"
            lxc info "$node_name"
            echo "----------------------------------------"
        else
            echo "Container $node_name does not exist. Skipping info."
        fi
    done
}

stopContainer() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 -t <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi
    
    for node_name in "$@"; do
        if lxc list --format csv | cut -d, -f1 | grep -q "^$node_name$"; then
            echo "Stopping container $node_name..."
            lxc stop "$node_name"
            echo "Container $node_name stopped successfully."
        else
            echo "Container $node_name does not exist. Skipping stop."
        fi
    done
}

listContainers() {
    echo "Listing all containers:"
    lxc list
}

# Main option parsing
while getopts ":c:ahitsdDl" options; do
    case "${options}" in 
        a)
            echo "Usage: $0 [OPTIONS] [CONTAINER_NAMES...]"
            echo ""
            echo "Container Management Script using LXD"
            echo ""
            echo "Options:"
            echo "  -c <names...>  Create containers with specified names"
            echo "  -d <names...>  Drop specified containers"
            echo "  -D             Drop all containers"
            echo "  -s <names...>  Start containers"
            echo "  -t <names...>  Stop containers"
            echo "  -i <names...>  Show container info"
            echo "  -l             List all containers"
            echo "  -h             Show detailed help"
            echo "  -a             Show this usage message"
            exit 0
            ;;
        h)
            echo "Container Management Script using LXD"
            echo "======================================"
            echo ""
            echo "This script manages LXD containers with automatic SSH configuration"
            echo "and Ansible inventory generation."
            echo ""
            echo "USAGE:"
            echo "  $0 -c <node_name1> [node_name2] ...    Create containers"
            echo "  $0 -d <node_name1> [node_name2] ...    Delete containers" 
            echo "  $0 -D                                   Delete ALL containers"
            echo "  $0 -s <node_name1> [node_name2] ...    Start containers"
            echo "  $0 -t <node_name1> [node_name2] ...    Stop containers"
            echo "  $0 -i <node_name1> [node_name2] ...    Show container info"
            echo "  $0 -l                                   List all containers"
            echo ""
            echo "EXAMPLES:"
            echo "  $0 -c web1 web2 db1     # Create 3 containers"
            echo "  $0 -s web1              # Start web1 container"
            echo "  $0 -d web1 web2         # Delete web1 and web2"
            echo "  $0 -D                   # Delete all containers"
            echo ""
            echo "REQUIREMENTS:"
            echo "  - LXD must be installed and initialized"
            echo "  - SSH key pair should exist at ~/.ssh/id_rsa.pub"
            echo "  - User must have permission to run lxc commands"
            exit 0
            ;;
        c)
            shift $((OPTIND - 2))
            if [ "$#" -lt 1 ]; then
                echo "Usage: $0 -c <node_name1> <node_name2> ... <node_nameN>"
                exit 1
            fi
            if [ -z "$1" ]; then
                echo "Node name cannot be empty. Please provide valid node names."
                exit 1
            fi
            createContainer "$@"
            exit 0
            ;;
        d)
            shift $((OPTIND - 2))
            dropContainer "$@"
            exit 0
            ;;
        s)
            shift $((OPTIND - 2))
            startContainer "$@"
            exit 0
            ;;
        i)
            shift $((OPTIND - 2))
            infoContainer "$@"
            exit 0
            ;;
        t)
            shift $((OPTIND - 2))
            stopContainer "$@"
            exit 0
            ;;
        D)
            dropAllContainers
            exit 0
            ;;
        l)
            listContainers
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            echo "Use -h for help or -a for usage."
            exit 1
            ;;
    esac
done

# If no options provided, show usage
if [ $# -eq 0 ]; then
    echo "No options provided. Use -a for usage or -h for detailed help."
    exit 1
fi