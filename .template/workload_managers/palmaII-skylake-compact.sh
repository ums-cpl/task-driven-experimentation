#!/usr/bin/env bash
set -euo pipefail

MANIFEST="$1"
LOG_DIR="$2"
STAGE="$3"

SBATCH_PARTITION="express,normal,long"
SBATCH_CPUS_PER_TASK="4"
SBATCH_MEM="10gb"
SBATCH_TIME="2:00:00"

source "${REPOSITORY_ROOT:?}/.template/scripts/wm_helpers.sh"
wm_slurm_submit_stage "$MANIFEST" "$LOG_DIR" "$STAGE"

