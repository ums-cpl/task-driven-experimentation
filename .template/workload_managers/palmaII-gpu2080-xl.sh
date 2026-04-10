#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
LOG_DIR="$2"
STAGE="$3"

SBATCH_PARTITION="gpu2080"
SBATCH_GRES="gpu:1"
SBATCH_CPUS_PER_TASK="4"
SBATCH_MEM="28gb"
SBATCH_TIME="3-00:00:00"

source "${TEMPLATE:?}/scripts/wm_helpers.sh"
wm_slurm_submit_stage "$MANIFEST" "$LOG_DIR" "$STAGE"
