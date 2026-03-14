#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
LOG_DIR="$2"
STAGE="$3"

SBATCH_PARTITION="gpuh200"
SBATCH_GRES="gpu:1"
SBATCH_CPUS_PER_TASK="16"
SBATCH_MEM="180gb"
SBATCH_TIME="24:00:00"

source "${REPOSITORY_ROOT:?}/.template/scripts/wm_helpers.sh"
wm_slurm_submit_stage "$MANIFEST" "$LOG_DIR" "$STAGE"
