#!/bin/bash

TARGET_HOST="$1"
CORE_CONF="/etc/systemd/coredump.conf.d/famfs.conf"

# Create the config directory on the remote host
ssh root@"${TARGET_HOST}" "mkdir -p $(dirname "$CORE_CONF")"

# Send the config file via SSH and write it atomically
ssh root@"${TARGET_HOST}" "cat > \"$CORE_CONF\"" <<'EOF'
# /etc/systemd/coredump.conf.d/famfs.conf

[Coredump]
# Store cores in the external journal directory (/var/lib/systemd/coredump/)
Storage=external

# Save core dumps for processes up to 32 GiB in size
ProcessSizeMax=32G

# Compress core dumps to save space (xz, zstd, or none)
Compress=yes

# Save cores even for setuid/setgid binaries (optional; be cautious with sensitive binaries)
SetuidSafe=yes

# Keep core dumps for 3 days
MaxUse=1G
KeepFree=500M
EOF

# Reload systemd to apply the new config
ssh root@"${TARGET_HOST}" "systemctl daemon-reexec"
