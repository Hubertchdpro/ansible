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
        # if container exist, don"t create anymore
        if sudo lxc-ls --fancy | awk '{print $1}' | grep -q "^$node_name$"; then
            echo "Info: Container $node_name already exists. Skipping creation."
        else
            # Create container
            echo "Creating container $node_name..."
            if ! sudo lxc-create -n "$node_name" -t download -- --dist ubuntu --release jammy --arch amd64; then
                echo "Error: Failed to create node $node_name. Please check your inputs and try again."
                exit 1
            fi
            echo "Success: Node $node_name created successfully."
            echo "Node $node_name is starting. Please wait..."
            sudo lxc-start -n "$node_name"
            sleep 5  # Wait for a few seconds to allow the node to start
        fi

        # # Configure container
        sudo sudo lxc-attach -n "$node_name" -- apt install -y openssh-server
        sudo sudo lxc-attach -n "$node_name" -- mkdir -m 0700 ${CONTAINER_HOME}/.ssh && chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh
        # cat ${HOME}/.ssh/id_rsa.pub | sudo lxc-attach -n "$node_name" -- sh -c "cat >> ${CONTAINER_HOME}/.ssh/authorized_keys"

        # Keys Adding
        KEY_CONTENT=$(sudo cat ${CONTAINER_HOME}/.ssh/id_rsa.pub)
        if [ -z "$KEY_CONTENT" ]; then
            echo "Public key not found. Please generate an SSH key pair first."
            exit 1
        fi
        # Add public key to container's authorized_keys
        echo "Adding public key to container $node_name..."
        sudo lxc-attach -n "$node_name" -- sh -c "echo '$KEY_CONTENT' > ${CONTAINER_HOME}/.ssh/authorized_keys"
        # Ensure the .ssh directory and authorized_keys file have the correct permissions
        sudo lxc-attach -n "$node_name" -- chmod 700 ${CONTAINER_HOME}/.ssh
        sudo lxc-attach -n "$node_name" -- chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh
        # Append the public key to authorized_keys
        sudo lxc-attach -n "$node_name" -- sh -c "echo '$KEY_CONTENT' >> ${CONTAINER_HOME}/.ssh/authorized_keys"
        # Ensure the authorized_keys file has the correct permissions
        sudo lxc-attach -n "$node_name" -- chmod 600 ${CONTAINER_HOME}/.ssh/authorized_keys
        sudo lxc-attach -n "$node_name" -- chown ${CONTAINER_USER}:${CONTAINER_USER} ${CONTAINER_HOME}/.ssh/authorized_keys
        # edit sshd_config to allow public key authentication
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'PermitRootLogin no' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'AllowUsers ${CONTAINER_USER}' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'X11Forwarding yes' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'UsePAM yes' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- sh -c "echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> /etc/ssh/sshd_config"
        sudo lxc-attach -n "$node_name" -- systemctl enable ssh
        sudo lxc-attach -n "$node_name" -- systemctl start ssh
        # User to be able to use sudo without password
        sudo lxc-attach -n "$node_name" -- mkdir -p /etc/sudoers.d
        sudo lxc-attach -n "$node_name" -- sh -c "echo '${CONTAINER_USER} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${CONTAINER_USER}"
        sudo lxc-attach -n "$node_name" -- chmod 440 /etc/sudoers.d/${CONTAINER_USER}
        echo "Container $node_name created and configured successfully."
    done

    # Create Ansible inventory
    if [ ! -d ${ANSIBLE_DIR} ]; then
        mkdir -p ${ANSIBLE_DIR}
    else
        rm -rf ${ANSIBLE_DIR}/*
    fi
    echo "containers:" > ${ANSIBLE_DIR}/inventory.yml
    echo "  vars:" >> ${ANSIBLE_DIR}/inventory.yml
    echo "  hosts:" >> ${ANSIBLE_DIR}/inventory.yml
    sudo lxc-ls --fancy | grep "[0-9].[0-9].[0-9].[0-9]" | awk '{print "    "$1 ":\n      ansible_host: " $5}' >> ${ANSIBLE_DIR}/inventory.yml
    mkdir -p ${ANSIBLE_DIR}/host_vars
    mkdir -p ${ANSIBLE_DIR}/group_vars
}


dropContainer() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi
    for node_name in "$@"
    do
        if sudo lxc-info -n "$node_name" &>/dev/null; then
            echo "Stopping and destroying container $node_name..."
            sudo lxc-stop -n "$node_name"
            sudo lxc-destroy -n "$node_name"
            echo "Container $node_name destroyed successfully."
        else
            echo "Container $node_name does not exist. Skipping destruction."
        fi
    done
}

dropAllContainers() {
    echo "Stopping and destroying all containers..."
    for node_name in $(sudo lxc-ls --fancy | awk '{print $1}' | grep -v NAME); do
        sudo lxc-stop -n "$node_name"
        sudo lxc-destroy -n "$node_name"
        echo "Container $node_name destroyed successfully."
    done
    echo "All containers have been destroyed."
}

startContainer() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 -s <node_name1> <node_name2> ... <node_nameN>"
        exit 1
    fi
    for node_name in "$@"; do
        if sudo lxc-info -n "$node_name" &>/dev/null; then
            echo "Starting container $node_name..."
            sudo lxc-start -n "$node_name"
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
        if sudo lxc-info -n "$node_name" &>/dev/null; then
            echo "Container $node_name info:"
            sudo lxc-info -n "$node_name"
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
        if sudo lxc-info -n "$node_name" &>/dev/null; then
            echo "Stopping container $node_name..."
            sudo lxc-stop -n "$node_name"
            echo "Container $node_name stopped successfully."
        else
            echo "Container $node_name does not exist. Skipping stop."
        fi
    done
}

while getopts ":c:ahitsdD" options; do
  case "${options}" in 
    a)
      echo "Usage: $0 -c <node_name1> <node_name2> ... <node_nameN> | -d <node_name1> <node_name2> ... <node_nameN> | -D"
      exit 0
      ;;
    h)
      echo "Usage: $0 -c <node_name1> <node_name2> ... <node_nameN> | -d <node_name1> <node_name2> ... <node_nameN> | -D"
      echo "Options:"
      echo "  -c <node_name1> <node_name2> ... <node_nameN>  Create containers with specified names"
      echo "  -d <node_name1> <node_name2> ... <node_nameN>  Drop specified containers"
      echo "  -D                                             Drop all containers"
      echo "  -a                                             Show this help message"
      echo "  -s                                             Start container"
      echo "  -i                                             Info container"
      echo "  -t                                             Stop container"
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
    #   shift $((OPTIND - 1))
      dropContainer "$@"
      exit 0
      ;;
    s)
    #   shift $((OPTIND - 1))
      startContainer "$@"
      exit 0
      ;;
    i)
    #   shift $((OPTIND - 1))   
      infoContainer "$@"
      exit 0
      ;;
    t)
    #   shift $((OPTIND - 1))   
      stopContainer "$@"
      exit 0
      ;;
    D)
      dropAllContainers
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG"
      exit 1
      ;;
  esac
done
