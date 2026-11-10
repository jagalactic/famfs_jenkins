#!/usr/bin/env bash
#
# update-kernel-mirror.sh - refresh the local bare kernel mirror that
# ndctl_regression_public hardlink-clones from (run_qemu_fixture's kernelMirror).
# The mirror lives on the run_qemu agent (thing1), so the git ops run there over
# ssh - this stays a controller-side unit like the other timers. Idempotent;
# meant for a daily systemd timer (see systemd/kernel-mirror-update.*).
#
# The mirror was created with `git clone --mirror` (remote.origin.mirror=true),
# so `git remote update --prune` syncs ALL refs to upstream and prunes deleted
# ones. Add upstream remotes to the mirror itself to widen coverage; this script
# refreshes whatever remotes it has. Refreshes the commit-graph afterward so the
# per-build local clones/fetches of this large tree stay fast.
#
# Usage:  scripts/update-kernel-mirror.sh
# Env:    MIRROR (default /home/jenkins/git/linux-mirror.git)
#         MIRROR_HOST (default thing1)
set -euo pipefail
MIRROR="${MIRROR:-/home/jenkins/git/linux-mirror.git}"
HOST="${MIRROR_HOST:-thing1}"

echo "[$(date '+%F %T')] refreshing ${HOST}:${MIRROR}"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
    "set -e
     git -C '$MIRROR' rev-parse --is-bare-repository >/dev/null
     git -C '$MIRROR' remote update --prune
     git -C '$MIRROR' commit-graph write --reachable
     printf 'tags now: %s\n' \"\$(git -C '$MIRROR' for-each-ref refs/tags | wc -l)\""
echo "[$(date '+%F %T')] mirror refresh done"
