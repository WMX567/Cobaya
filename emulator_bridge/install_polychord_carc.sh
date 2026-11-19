#!/usr/bin/env bash
#SBATCH --job-name=cobaya-install-polychord
#SBATCH --partition=main
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=01:00:00
# Usage from the repository root:
#   bash emulator_bridge/install_polychord_carc.sh
#   sbatch --account=YOUR_ACCOUNT emulator_bridge/install_polychord_carc.sh
# Load your compatible compiler/MPI modules before submitting, if needed.
set -eo pipefail

PROJECT_DIR="${COBAYA_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [[ -d "$PROJECT_DIR/configs" && -f "$PROJECT_DIR/../cobaya/__init__.py" ]]; then
    PROJECT_DIR="$(cd -- "$PROJECT_DIR/.." && pwd)"
fi
cd -- "$PROJECT_DIR"
PROJECT_DIR="$PWD"
if [[ ! -f "$PROJECT_DIR/cobaya/samplers/polychord/polychord.py" ]]; then
    echo "Cannot find Cobaya in $PROJECT_DIR. Set COBAYA_DIR to the repository root." >&2
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
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1
export PYTHONUNBUFFERED=1

PACKAGES="${COBAYA_PACKAGES_PATH:-$PROJECT_DIR/emulator_bridge/packages}"
mkdir -p -- "$PACKAGES" "$PROJECT_DIR/emulator_bridge/logs"
LOG="$PROJECT_DIR/emulator_bridge/logs/install_polychord-${SLURM_JOB_ID:-$(date +%Y%m%d-%H%M%S)}.log"

install_polychord() {
    echo "Python: $ENV_PYTHON"
    "$ENV_PYTHON" --version
    echo "Packages: $PACKAGES"
    echo "Log: $LOG"
    # Conda/modules may export FC=gfortran. MPI builds require wrappers instead.
    export CC="${POLYCHORD_CC:-mpicc}"
    export CXX="${POLYCHORD_CXX:-mpicxx}"
    if [[ -n "${POLYCHORD_FC:-}" ]]; then
        export FC="$POLYCHORD_FC"
    elif command -v mpif90 >/dev/null 2>&1; then
        export FC=mpif90
    else
        export FC=mpifort
    fi
    for compiler in make "$CC" "$CXX" "$FC"; do
        if ! command -v "$compiler"; then
            echo "Missing $compiler. Load compatible compiler and MPI modules, then retry." >&2
            echo "Discover available modules with: module avail gcc; module avail openmpi" >&2
            return 2
        fi
    done
    echo "Build compilers: CC=$CC CXX=$CXX FC=$FC"
    # Compile and link without launching an MPI process on the login node.
    local probe_dir
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/polychord-mpi.XXXXXX")" || return 2
    cat > "$probe_dir/check.f90" <<'EOF'
program check_mpi
  implicit none
  include 'mpif.h'
  integer ierr
  call MPI_Init(ierr)
  call MPI_Finalize(ierr)
end program check_mpi
EOF
    if ! "$FC" "$probe_dir/check.f90" -o "$probe_dir/check_mpi"; then
        echo "MPI Fortran compile/link check failed. Load compatible GCC and MPI modules, then retry." >&2
        return 2
    fi
    "$ENV_PYTHON" -u -m cobaya install polychord \
        -p "$PACKAGES" --no-set-global "$@" || return "$?"
    "$ENV_PYTHON" -u -m cobaya install polychord \
        -p "$PACKAGES" --no-set-global --test || return "$?"
    echo "PolyChord installation verified. Use the same compiler/MPI modules for sampling jobs."
}

install_polychord "$@" 2>&1 | tee "$LOG"
