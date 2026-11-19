#!/usr/bin/env bash
# Usage: bash emulator_bridge/submit_carc.sh [planck|act|act_planck|all] [sbatch options...]
set -euo pipefail
# This helper may itself be submitted with sbatch, which copies it to spool.
PROJECT_DIR="${COBAYA_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export COBAYA_DIR="$PROJECT_DIR"
COBAYA_DIR="$(cd -- "$COBAYA_DIR" && pwd)"
if [[ ! -f "$COBAYA_DIR/emulator_bridge/run_carc.sh" ]]; then
    echo "Cannot find emulator_bridge/run_carc.sh in $COBAYA_DIR. Submit from the Cobaya root or set COBAYA_DIR to its absolute path." >&2
    exit 2
fi
DATASET="${1:-planck}"
if (( $# )); then shift; fi
case "$DATASET" in
    planck|act|act_planck) DATASETS=("$DATASET") ;;
    all) DATASETS=(planck act act_planck) ;;
    *) echo "Usage: bash emulator_bridge/submit_carc.sh [planck|act|act_planck|all] [sbatch options...]" >&2; exit 2 ;;
esac
mkdir -p -- "$COBAYA_DIR/emulator_bridge/logs"
for dataset in "${DATASETS[@]}"; do
    JOB_ID="$(sbatch --parsable --export=ALL --chdir="$COBAYA_DIR" \
        --job-name="cobaya-$dataset" \
        --output="$COBAYA_DIR/emulator_bridge/logs/${dataset}-%j.out" \
        "$@" "$COBAYA_DIR/emulator_bridge/run_carc.sh" "$dataset")"
    echo "$dataset job: $JOB_ID"
done
