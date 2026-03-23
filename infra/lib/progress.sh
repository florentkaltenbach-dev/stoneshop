#!/usr/bin/env bash
# Dockbase deploy state tracking — mode-prefixed phases
# Usage: source "$(dirname "$0")/lib/progress.sh"
#
# State entries are formatted as "mode:phase" (e.g., "full:harden").
# This ensures mode switches correctly re-run shared phases.

# STATE_FILE must be set before sourcing (set by common.sh or deploy.sh)
: "${STATE_FILE:?STATE_FILE must be set before sourcing progress.sh}"

# DEPLOY_MODE must be set before calling phase_done/mark_done
: "${DEPLOY_MODE:=full}"

phase_done() {
    grep -qx "${DEPLOY_MODE}:$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    echo "${DEPLOY_MODE}:$1" >> "$STATE_FILE"
    echo ""
    echo "  >>> checkpoint: ${DEPLOY_MODE}:$1 done <<<"
    echo ""
}

last_checkpoint() {
    if [ -f "$STATE_FILE" ]; then
        tail -1 "$STATE_FILE"
    else
        echo "(none)"
    fi
}

reset_all() {
    rm -f "$STATE_FILE"
    echo "Deploy state cleared."
}

reset_mode() {
    local mode="$1"
    if [ ! -f "$STATE_FILE" ]; then
        echo "No state file to reset."
        return 0
    fi
    local before after
    before=$(wc -l < "$STATE_FILE")
    sed -i "/^${mode}:/d" "$STATE_FILE"
    after=$(wc -l < "$STATE_FILE")
    echo "Cleared $((before - after)) entries for mode '${mode}'."
}
