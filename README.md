# Run on CARC

Run all commands from `/scratch1/mengxiwu/Cobaya`.

## 1. Install the environment once

```bash
cd /scratch1/mengxiwu/Cobaya
bash emulator_bridge/create_env_carc.sh
```

If setup is interrupted, rerun with `--resume`.

## 2. Activate the environment and set paths

Run this in each new submission terminal:

```bash
unset LD_PRELOAD
conda activate cobaya-emulator
export COBAYA_CONDA_ENV=cobaya-emulator
export COBAYA_PYTHON="$CONDA_PREFIX/bin/python"
export COBAYA_SAMPLER=polychord

# Replace with the directory containing your TT, EE, TE, and PhiPhi folders.
export COBAYA_MODELS=/absolute/path/to/models
```

Each spectrum folder must contain `0_3000/best.pt`, `3000_6000/best.pt`, and
`6000_9000/best.pt`. Keep the Emulator project at `../Emulator`, or set
`EMULATOR_DIR` to its absolute path.

## 3. Install likelihood data once

```bash
bash emulator_bridge/install_data_carc.sh
```

## 4. Submit all three datasets

```bash
sbatch emulator_bridge/submit_carc.sh all
# If an allocation account is required:
# sbatch --account=YOUR_ACCOUNT emulator_bridge/submit_carc.sh all
```

This submits Planck, ACT, and ACT + Planck as separate PolyChord jobs, each with
a **10-hour limit**. To run one dataset, replace `all` with `planck`, `act`, or
`act_planck`.

Edit sampler settings in `emulator_bridge/configs/<dataset>_polychord.yaml`.

## 5. Check results or resume

```bash
squeue --me
ls -lt emulator_bridge/logs/
tail -f emulator_bridge/logs/planck-JOBID.out
```

Results are saved under `emulator_bridge/chains/<dataset>_polychord*`.
After a timeout, resubmit the same command to resume from saved state. Do not
change the model files, priors, or output prefix when resuming, or submit a
duplicate job while the original is still running.
