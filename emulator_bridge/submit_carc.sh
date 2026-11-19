#!/usr/bin/env bash
# Usage: bash emulator_bridge/submit_carc.sh [planck|act|act_planck|all] [sbatch options...]
set -euo pipefail
export COBAYA_SAMPLER="${COBAYA_SAMPLER:-polychord}"
export COBAYA_CONDA_ENV="${COBAYA_CONDA_ENV:-nanoGPT}"
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
SAMPLER="${COBAYA_SAMPLER:-polychord}"
case "$SAMPLER" in
    polychord) RUN_SCRIPT=run_polychord_carc.sh ;;
    mcmc) RUN_SCRIPT=run_carc.sh ;;
    *) echo "COBAYA_SAMPLER must be polychord or mcmc" >&2; exit 2 ;;
esac
mkdir -p -- "$COBAYA_DIR/emulator_bridge/logs"
ACCOUNT_OPTIONS=(--export=ALL)
if [[ -n "${SLURM_JOB_ACCOUNT:-}" ]]; then
    ACCOUNT_OPTIONS+=(--account="$SLURM_JOB_ACCOUNT")
fi
for dataset in "${DATASETS[@]}"; do
    echo "Submitting $dataset with $SAMPLER: $COBAYA_DIR/emulator_bridge/configs/${dataset}_${SAMPLER}.yaml"
    JOB_ID="$(sbatch --parsable --chdir="$COBAYA_DIR" \
        --job-name="cobaya-$dataset" \
        --output="$COBAYA_DIR/emulator_bridge/logs/${dataset}-%j.out" \
        "${ACCOUNT_OPTIONS[@]}" "$@" "$COBAYA_DIR/emulator_bridge/$RUN_SCRIPT" "$dataset")"
    echo "$dataset job: $JOB_ID"
done
