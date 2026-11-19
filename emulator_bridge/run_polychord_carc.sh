#!/usr/bin/env bash
#SBATCH --job-name=cobaya-polychord
#SBATCH --partition=main
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=10:00:00
#SBATCH --open-mode=append
set -eo pipefail
PROJECT_DIR="${COBAYA_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# Accept submission from either the repository root or emulator_bridge.
if [[ -d "$PROJECT_DIR/configs" && -f "$PROJECT_DIR/../cobaya/__init__.py" ]]; then
    PROJECT_DIR="$(cd -- "$PROJECT_DIR/.." && pwd)"
fi
cd -- "$PROJECT_DIR"
if [[ "${SLURM_NTASKS:-1}" != 1 ]]; then
    echo "This script requires --ntasks=1." >&2
    exit 2
fi
if [[ -n "${COBAYA_PYTHON:-}" ]]; then
    ENV_PYTHON="$COBAYA_PYTHON"
else
    source "${CONDA_SH:-$(conda info --base)/etc/profile.d/conda.sh}"
    conda activate "${COBAYA_CONDA_ENV:-nanogpt}"
    ENV_PYTHON="$CONDA_PREFIX/bin/python"
fi
set -u
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-4}"
export MKL_NUM_THREADS="$OMP_NUM_THREADS"
export OPENBLAS_NUM_THREADS="$OMP_NUM_THREADS"
export NUMEXPR_NUM_THREADS="$OMP_NUM_THREADS"
export COBAYA_NOMPI=1
export PYTHONUNBUFFERED=1
export PYTHONFAULTHANDLER=1
# PolyChord uses native resume files, not the MCMC checkpoint/signal callback.
# Resubmit the same command after a timeout to resume from saved state.
exec "$ENV_PYTHON" -u -m emulator_bridge.polychord_runner "${1:-planck}"
