#!/bin/bash
set -euo pipefail

# =============================
# Multi-VM Manager (clean)
# =============================

display_header() {
    clear
    cat << "EOF"
========================================
       Multi-VM Manager - Console UI
========================================
EOF
    echo
}

# colored output
print_status() {
    local type=$1
    local message=$2

    case $type in
        "INFO") echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

validate_input() {
    local type=$1
    local value=$2

    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "Name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore and contain only letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing_deps=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Debian/Ubuntu: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

cleanup() {
    rm -f "user-data" "meta-data" 2>/dev/null || true
}

get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        # shellcheck disable=SC1090
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Configuration saved to $config_file"
}

setup_vm_image() {
    print_status "INFO" "Preparing image..."
    mkdir -p "$VM_DIR"
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image exists, skipping download."
    else
        print_status "INFO" "Downloading: $IMG_URL"
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Download failed: $IMG_URL"
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi

    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Could not resize in place; recreating image as needed..."
        # try to create a new blank image (if base backing not supported)
        if qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
            print_status "INFO" "Created new qcow2 image: $IMG_FILE"
        else
            print_status "WARN" "Could not create resized image; continuing with existing file."
        fi
    fi

    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi

    print_status "SUCCESS" "Prepared VM image and seed for '$VM_NAME'."
}

create_new_vm() {
    print_status "INFO" "Creating a new VM"

    print_status "INFO" "Select an OS:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done

    while true; do
        read -p "$(print_status "INPUT" "Choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection"
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Password (default hidden): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then break; else print_status "ERROR" "Password cannot be empty"; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT in use"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI? (y/n, default: n): ")" gui_input
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true; break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then GUI_MODE=false; break
        else print_status "ERROR" "Answer y or n"; fi
    done

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80), Enter for none: ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image
    save_vm_config
}

start_vm() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Starting VM: $vm_name"
        print_status "INFO" "Connect: ssh -p $SSH_PORT $USERNAME@localhost"

        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "Image not found: $IMG_FILE"
            return 1
        fi

        if [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Seed file missing, recreating..."
            setup_vm_image
        fi

        local qemu_cmd=(
            qemu-system-x86_64
            -enable-kvm
            -m "$MEMORY"
            -smp "$CPUS"
            -cpu host
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        )

        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                qemu_cmd+=(-netdev "user,id=net${host_port},hostfwd=tcp::$host_port-:$guest_port")
                qemu_cmd+=(-device virtio-net-pci,netdev=net${host_port})
            done
        fi

        if [[ "$GUI_MODE" == true ]]; then
            qemu_cmd+=(-vga virtio -display gtk,gl=on)
        else
            qemu_cmd+=(-nographic -serial mon:stdio)
        fi

        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        print_status "INFO" "Launching QEMU..."
        "${qemu_cmd[@]}"
        print_status "INFO" "VM $vm_name stopped"
    fi
}

delete_vm() {
    local vm_name=$1
    print_status "WARN" "This will delete VM '$vm_name' and its data"
    read -p "$(print_status "INPUT" "Confirm? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
            print_status "SUCCESS" "Deleted '$vm_name'"
        fi
    else
        print_status "INFO" "Cancelled"
    fi
}

show_vm_info() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "VM: $vm_name"
        echo "=========================================="
        echo "OS: $OS_TYPE"
        echo "Hostname: $HOSTNAME"
        echo "Username: $USERNAME"
        echo "SSH Port: $SSH_PORT"
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "GUI Mode: $GUI_MODE"
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        echo "Created: $CREATED"
        echo "Image: $IMG_FILE"
        echo "Seed: $SEED_FILE"
        echo "=========================================="
        echo
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

is_vm_running() {
    local vm_name=$1
    if pgrep -f "qemu-system-x86_64.*$IMG_FILE" >/dev/null; then return 0; else return 1; fi
}

stop_vm() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Stopping VM: $vm_name"
            pkill -f "qemu-system-x86_64.*$IMG_FILE" || true
            sleep 2
            if is_vm_running "$vm_name"; then
                print_status "WARN" "Forcing termination..."
                pkill -9 -f "qemu-system-x86_64.*$IMG_FILE" || true
            fi
            print_status "SUCCESS" "Stopped $vm_name"
        else
            print_status "INFO" "VM not running"
        fi
    fi
}

edit_vm_config() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Editing $vm_name"
        while true; do
            echo "1) Hostname  2) Username  3) Password  4) SSH Port"
            echo "5) GUI Mode  6) Port Forwards  7) Memory  8) CPUs  9) Disk"
            echo "0) Back"
            read -p "$(print_status "INPUT" "Choice: ")" edit_choice
            case $edit_choice in
                1)
                    read -p "$(print_status "INPUT" "New hostname (current: $HOSTNAME): ")" new_hostname
                    new_hostname="${new_hostname:-$HOSTNAME}"
                    if validate_input "name" "$new_hostname"; then HOSTNAME="$new_hostname"; fi
                    ;;
                2)
                    read -p "$(print_status "INPUT" "New username (current: $USERNAME): ")" new_username
                    new_username="${new_username:-$USERNAME}"
                    if validate_input "username" "$new_username"; then USERNAME="$new_username"; fi
                    ;;
                3)
                    read -s -p "$(print_status "INPUT" "New password: ")" new_password
                    echo
                    if [ -n "$new_password" ]; then PASSWORD="$new_password"; fi
                    ;;
                4)
                    read -p "$(print_status "INPUT" "New SSH port (current: $SSH_PORT): ")" new_ssh_port
                    new_ssh_port="${new_ssh_port:-$SSH_PORT}"
                    if validate_input "port" "$new_ssh_port"; then
                        if [ "$new_ssh_port" != "$SSH_PORT" ] && ss -tln 2>/dev/null | grep -q ":$new_ssh_port "; then
                            print_status "ERROR" "Port in use"
                        else
                            SSH_PORT="$new_ssh_port"
                        fi
                    fi
                    ;;
                5)
                    read -p "$(print_status "INPUT" "Enable GUI? (y/n): ")" gui_input
                    if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true
                    elif [[ "$gui_input" =~ ^[Nn]$ ]]; then GUI_MODE=false; fi
                    ;;
                6)
                    read -p "$(print_status "INPUT" "Port forwards (current: ${PORT_FORWARDS:-None}): ")" new_pf
                    PORT_FORWARDS="${new_pf:-$PORT_FORWARDS}"
                    ;;
                7)
                    read -p "$(print_status "INPUT" "Memory MB (current: $MEMORY): ")" new_memory
                    new_memory="${new_memory:-$MEMORY}"
                    if validate_input "number" "$new_memory"; then MEMORY="$new_memory"; fi
                    ;;
                8)
                    read -p "$(print_status "INPUT" "CPUs (current: $CPUS): ")" new_cpus
                    new_cpus="${new_cpus:-$CPUS}"
                    if validate_input "number" "$new_cpus"; then CPUS="$new_cpus"; fi
                    ;;
                9)
                    read -p "$(print_status "INPUT" "Disk size (current: $DISK_SIZE): ")" new_disk_size
                    new_disk_size="${new_disk_size:-$DISK_SIZE}"
                    if validate_input "size" "$new_disk_size"; then
                        DISK_SIZE="$new_disk_size"
                    fi
                    ;;
                0) return 0 ;;
                *) print_status "ERROR" "Invalid";;
            esac

            if [[ "$edit_choice" =~ ^[123]$ ]]; then
                print_status "INFO" "Updating cloud-init seed..."
                setup_vm_image
            fi
            save_vm_config
            read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" cont
            if [[ ! "$cont" =~ ^[Yy]$ ]]; then break; fi
        done
    fi
}

resize_vm_disk() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Current disk: $DISK_SIZE"
        while true; do
            read -p "$(print_status "INPUT" "New disk size (e.g., 50G): ")" new_disk_size
            if validate_input "size" "$new_disk_size"; then
                if [[ "$new_disk_size" == "$DISK_SIZE" ]]; then
                    print_status "INFO" "No change"
                    return 0
                fi
                # convert units roughly for comparison
                local curr=${DISK_SIZE%[GgMm]}
                local new=${new_disk_size%[GgMm]}
                local curr_unit=${DISK_SIZE: -1}
                local new_unit=${new_disk_size: -1}
                if [[ "$curr_unit" =~ [Gg] ]]; then curr=$((curr * 1024)); fi
                if [[ "$new_unit" =~ [Gg] ]]; then new=$((new * 1024)); fi
                if [[ $new -lt $curr ]]; then
                    print_status "WARN" "Shrinking may cause data loss"
                    read -p "$(print_status "INPUT" "Proceed? (y/N): ")" confirm_shrink
                    if [[ ! "$confirm_shrink" =~ ^[Yy]$ ]]; then print_status "INFO" "Cancelled"; return 0; fi
                fi
                if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
                    DISK_SIZE="$new_disk_size"
                    save_vm_config
                    print_status "SUCCESS" "Resized to $new_disk_size"
                else
                    print_status "ERROR" "Resize failed"
                    return 1
                fi
                break
            fi
        done
    fi
}

show_vm_performance() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Performance for $vm_name"
            echo "=========================================="
            local qemu_pid
            qemu_pid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE" || true)
            if [[ -n "$qemu_pid" ]]; then
                ps -p "$qemu_pid" -o pid,%cpu,%mem,sz,rss,vsz,cmd --no-headers
                echo
                free -h
                echo
                df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
            else
                print_status "ERROR" "QEMU process not found"
            fi
        else
            print_status "INFO" "VM not running. Configuration:"
            echo "  Memory: $MEMORY MB"
            echo "  CPUs: $CPUS"
            echo "  Disk: $DISK_SIZE"
        fi
        echo "=========================================="
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

main_menu() {
    while true; do
        display_header
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if is_vm_running "${vms[$i]}"; then status="Running"; fi
                printf "  %2d) %s (%s)\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
        fi
        echo "  0) Exit"
        echo

        read -p "$(print_status "INPUT" "Enter your choice: ")" choice

        case $choice in
            1) create_new_vm ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to start: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to stop: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show info: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to edit: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to delete: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to resize disk: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show performance: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            0)
                print_status "INFO" "Exiting"
                exit 0
                ;;
            *)
                print_status "ERROR" "Invalid option"
                ;;
        esac

        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

trap cleanup EXIT

check_dependencies

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|vm-ubuntu-22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|vm-ubuntu-24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|vm-debian-11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|vm-debian-12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|vm-fedora-40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|vm-centos-9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|vm-alma-9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|vm-rocky-9|rocky|rocky"
)

main_menu
