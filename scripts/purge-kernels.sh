#!/bin/bash
#
# purge-kernels.sh - Remove old kernels from a remote node
#
# Usage: ./purge-kernels.sh <node> <kernel-version-prefix>
#
# Example: ./purge-kernels.sh famfs3 6.19
#
# This will remove all kernels matching the version prefix EXCEPT the
# currently running kernel on that node.
#

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <node> <kernel-version-prefix>"
    echo "Example: $0 famfs3 6.19"
    exit 1
fi

NODE="$1"
VERSION="$2"

echo "Connecting to $NODE to purge $VERSION kernels..."

ssh "$NODE" 'RUNNING=$(uname -r)
VERSION="'"$VERSION"'"

echo "Running kernel: $RUNNING"
echo "Purging kernels matching: $VERSION (except running)"
echo ""

# Remove boot files except the running kernel
for f in /boot/vmlinuz-${VERSION}* /boot/initramfs-${VERSION}*; do
    [ -e "$f" ] || continue
    case "$f" in
        *"$RUNNING"*) echo "Keeping $f" ;;
        *) echo "Removing $f"; sudo rm -f "$f" ;;
    esac
done

# Remove module directories except the running kernel
for d in /lib/modules/${VERSION}*; do
    [ -d "$d" ] || continue
    case "$d" in
        *"$RUNNING"*) echo "Keeping $d" ;;
        *) echo "Removing $d"; sudo rm -rf "$d" ;;
    esac
done

echo ""
echo "Remaining $VERSION kernels:"
ls /boot/vmlinuz-${VERSION}* /boot/initramfs-${VERSION}* 2>/dev/null || echo "  (none in /boot)"
ls -d /lib/modules/${VERSION}* 2>/dev/null || echo "  (none in /lib/modules)"
'

echo ""
echo "Done."
