#!/usr/bin/env bash
set -e

echo "=== Starting Mikrotik RouterOS Container ==="
echo "Host Architecture: $(uname -m)"

# ======================
# MAC ADDRESS GENERATION
# ======================
generate_mac_address() {
    # Generate random MAC address dengan prefix Mikrotik (54:05:AB)
    # atau gunakan custom prefix dari env
    local prefix="${MAC_PREFIX:-54:05:AB}"
    
    # Generate random 3 octets terakhir
    local octet4=$(printf '%02x' $((RANDOM % 256)))
    local octet5=$(printf '%02x' $((RANDOM % 256)))
    local octet6=$(printf '%02x' $((RANDOM % 256)))
    
    echo "${prefix}:${octet4}:${octet5}:${octet6}" | tr '[:lower:]' '[:upper:]'
}

# Get MAC address dari env atau generate random
if [[ -n "${MAC_ADDRESS:-}" ]]; then
    # Validasi format MAC address
    if [[ "$MAC_ADDRESS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        QEMU_MAC="$MAC_ADDRESS"
        echo "Using custom MAC address from env: $QEMU_MAC"
    else
        echo "⚠️ Invalid MAC address format: $MAC_ADDRESS"
        echo "Generating random MAC address instead..."
        QEMU_MAC=$(generate_mac_address)
    fi
else
    QEMU_MAC=$(generate_mac_address)
    echo "Generated random MAC address: $QEMU_MAC"
fi

# Export untuk digunakan di script lain jika perlu
export QEMU_MAC

# ======================
# PATHS CONFIGURATION
# ======================
ROUTEROS_SOURCE="/routeros_source"
ROUTEROS_WORKDIR="/routeros"

# Copy semua file dari source ke workdir pada first run
if [[ ! -f "${ROUTEROS_WORKDIR}/chr.vdi" ]]; then
    echo "Copying RouterOS files to working directory..."
    cp -r "${ROUTEROS_SOURCE}/." "${ROUTEROS_WORKDIR}/"
    
    # Fix permissions
    echo "Setting execute permissions..."
    find "${ROUTEROS_WORKDIR}" -type f \( -name "*.sh" -o -name "*.py" -o -name "qemu-*" \) \
        -exec chmod +x {} \; 2>/dev/null || true
fi

cd "${ROUTEROS_WORKDIR}"

# ======================
# VALIDATION
# ======================
if [[ ! -f "chr.vdi" ]]; then
    echo "ERROR: RouterOS VDI file not found!"
    ls -la
    exit 1
fi

# Cek /dev/net/tun device
if [[ ! -c /dev/net/tun ]]; then
    echo "ERROR: /dev/net/tun device not found!"
    echo "Add to docker run: --device /dev/net/tun"
    echo "Or in docker-compose: devices: - /dev/net/tun"
    exit 1
fi

echo "TUN device available: /dev/net/tun"

# ======================
# BRIDGE & DHCP NETWORK SETUP
# ======================
QEMU_BRIDGE_ETH1='qemubr1'
default_dev1='eth0'  # Default container interface
DUMMY_DHCPD_IP='10.0.0.1'
DHCPD_CONF_FILE='dhcpd.conf'
DHCPD_LEASES_FILE='/var/lib/udhcpd/udhcpd.leases'

function prepare_intf() {
   echo "Preparing interface $1 for bridge $2"
   
   # First we clear out the IP address and route
   ip addr flush dev $1 2>/dev/null || true
   
   # Next, we create our bridge, and add our container interface to it.
   # Delete existing bridge if exists
   ip link delete $2 2>/dev/null || true
   
   # Create bridge
   ip link add name $2 type bridge
   
   # Add container interface to bridge
   ip link set dev $1 master $2
   
   # Then, we toggle the interface and the bridge to make sure everything is up
   # and running.
   ip link set dev $1 up
   ip link set dev $2 up
   
   # Give bridge an IP for DHCP server
   ip addr add ${DUMMY_DHCPD_IP}/24 dev $2
   
   echo "Bridge $2 created with $DUMMY_DHCPD_IP/24"
}

# Generate DHCPD config file
echo "Setting up DHCP server..."

# Create directory for DHCP leases
mkdir -p /var/lib/udhcpd
touch "$DHCPD_LEASES_FILE"
chmod 644 "$DHCPD_LEASES_FILE"

# Generate DHCPD config
if [[ -f "generate-dhcpd-conf.py" ]] && [[ -x "generate-dhcpd-conf.py" ]]; then
    echo "Generating DHCP configuration..."
    python3 generate-dhcpd-conf.py $QEMU_BRIDGE_ETH1 > $DHCPD_CONF_FILE
    echo "DHCP config generated: $DHCPD_CONF_FILE"
else
    echo "WARNING: generate-dhcpd-conf.py not found or not executable"
    # Create minimal DHCP config
    cat > $DHCPD_CONF_FILE <<EOF
start     10.0.0.10
end       10.0.0.250
interface $QEMU_BRIDGE_ETH1
max_leases 240
option subnet 255.255.255.0
option router 10.0.0.1
option dns 8.8.8.8 8.8.4.4
option lease 864000
EOF
    echo "Created default DHCP config"
fi

# Fix max_leases value if too high
sed -i 's/max_leases[[:space:]]*[0-9]*/max_leases 100/' $DHCPD_CONF_FILE

echo "DHCP configuration:"
cat $DHCPD_CONF_FILE

# Setup bridge
prepare_intf $default_dev1 $QEMU_BRIDGE_ETH1

# Start DHCPD server if available
if command -v udhcpd &> /dev/null; then
    echo "Starting DHCP server..."
    
    # Check if udhcpd can read config
    if udhcpd -f -I $DUMMY_DHCPD_IP $DHCPD_CONF_FILE --no-pid; then
        echo "✅ DHCP server test successful"
        # Start in background
        udhcpd -I $DUMMY_DHCPD_IP -f $DHCPD_CONF_FILE &
        echo "✅ DHCP server started"
    else
        echo "⚠️ DHCP server test failed, continuing without DHCP"
    fi
else
    echo "⚠️ udhcpd not found, DHCP server disabled"
fi


# ======================
# QEMU CONFIGURATION
# ======================
ARCH=$(uname -m)
QEMU_CMD="qemu-system-x86_64"
KVM_AVAILABLE="no"

echo "Host Architecture: $ARCH"

# Cek KVM hanya jika arsitektur x86_64
if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    if [[ -e /dev/kvm ]] && grep -q -E "(vmx|svm)" /proc/cpuinfo; then
        KVM_AVAILABLE="yes"
        echo "✓ KVM acceleration available"
    fi
fi

# ======================
# NETWORKING - TAP/BRIDGE MODE
# ======================
echo "Configuring TAP bridge networking..."

# Cari network scripts
QEMU_IFUP=""
QEMU_IFDOWN=""

for script in qemu-ifup qemu-ifup*; do
    if [[ -f "$script" ]] && [[ -x "$script" ]]; then
        QEMU_IFUP="$script"
        break
    fi
done

for script in qemu-ifdown qemu-ifdown*; do
    if [[ -f "$script" ]] && [[ -x "$script" ]]; then
        QEMU_IFDOWN="$script"
        break
    fi
done

# Validasi scripts
if [[ -z "$QEMU_IFUP" ]]; then
    echo "ERROR: qemu-ifup script not found!"
    ls qemu-* 2>/dev/null || echo "None found"
    exit 1
fi

if [[ -z "$QEMU_IFDOWN" ]]; then
    echo "ERROR: qemu-ifdown script not found!"
    ls qemu-* 2>/dev/null || echo "None found"
    exit 1
fi

echo "Using TAP bridge scripts:"
echo "  UP: $QEMU_IFUP"
echo "  DOWN: $QEMU_IFDOWN"

# Networking option
NETWORK_OPTION="-nic tap,id=qemu1,mac=$QEMU_MAC,script=$QEMU_IFUP,downscript=$QEMU_IFDOWN"

# ======================
# QEMU PARAMETERS
# ======================
QEMU_PARAMS=()

# Basic parameters
QEMU_PARAMS+=(-serial mon:stdio)
QEMU_PARAMS+=(-nographic)
QEMU_PARAMS+=(-m 256)
QEMU_PARAMS+=(-smp "2,sockets=1,cores=2,threads=1")

# Machine and CPU
if [[ "$KVM_AVAILABLE" == "yes" ]]; then
    QEMU_PARAMS+=(-machine "pc,accel=kvm")
    QEMU_PARAMS+=(-cpu "host")
else
    QEMU_PARAMS+=(-machine "pc,accel=tcg")
    QEMU_PARAMS+=(-cpu "qemu64,+ssse3,+sse4.1,+sse4.2")
    [[ "$ARCH" != "x86_64" ]] && echo "⚠️  Running in emulation mode (slow on ARM)"
fi

# Networking - SELALU TAP
QEMU_PARAMS+=($NETWORK_OPTION)

# Disk
QEMU_PARAMS+=(-hda "chr.vdi")

# VNC jika di-enable via env
if [[ "${ENABLE_VNC:-}" == "true" ]] || [[ "${ENABLE_VNC:-}" == "1" ]]; then
    QEMU_PARAMS+=(-vnc "0.0.0.0:0,password=on")
    echo "VNC enabled on port 5900"
fi

# Additional arguments
if [[ $# -gt 0 ]]; then
    echo "Additional arguments: $*"
    QEMU_PARAMS+=("$@")
fi

# ======================
# START ROUTEROS
# ======================
echo "=== Starting RouterOS with TAP Networking ==="
echo "Command: $QEMU_CMD"
for param in "${QEMU_PARAMS[@]}"; do
    echo "  $param"
done

exec $QEMU_CMD "${QEMU_PARAMS[@]}"
