#!/bin/bash
#
# Creates a fresh KVM VM via libvirt. This can be used to create both
# the Crowbar admin node VM and subsequent PXE-booting Crowbar nodes.
#
# FIXME: ideally this would eventually be replaced by one or more
# Vagrantfiles.

DEFAULT_HYPERVISOR="qemu:///system"
DEFAULT_RAMSIZE=2
DEFAULT_FSSIZE=24
DEFAULT_CPUS=4
DEFAULT_USE_CPU_HOST=true
DEFAULT_IMPORT_IMAGE=false
DEFAULT_CACHE_MODE=none

usage () {
    # Call as: usage [EXITCODE] [USAGE MESSAGE]
    exit_code=1
    if [[ "$1" == [0-9] ]]; then
        exit_code="$1"
        shift
    fi
    if [ -n "$1" ]; then
        echo >&2 "$*"
        echo
    fi

    me=`basename $0`

    cat <<EOF >&2
Usage: $me [options] VM-NAME VM-DISK VBRIDGE [FILESYSTEM-PATH]

If VM-DISK does not already exist, it will be created. If you define
and LVM path in a form of /dev/lvgroup/lvname and additional an image
to import it converts the image into the LVM device. The path
/dev/mapper/lvgroup-lvname is only supported if the volume name does
not include dashes.

FILESYSTEM-PATH should be a directory on the host which you want
share to the guest via a 9p virtio passthrough mount.

Options:
  -h, --help             Show this help and exit
  -c, --connect URI      Connect to hypervisor at URI [$DEFAULT_HYPERVISOR]
  -r, --ramsize XX       Size of memory (in GB) [$DEFAULT_RAMSIZE]
  -s, --disksize XX      Size of VM-QCOW2-DISK (in GB) [$DEFAULT_FSSIZE]
  -C, --cpus XX          Number of virtual CPUs to assign [$DEFAULT_CPUS]
  -n, --no-cpu-host      Don´t use the option --cpu host for virt-install [$DEFAULT_USE_CPU_HOST]
  -i, --import IMAGE     An image to import into LVM volume (Only for LVM disks)
  -d, --cache-mode MODE  Cache mode for disk
EOF
    exit "$exit_code"
}

parse_args () {
    hypervisor="$DEFAULT_HYPERVISOR"
    vm_disk_size="${DEFAULT_FSSIZE}G"
    vm_ram_size=$((${DEFAULT_RAMSIZE} * 1024))
    vm_vcpus="$DEFAULT_CPUS"
    cache_mode="$DEFAULT_CACHE_MODE"
    import_image=$DEFAULT_IMPORT_IMAGE
    use_cpu_host=$DEFAULT_USE_CPU_HOST

    while [ $# != 0 ]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -c|--connect)
                hypervisor="$2"
                shift 2
                ;;
            -r|--ramsize)
                vm_ram_size=$((${2} * 1024))
                shift 2
                ;;
            -s|--disksize)
                vm_disk_size="${2}G"
                shift 2
                ;;
            -C|--cpus)
                vm_vcpus="$2"
                shift 2
                ;;
            -d|--cache-mode)
                cache_mode="$2"
                shift 2
                ;;
            -i|--import)
                import_image="$2"
                shift 2
                ;;
            -n|--no-cpu-host)
                use_cpu_host=false
                shift 1
                ;;
            -*)
                usage "Unrecognised option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
        usage
    fi

    vm_name="$1"
    vm_disk="$2"
    vbridge="$3"
    filesystem="$4"
}

die () {
    echo >&2 "$*"
    exit 1
}

run_virsh () {
    LANG=C virsh -c "$hypervisor" "$@"
}

run_sudo () {
    if ! hash sudo 2> /dev/null; then
        echo "Please install sudo to use LVM volumes." >&2
        exit 1
    fi

    LANG=C sudo -i "$@"
}

valid_bridge () {
    local vbridge="$1"
    #/sbin/brctl show | egrep -q "^${vbridge}[[:space:]]"
    for net in $( run_virsh net-list | awk '/active/ {print $1}' ); do
        if run_virsh net-info "$net" | grep -qE "^Bridge:[[:space:]]+$vbridge\$"; then
            echo "Bridge is associated with '$net' network."
            return 0
        fi
    done
    return 1
}

detect_lvm () {
    local path="$1"

    if [[ $path =~ ^/dev/mapper/[[:alnum:]]+ ]]; then
        lvm_combined=${path:12}
        IFS="-"; local -a lvm_values=($lvm_combined)
    elif [[ $path =~ ^/dev/[[:alnum:]]+/[[:alnum:]]+ ]]; then
        lvm_combined=${path:5}
        IFS="/"; local -a lvm_values=($lvm_combined)
    else
        die "Failed to detect LVM group and volume"
    fi

    echo ${lvm_values[0]} ${lvm_values[1]}
}

main () {
    if [ $EUID -eq 0 ]; then
        echo "Maybe the VNC connection can't pop up if you run this as root"
    fi

    parse_args "$@"

    if ! valid_bridge "$vbridge"; then
        usage "$vbridge is not a valid bridge device name"
    fi

    if [[ $vm_disk =~ \qcow2$ ]]; then
        vm_disk_path=$vm_disk,format=qcow2,cache=$cache_mode
    else
        vm_disk_path=$vm_disk,format=raw,cache=$cache_mode
    fi

    if [[ $import_image != false ]]; then
        echo "Importing image from $import_image ..."

        if [[ $import_image =~ ^(http|ftp) ]]; then
            import_name=$(mktemp import-image.XXXXX)

            wget -O ${import_name} ${import_image}
            [[ $? -ne 0 ]] && die "Failed to download import image"
        else
            import_name=$import_image
        fi

        if [[ $vm_disk =~ ^/dev ]]; then
            IFS=" "; declare -a lvm_values=($(detect_lvm $vm_disk))

            vm_lvm_group=${lvm_values[0]}
            vm_lvm_name=${lvm_values[1]}

            echo "Creating LVM volume"
            run_sudo lvcreate -L ${vm_disk_size} -n ${vm_lvm_name} ${vm_lvm_group}
            [[ $? -ne 0 ]] && die "Failed to create LVM volume"

            echo "Converting image to LVM"
            run_sudo qemu-img convert ${import_name} -O host_device ${vm_disk}
            [[ $? -ne 0 ]] && die "Failed to convert image to LVM"
        else
            echo "Moving import image"
            cp ${import_name} ${vm_disk}
            [[ $? -ne 0 ]] && die "Failed to move import image"
        fi
    fi

    if [ -e "$vm_disk" ]; then
        opts=(
            --import
        )
    else
        if [[ $vm_disk =~ ^/dev ]]; then
            echo "Creating $vm_disk with size $vm_disk_size as LVM volume ..."

            IFS=" "; declare -a lvm_values=$(detect_lvm $vm_disk)

            vm_lvm_group=${lvm_values[0]}
            vm_lvm_name=${lvm_values[1]}

            run_sudo lvcreate -L $vm_disk_size -n $vm_lvm_name $vm_lvm_group
            [[ $? -ne 0 ]] && die "Failed to create LVM volume"
        else
            echo "Creating $vm_disk with size $vm_disk_size as qcow2 image ..."

            qemu-img create -f qcow2 "$vm_disk" "$vm_disk_size"
            [[ $? -ne 0 ]] && die "Failed to create qcow2 image"
        fi

        opts=(
            --pxe
            --boot=network,hd,menu=on
        )
    fi

    if [ -n "$filesystem" ]; then
        opts+=(
            --filesystem "$filesystem",install
        )
    fi

    vm_cpu=""
    for plat in amd intel ; do
        if [[ $(grep -i $plat /proc/cpuinfo) ]]; then
            if [ `id -u` == 0 ] ; then
                echo "Running as root, invoking modprobe kvm_$plat."
                if [ $plat = "intel" ] ; then
                    if ! grep -q nested /etc/modprobe.d/99-local.conf ; then
                        echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/99-local.conf
                        modprobe -r kvm_intel
                    fi
                fi

                modprobe kvm_$plat
            fi

            if grep -q kvm_$plat /proc/modules && egrep -q "[Y1]" /sys/module/kvm_$plat/parameters/nested && $use_cpu_host; then
                vm_cpu="--cpu=host"
                echo "Host CPU ($plat) supports nested virtualization and kvm_$plat module is loaded with nested=1, adding $vm_cpu"
            fi
        fi
    done

    virt-install \
        --debug \
        --connect "${hypervisor}" \
        --virt-type kvm \
        --name "${vm_name}" \
        --ram "${vm_ram_size}" \
        --vcpus "${vm_vcpus}" \
        "${vm_cpu}" \
        --os-type linux \
        --os-variant sles11 \
        --graphics vnc \
        --network bridge="${vbridge}" \
        --disk path="${vm_disk_path}" \
        "${opts[@]}"
}

main "$@"
