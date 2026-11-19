# Emulator → Cobaya → Planck / ACT

Run parameter inference with trained segmented emulator models and Planck / ACT
likelihoods. Run all commands from this repository root.

## Setup

To create a separate environment with matching compilers and serial PolyChord:

```bash
bash emulator_bridge/create_env_carc.sh
# After setup, select the new environment before submitting jobs:
unset LD_PRELOAD
conda activate cobaya-emulator
export COBAYA_CONDA_ENV=cobaya-emulator
export COBAYA_PYTHON="$CONDA_PREFIX/bin/python"
```

## Submit on CARC

```bash
# Run from the repository root. Submits all three datasets with PolyChord.
sbatch emulator_bridge/submit_carc.sh all
# If CARC requires an explicit allocation account:
# sbatch --account=YOUR_CARC_ACCOUNT emulator_bridge/submit_carc.sh all
```
- Logs: `emulator_bridge/logs/<dataset>-<jobid>.out`
- Results: `emulator_bridge/chains/<dataset>_polychord*`
