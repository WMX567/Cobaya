#!/usr/bin/env bash
#SBATCH --job-name=cobaya-create-env
#SBATCH --partition=main
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=10:00:00
# Usage: bash emulator_bridge/create_env_carc.sh [--resume]
# Or: sbatch --account=YOUR_ACCOUNT emulator_bridge/create_env_carc.sh
set -eo pipefail

# Clear the previous runtime workaround in this script's process only.
unset LD_PRELOAD PYTHONHOME PYTHONPATH LD_LIBRARY_PATH
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1 PYTHONUNBUFFERED=1 COBAYA_NOMPI=1

PROJECT_DIR="${COBAYA_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [[ -d "$PROJECT_DIR/configs" && -f "$PROJECT_DIR/../cobaya/__init__.py" ]]; then
    PROJECT_DIR="$(cd -- "$PROJECT_DIR/.." && pwd)"
fi
cd -- "$PROJECT_DIR"
export COBAYA_DIR="$PWD"
if [[ ! -f emulator_bridge/requirements.txt ]]; then
    echo "Set COBAYA_DIR to the Cobaya repository root." >&2
    exit 2
fi
ENV_NAME="${COBAYA_NEW_ENV:-cobaya-emulator}"
if [[ ! "$ENV_NAME" =~ ^[a-zA-Z0-9_-]+$ || "$ENV_NAME" == base || "$ENV_NAME" == nanogpt ]]; then
    echo "Choose a new environment name with COBAYA_NEW_ENV (not base or nanogpt)." >&2
    exit 2
fi
RESUME=0
case "${1:-}" in
    '') ;;
    --resume) RESUME=1 ;;
    *) echo "Usage: bash emulator_bridge/create_env_carc.sh [--resume]" >&2; exit 2 ;;
esac
if (( $# > 1 )); then echo "Too many arguments" >&2; exit 2; fi

mkdir -p emulator_bridge/logs
LOG="$COBAYA_DIR/emulator_bridge/logs/create_env-${SLURM_JOB_ID:-$(date +%Y%m%d-%H%M%S)}.log"
setup_environment() {
echo "Environment: $ENV_NAME; log: $LOG"
CONDA_BASE="$(conda info --base)"
source "${CONDA_SH:-$CONDA_BASE/etc/profile.d/conda.sh}"
# Avoid inheriting the old environment's compiler activation variables.
while [[ "${CONDA_SHLVL:-0}" -gt 0 ]]; do conda deactivate; done
unset CC CXX FC F77 F90 CFLAGS CXXFLAGS FFLAGS LDFLAGS

if conda env list --json | "$CONDA_BASE/bin/python" -c \
    'import json, pathlib, sys; sys.exit(0 if any(pathlib.Path(p).name == sys.argv[1] for p in json.load(sys.stdin)["envs"]) else 1)' "$ENV_NAME"; then
    if [[ "$RESUME" != 1 ]]; then
        echo "Environment already exists. To continue this setup, rerun with --resume." >&2
        exit 2
    fi
else
    conda create -y --name "$ENV_NAME" --override-channels -c conda-forge \
        python=3.10 pip setuptools wheel 'numpy<2' scipy \
        c-compiler cxx-compiler fortran-compiler make git
fi

conda activate "$ENV_NAME"
export COBAYA_CONDA_ENV="$ENV_NAME"
export COBAYA_PYTHON="$CONDA_PREFIX/bin/python"
export POLYCHORD_CC="${CC:?Conda C compiler activation failed}"
export POLYCHORD_CXX="${CXX:?Conda C++ compiler activation failed}"
export POLYCHORD_FC="${FC:?Conda Fortran compiler activation failed}"
set -u
"$COBAYA_PYTHON" -c 'import sys, datetime, _datetime, numpy; print(sys.executable); print("NumPy:", numpy.__version__)'
# CPU inference only: avoid downloading CUDA libraries.
"$COBAYA_PYTHON" -m pip install 'torch>=2.6' --index-url https://download.pytorch.org/whl/cpu
echo "Installing all project requirements with $COBAYA_PYTHON"
"$COBAYA_PYTHON" -m pip install -r "$COBAYA_DIR/emulator_bridge/requirements.txt"
"$COBAYA_PYTHON" -m pip check
"$COBAYA_PYTHON" -c 'import yaml, numpy, scipy, pandas, getdist, portalocker, torch, act_dr6_cmbonly, cobaya; print("Project dependency imports verified")'
bash emulator_bridge/install_polychord_carc.sh

echo "Setup complete. Existing models and likelihood data have not been changed."
echo "If likelihood data are missing, run the data installer with this environment."
echo "In your submission terminal, run:"
echo "  unset LD_PRELOAD"
echo "  conda activate $ENV_NAME"
echo "  export COBAYA_CONDA_ENV=$ENV_NAME"
echo '  export COBAYA_PYTHON="$CONDA_PREFIX/bin/python"'
echo "  sbatch emulator_bridge/submit_carc.sh all"

}

setup_environment 2>&1 | tee "$LOG"
