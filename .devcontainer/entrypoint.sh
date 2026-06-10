#!/usr/bin/env bash
# =============================================================================
# Fast DDS Dev Container - Entrypoint
# -----------------------------------------------------------------------------
# Runs at every container start (NOT at image build).
# Fixes ownership of Docker named volumes so the non-root dev user can write.
#
# Why this exists:
#   Docker named volumes are created at container-start time and are owned by
#   root:root by default. Any chown done inside the Dockerfile only affects the
#   image layer, which gets shadowed by the volume mount. So we must chown at
#   runtime instead.
#
# This script is configured as the image ENTRYPOINT.
# =============================================================================

set -e

USER_NAME="${USER_NAME:-dev}"
USER_UID="$(id -u "${USER_NAME}" 2>/dev/null || echo 1001)"
USER_GID="$(id -g "${USER_NAME}" 2>/dev/null || echo 1001)"

# Directories that should be owned by the dev user.
# These are typical mount points for our docker-compose named volumes.
FIX_DIRS=(
    "/workspace/ws"
    "/home/${USER_NAME}/.ccache"
    "/home/${USER_NAME}/.history"
)

for d in "${FIX_DIRS[@]}"; do
    if [ -d "$d" ]; then
        current_owner="$(stat -c '%u:%g' "$d")"
        wanted_owner="${USER_UID}:${USER_GID}"
        if [ "$current_owner" != "$wanted_owner" ]; then
            echo "[entrypoint] chown $d ($current_owner -> $wanted_owner)"
            # We are running as the dev user; use the passwordless sudo
            # configured in the Dockerfile.
            sudo chown -R "$wanted_owner" "$d" || \
                echo "[entrypoint] WARN: chown $d failed" >&2
        fi
    fi
done

# Hand off to the CMD (or whatever args were passed to the container).
exec "$@"
