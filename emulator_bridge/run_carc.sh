#!/usr/bin/env bash
#SBATCH --job-name=cobaya-emulator
#SBATCH --partition=main
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=16:00:00
#SBATCH --signal=B:USR1@180
#SBATCH --requeue
#SBATCH --open-mode=append
# Submit via submit_carc.sh so log directories exist before Slurm opens them.
set -eo pipefail

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
DATASET="${1:-planck}"
case "$DATASET" in planck|act|act_planck) ;; *) echo "Expected planck, act, or act_planck" >&2; exit 2 ;; esac
if [[ "${SLURM_NTASKS:-1}" != 1 ]]; then
    echo "This script runs one chain per job; keep --ntasks=1." >&2
    exit 2
fi

if [[ -n "${COBAYA_PYTHON:-}" ]]; then
    ENV_PYTHON="$COBAYA_PYTHON"
else
    # As in Emulator/train_emulators.sh, conda must be available in the job.
    # Optionally set CONDA_SH if your CARC login setup does not expose conda.
    source "${CONDA_SH:-$(conda info --base)/etc/profile.d/conda.sh}"
    conda activate "${COBAYA_CONDA_ENV:-nanogpt}"
    ENV_PYTHON="$CONDA_PREFIX/bin/python"
fi
set -u
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-4}"
export MKL_NUM_THREADS="$OMP_NUM_THREADS"
export OPENBLAS_NUM_THREADS="$OMP_NUM_THREADS"
export NUMEXPR_NUM_THREADS="$OMP_NUM_THREADS"
export PYTHONUNBUFFERED=1
export PYTHONFAULTHANDLER=1

CONFIG="$PROJECT_DIR/emulator_bridge/configs/${DATASET}_mcmc.yaml"
TAG="${COBAYA_RUN_TAG:-}"
if [[ -n "$TAG" && ! "$TAG" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "COBAYA_RUN_TAG may contain only letters, digits, underscores and hyphens." >&2
    exit 2
fi
PREFIX="${COBAYA_CHAINS_DIR:-$PROJECT_DIR/emulator_bridge/chains}/${DATASET}_mcmc${TAG:+_$TAG}"
PACKAGES="${COBAYA_PACKAGES_PATH:-$PROJECT_DIR/emulator_bridge/packages}"
mkdir -p -- "$(dirname -- "$PREFIX")"
[[ -f "$CONFIG" ]] || { echo "Missing config: $CONFIG" >&2; exit 2; }
COMMAND=("$ENV_PYTHON" -u -m emulator_bridge.carc_runner "$CONFIG"
    --output "$PREFIX" --packages-path "$PACKAGES"
    --models-path "${COBAYA_MODELS:-$PROJECT_DIR/emulator_bridge/models}"
    --emulator-path "${EMULATOR_DIR:-$PROJECT_DIR/../Emulator}")
if [[ -n "${COBAYA_SEED:-}" ]]; then COMMAND+=(--seed "$COBAYA_SEED"); fi

STOP_NOTICE=0
RUN_PID=""
on_notice() {
    STOP_NOTICE=1
    echo "$(date -u): time-limit notice; requesting checkpoint."
    if [[ -n "$RUN_PID" ]]; then kill -USR1 "$RUN_PID" 2>/dev/null || true; fi
}
on_cancel() {
    trap - TERM INT
    echo "Job cancelled/terminated; leaving existing files available for manual resume."
    if [[ -n "$RUN_PID" ]]; then
        kill -TERM "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
    fi
    exit 143
}
trap on_notice USR1
trap on_cancel TERM INT
echo "Dataset: $DATASET; output: $PREFIX; Python: $ENV_PYTHON"
echo "Job: ${SLURM_JOB_ID:-local}; restart: ${SLURM_RESTART_COUNT:-0}"
"${COMMAND[@]}" &
RUN_PID=$!
# wait can return early when the shell receives USR1; keep waiting for the child.
set +e
wait "$RUN_PID"
STATUS=$?
if [[ "$STOP_NOTICE" == 1 ]]; then
    # Leave roughly a minute before Slurm's hard limit for requeue operations.
    GRACE="${COBAYA_STOP_GRACE_SECONDS:-110}"
    for ((elapsed=0; elapsed<GRACE; elapsed++)); do
        kill -0 "$RUN_PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$RUN_PID" 2>/dev/null; then
        echo "Grace period exhausted; retaining the last persisted checkpoint."
        kill -TERM "$RUN_PID" 2>/dev/null
        sleep 2
        kill -KILL "$RUN_PID" 2>/dev/null
    fi
    wait "$RUN_PID"
    STATUS=$?
fi
set -e

if [[ "$STOP_NOTICE" == 1 && ( "$STATUS" == 75 || "$STATUS" == 143 || "$STATUS" == 137 ) ]]; then
    if [[ "${COBAYA_AUTO_REQUEUE:-1}" == 1 && -n "${SLURM_JOB_ID:-}" ]]; then
        if (( ${SLURM_RESTART_COUNT:-0} >= ${COBAYA_MAX_REQUEUES:-20} )); then
            echo "Requeue limit reached. Resubmit the same command to resume." >&2
            exit 75
        fi
        if [[ ! -s "$PREFIX.checkpoint" ]]; then
            echo "No persisted checkpoint; refusing automatic requeue." >&2
            exit 75
        fi
        echo "Requeuing $SLURM_JOB_ID; the next allocation will resume $PREFIX."
        if scontrol requeue "$SLURM_JOB_ID"; then exit 0; fi
        echo "Requeue was rejected. Resubmit the same submission command to resume." >&2
    fi
    exit 75
fi
# Errors are not automatically requeued; successful convergence exits normally.
exit "$STATUS"
