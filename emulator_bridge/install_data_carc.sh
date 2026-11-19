#!/usr/bin/env bash
#SBATCH --job-name=cobaya-data
#SBATCH --partition=main
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=01:00:00
# Usage (with your Python environment activated):
#   bash emulator_bridge/install_data_carc.sh
# Or: sbatch --account=YOUR_CARC_ACCOUNT emulator_bridge/install_data_carc.sh
set -euo pipefail

# Set these before Python imports NumPy/SciPy. Override inherited thread counts.
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1
export PYTHONUNBUFFERED=1

# Slurm executes a copy in its spool directory, not the original script path.
PROJECT_DIR="${COBAYA_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd -- "$PROJECT_DIR"
PROJECT_DIR="$PWD"
if [[ ! -d "$PROJECT_DIR/emulator_bridge/configs" ]]; then
    echo "Cannot find emulator_bridge/configs in $PROJECT_DIR. Submit from the Cobaya root or set COBAYA_DIR to its absolute path." >&2
    exit 2
fi

if [[ -n "${COBAYA_PYTHON:-}" ]]; then
    ENV_PYTHON="$COBAYA_PYTHON"
elif [[ -n "${VIRTUAL_ENV:-}" ]]; then
    ENV_PYTHON="$VIRTUAL_ENV/bin/python"
elif [[ -n "${CONDA_PREFIX:-}" ]]; then
    ENV_PYTHON="$CONDA_PREFIX/bin/python"
else
    ENV_PYTHON="$(command -v python || true)"
fi
if [[ -z "$ENV_PYTHON" || ! -x "$ENV_PYTHON" ]]; then
    echo "Activate your Cobaya environment first, or set COBAYA_PYTHON to its absolute Python path." >&2
    exit 2
fi

PACKAGES="${COBAYA_PACKAGES_PATH:-$PROJECT_DIR/emulator_bridge/packages}"
mkdir -p -- "$PACKAGES"
echo "Python: $ENV_PYTHON"
echo "Data directory: $PACKAGES"
echo "BLAS/OpenMP threads: 1"

# Repeat this script after an interruption. Cobaya checks installed components.
# This installs likelihood data, not the Python dependencies in requirements.txt.
exec "$ENV_PYTHON" -u -m cobaya install \
    planck_2018_highl_plik.TTTEEE_lite_native \
    planck_2018_lowl.TT \
    planck_2018_lowl.EE_sroll2 \
    act_dr6_cmbonly.ACTDR6CMBonly \
    act_dr6_cmbonly.PlanckActCut \
    -p "$PACKAGES" --no-set-global "$@"
