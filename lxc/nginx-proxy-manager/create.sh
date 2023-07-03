#!/usr/bin/env bash

set -Eeuo pipefail

trap error ERR
trap 'popd >/dev/null; rm -rf $_temp_dir;' EXIT

function info { echo -e "\e[32m[info] $*\e[39m"; }
function warn { echo -e "\e[33m[warn] $*\e[39m"; }
function error { 
  trap - ERR

  if [ -z "${1-}" ]; then
    echo -e "\e[31m[error] $(caller): ${BASH_COMMAND}\e[39m"
  else
    echo -e "\e[31m[error] $1\e[39m"
  fi

  if [ ! -z ${_ctid-} ]; then
    if $(pct status $_ctid &>/dev/null); then
      if [ "$(pct status $_ctid 2>/dev/null | awk '{print $2}')" == "running" ]; then
        pct stop $_ctid &>/dev/null
      fi
      pct destroy $_ctid &>/dev/null
    elif [ "$(pvesm list $_storage --vmid $_ctid 2>/dev/null | awk 'FNR == 2 {print $2}')" != "" ]; then
      pvesm free $_rootfs &>/dev/null
    fi
  fi

  exit 1
}

# Base raw github URL
_raw_base="https://raw.githubusercontent.com/ImNotNikola/proxmox-scripts/main/lxc/nginx-proxy-manager"
# Operating system
_os_type=debian
_os_version=12.0
# System architecture
_arch=$(dpkg --print-architecture)

# Create temp working directory
_temp_dir=$(mktemp -d)
pushd $_temp_dir >/dev/null

# Parse command line parameters
while [[ $# -gt 0 ]]; do
  arg="$1"

  case $arg in
    --id)
      _ctid=$2
      shift
      ;;
    --bridge)
      _bridge=$2
      shift
      ;;
    --cores)
      _cpu_cores=$2
      shift
      ;;
    --disksize)
      _disk_size=$2
      shift
      ;;
    --hostname)
      _host_name=$2
      shift
      ;;
    --memory)
      _memory=$2
      shift
      ;;
    --storage)
      _storage=$2
      shift
      ;;
    --templates)
      _storage_template=$2
      shift
      ;;
    --swap)
      _swap=$2
      shift
      ;;
    *)
      error "Unrecognized option $1"
      ;;
  esac
  shift
done

# Check user settings or set defaults
_ctid=${_ctid:-`pvesh get /cluster/nextid`}
_cpu_cores=${_cpu_cores:-1}
_disk_size=${_disk_size:-2G}
_host_name=${_host_name:-nginx}
_bridge=${_bridge:-vmbr0}
_memory=${_memory:-512}
_swap=${_swap:-0}
_storage=${_storage:-DiskStore}
_storage_template=${_storage_template:-local}
_template='debian-12-standard_12.0-1_amd64.tar.zst'

# Test if ID is in use
if pct status $_ctid &>/dev/null; then
  warn "ID '$_ctid' is already in use."
  unset _ctid
  error "Cannot use ID that is already in use."
fi

echo ""
warn "Container will be created using the following settings."
warn ""
warn "ctid:     $_ctid"
warn "hostname: $_host_name"
warn "cores:    $_cpu_cores"
warn "memory:   $_memory"
warn "swap:     $_swap"
warn "disksize: $_disk_size"
warn "bridge:   $_bridge"
warn "storage:  $_storage"
warn "templates:  $_storage_template"
warn ""
echo ""

_disk_ref="$_ctid/"
_disk_prefix="subvol"
_disk_format="subvol"
_disk="${_disk_prefix}-${_ctid}-disk-0"
_rootfs=${_storage}:${_disk}

# Create LXC
info "Allocating storage for LXC container..."
pvesm alloc $_storage $_ctid $_disk $_disk_size --format ${_disk_format} &>/dev/null \
  || error "A problem occured while allocating storage."

info "Creating LXC container..."
_pct_options=(
  -arch $_arch
  -cmode shell
  -hostname $_host_name
  -cores $_cpu_cores
  -memory $_memory
  -net0 name=eth0,bridge=$_bridge,ip=dhcp
  -onboot 1
  -ostype $_os_type
  -rootfs $_rootfs,size=$_disk_size
  -storage $_storage
  -swap $_swap
)
pct create $_ctid "/mnt/pve/ISO/template/cache/$_template" ${_pct_options[@]} &>/dev/null \
  || error "A problem occured while creating LXC container."

# Set container timezone to match host
cat << 'EOF' >> /etc/pve/lxc/${_ctid}.conf
lxc.hook.mount: sh -c 'ln -fs $(readlink /etc/localtime) ${LXC_ROOTFS_MOUNT}/etc/localtime'
EOF

# Setup container
info "Setting up LXC container..."
pct start $_ctid
sleep 3
pct exec $_ctid -- sh -c "sysctl -w net.ipv6.conf.all.disable_ipv6=1; sysctl -w net.ipv6.conf.default.disable_ipv6=1"
pct exec $_ctid -- sh -c "wget --no-cache -qO - $_raw_base/setup.sh | sh"
