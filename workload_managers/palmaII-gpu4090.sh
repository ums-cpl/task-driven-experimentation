#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
LOG_DIR="$2"
STAGE="$3"

SBATCH_PARTITION="gpu4090"
SBATCH_GRES="gpu:1"
SBATCH_CPUS_PER_TASK="5"
SBATCH_MEM="56gb"
SBATCH_TIME="2:00:00"

source "${REPOSITORY_ROOT:?}/.template/scripts/wm_helpers.sh"
wm_slurm_submit_stage "$MANIFEST" "$LOG_DIR" "$STAGE"

