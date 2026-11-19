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
# Builds without MPI for the single-process sampling workflow. Load GCC if needed.
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
    # Ignore inherited MPI compiler wrappers: this workflow uses one process.
    export CC="${POLYCHORD_CC:-gcc}"
    export CXX="${POLYCHORD_CXX:-g++}"
    export FC="${POLYCHORD_FC:-gfortran}"
    export COBAYA_NOMPI=1
    for compiler in make "$CC" "$CXX" "$FC"; do
        if ! command -v "$compiler"; then
            echo "Missing $compiler. Load a GCC module, then retry (module avail gcc)." >&2
            return 2
        fi
    done
    echo "Building serial PolyChord: CC=$CC CXX=$CXX FC=$FC"
    "$ENV_PYTHON" -u - "$PACKAGES" <<'PYBUILD'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from cobaya.install import download_github_release
from cobaya.log import logger_setup
from cobaya.samplers.polychord import polychord

logger_setup()
packages = Path(sys.argv[1]).resolve()
source = Path(polychord.get_path(str(packages)))
# Match the release required by this checkout and avoid reusing MPI build objects.
if not download_github_release(str(packages / "code"),
                               polychord._pc_repo_name, polychord._pc_repo_version):
    raise SystemExit("PolyChord download failed")
env = dict(os.environ, PWD=str(source))
# PolyChord detects GNU compilers by looking for the unprefixed gfortran name.
# Conda's actual compiler names may be x86_64-conda-linux-gnu-*.
with tempfile.TemporaryDirectory(prefix="polychord-compilers-") as wrappers:
    for alias, variable in (("gcc", "CC"), ("g++", "CXX"), ("gfortran", "FC")):
        compiler = shutil.which(env[variable])
        if compiler is None:
            raise SystemExit(f"Compiler not found: {env[variable]}")
        env[variable] = str(Path(compiler).absolute())
        # Use a shell wrapper so GCC still locates its own toolchain correctly.
        import shlex
        wrapper = Path(wrappers) / alias
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(env[variable]) + ' "$@"\n')
        wrapper.chmod(0o755)
    env["PATH"] = wrappers + os.pathsep + env["PATH"]
    subprocess.check_call([sys.executable, "setup.py", "--no-mpi", "clean", "--all"],
                          cwd=source, env=env)
    subprocess.check_call([sys.executable, "setup.py", "--no-mpi", "build"],
                          cwd=source, env=env)
PYBUILD
    local build_status=$?
    if [[ "$build_status" != 0 ]]; then return "$build_status"; fi
    "$ENV_PYTHON" -u -m cobaya install polychord \
        -p "$PACKAGES" --no-set-global --test || return "$?"
    echo "Serial PolyChord installation verified. No OpenMPI runtime is required."

}

install_polychord 2>&1 | tee "$LOG"
