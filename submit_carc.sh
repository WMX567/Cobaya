#!/usr/bin/env bash
#SBATCH --job-name=cobaya-submit
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:05:00
# Submit from the repository root: sbatch submit_carc.sh all
# This short launcher submits three independent 10-hour sampling jobs.
set -euo pipefail
PROJECT_DIR="${COBAYA_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
export COBAYA_DIR="$PROJECT_DIR"
export COBAYA_SAMPLER=polychord
export COBAYA_CONDA_ENV="${COBAYA_CONDA_ENV:-nanoGPT}"
if (( $# == 0 )); then set -- all; fi
exec bash "$PROJECT_DIR/emulator_bridge/submit_carc.sh" "$@"
