#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
LOG_DIR="$2"
STAGE="$3"

SBATCH_PARTITION="normal,long"
SBATCH_CPUS_PER_TASK="36"
SBATCH_MEM="90gb"
SBATCH_TIME="7-00:00:00"

source "${TEMPLATE:?}/scripts/wm_helpers.sh"
wm_slurm_submit_stage "$MANIFEST" "$LOG_DIR" "$STAGE"

