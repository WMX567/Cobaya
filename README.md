# Emulator → Cobaya → Planck / ACT

These files connect the segmented models trained with
`../Emulator/cosmopower_pt/segmented.py` to Cobaya for parameter inference using
real Planck and ACT data. Run all commands below from the **Cobaya repository
root**. The original Emulator folder and Cobaya core code have not been modified.

## Environment and data

Use your existing `nanoGPT` conda environment (Python 3.10+). Conda environment
names are case-sensitive; use the exact name shown by `conda env list`.

```bash
conda activate nanoGPT
python --version
python -m pip install -r emulator_bridge/requirements.txt
bash emulator_bridge/install_data_carc.sh
```

### Connect your existing model weights

You already have the trained model weights. Copy the extracted checkpoints into
`emulator_bridge/models/`, preserving this layout:

```text
emulator_bridge/models/
  TT/{0_3000,3000_6000,6000_9000}/best.pt
  EE/{0_3000,3000_6000,6000_9000}/best.pt
  TE/{0_3000,3000_6000,6000_9000}/best.pt
  PhiPhi/{0_3000,3000_6000,6000_9000}/best.pt
```

Each brace expression above represents three separate directories, for a total
of 12 checkpoints. If the weights are still in `TT.zip`, `EE.zip`, `TE.zip`, and
`PhiPhi.zip`, extract them with:

```bash
python -m emulator_bridge.prepare_models --zip-dir /absolute/path/to/model_archives
```

For CARC jobs, you can leave the extracted weights in their existing location:

```bash
export COBAYA_MODELS=/absolute/path/to/models
```

This directory must contain the `TT`, `EE`, `TE`, and `PhiPhi` subdirectories.
`COBAYA_MODELS` is read by the CARC runner. When running the YAML configurations
directly with `python -m cobaya run`, set
`theory.emulator_bridge.theory.SegmentedEmulator.models_path` in the YAML instead,
or use the default `emulator_bridge/models/` location.

The data installer sets BLAS/OpenMP thread counts to one before importing Python
libraries, preventing OpenBLAS from trying to start 64 threads on a shared login
node. It uses the activated virtualenv or conda environment. You can also select
an interpreter explicitly or submit installation as a Slurm job:

```bash
# Run after activating nanoGPT; pin the interpreter for the batch job.
export COBAYA_PYTHON="$(python -c 'import sys; print(sys.executable)')"
export COBAYA_DIR=/scratch1/mengxiwu/Cobaya
bash emulator_bridge/install_data_carc.sh
# Alternatively, submit a one-core installation job:
sbatch --account=YOUR_CARC_ACCOUNT emulator_bridge/install_data_carc.sh
```

Batch scripts locate the project using `COBAYA_DIR` first, then
`SLURM_SUBMIT_DIR`, then the original script location for direct shell execution.
Submit from the Cobaya repository root, or set `COBAYA_DIR` explicitly as above.
Slurm runs a script copy under `/var/spool/slurm`; this is not the project path.

The selected node needs network access to the data servers. Repeat the same
command if installation is interrupted; Cobaya checks components already installed.
The installer only downloads likelihood data. Install `emulator_bridge/requirements.txt` first
if the Python likelihood packages are missing.

Models, likelihood data, and chain files are excluded from Git and must be
provided separately on each machine. Historical validation used
`/private/tmp/cobaya-emulator-venv/bin/python`; that temporary environment is no
longer present in the inspected local checkout.

### Current checkout status (2026-11-18)

The source code, analysis configurations, `pyproject.toml`, `README.rst`, and
`LICENCE.txt` are present. The model weights are available separately, but the
default `emulator_bridge/models/` directory is not populated in this checkout.
The default likelihood data directory, `emulator_bridge/packages/`, is also absent.

The last local check used `/opt/anaconda3/bin/python`, not the `nanoGPT`
environment. That interpreter lacked `getdist`, `portalocker`, `torch`, and
`act_dr6_cmbonly`; the Planck evaluation stopped at `ModuleNotFoundError: No module
named 'getdist'`. This does not establish which packages are installed in
`nanoGPT`. Activate that environment and verify it before starting a chain:

```bash
conda activate nanoGPT
python -c 'import sys; print(sys.executable); import getdist, portalocker, torch, act_dr6_cmbonly'
python -m pip check
python -m pytest -q emulator_bridge/test_bridge.py emulator_bridge/test_carc.py
python -m cobaya run emulator_bridge/configs/planck_evaluate.yaml
```

Run the evaluation after connecting the weights and installing the likelihood
data. Tests that require real checkpoints or ACT data can skip when those assets
are missing, so passing tests alone do not establish readiness for inference.

## Running on CARC with timeout recovery

Keep `cobaya/` and `Emulator/` next to each other on CARC, or set `EMULATOR_DIR` to
the Emulator project directory. Transfer `emulator_bridge/models/` and
`emulator_bridge/packages/` as well: these directories are excluded from Git.
Alternatively, extract the ZIP archives and install the likelihood data on the
cluster using the setup commands above. Install Python dependencies in your CARC
environment once before submitting jobs.

The scripts follow the conda setup used by the Emulator training jobs and default
to the `nanogpt` environment in the script. Set `COBAYA_CONDA_ENV=nanoGPT` to use
your environment's exact name. From the Cobaya repository root on CARC:

```bash
export COBAYA_CONDA_ENV=nanoGPT

# Replace YOUR_CARC_ACCOUNT with your actual Slurm allocation account.
bash emulator_bridge/submit_carc.sh planck --account=YOUR_CARC_ACCOUNT

# Submit ACT or the joint analysis separately.
bash emulator_bridge/submit_carc.sh act --account=YOUR_CARC_ACCOUNT
bash emulator_bridge/submit_carc.sh act_planck --account=YOUR_CARC_ACCOUNT

# Or submit all three as independent jobs.
bash emulator_bridge/submit_carc.sh all --account=YOUR_CARC_ACCOUNT
```

Default resources are partition `main`, one node, one task, four CPU cores,
16 GB RAM, and 24 hours. No GPU or MPI is needed. Override resources through the
submission command, for example `--partition=main --time=48:00:00 --mem=32G`,
subject to your allocation's limits. Use the submission helper so the log
directory exists before Slurm opens the output file. Logs are appended to
`emulator_bridge/logs/<dataset>-<jobid>.out`; chains retain a stable output prefix
under `emulator_bridge/chains/`.

Slurm sends the batch shell `USR1` approximately 180 seconds before the time
limit. The shell forwards this notice to `carc_runner.py`. At the next accepted
sample after burn-in, the runner flushes samples, saves a checkpoint, and exits
with status 75. The job then requests `scontrol requeue`; on the next allocation,
the same output prefix is automatically resumed. A normal completion does not
requeue. Ordinary Python errors and manual cancellation do not trigger automatic
requeue either.

If the runner cannot reach a safe sampling point within 110 seconds, the shell
stops it and attempts to requeue from the last persisted checkpoint. A hard kill,
node failure, or missed advance signal can lose samples that have not yet been
written. Incomplete burn-in may have to repeat. Requeue permission depends on
cluster policy: `--requeue` alone does not guarantee that a job will be rescheduled
after a hard timeout. If automatic requeue is rejected or the job has already
timed out, **resubmit the same command with the same environment variables and
output prefix** to resume manually. Do not change parameters, priors, or model
files during a resumed analysis.

Useful environment variables:

| Variable | Default / purpose |
| --- | --- |
| `COBAYA_CONDA_ENV` | `nanogpt`; conda environment name or path |
| `CONDA_SH` | Optional absolute path to conda's `etc/profile.d/conda.sh` |
| `COBAYA_PYTHON` | Absolute Python executable; skips conda activation when set |
| `COBAYA_DIR` | Cobaya repository root, inferred from the scripts |
| `EMULATOR_DIR` | Sibling `../Emulator` directory |
| `COBAYA_MODELS` | `emulator_bridge/models` under the Cobaya root |
| `COBAYA_PACKAGES_PATH` | `emulator_bridge/packages` under the Cobaya root |
| `COBAYA_CHAINS_DIR` | `emulator_bridge/chains` under the Cobaya root |
| `COBAYA_RUN_TAG` | Optional output suffix for a separate independent run |
| `COBAYA_SEED` | Optional sampler seed override; keep it stable when resuming |
| `COBAYA_AUTO_REQUEUE` | `1`; set to `0` for manual resubmission only |
| `COBAYA_MAX_REQUEUES` | `20`; maximum automatic restarts per Slurm job |

Each job runs **one chain**. To run another independent chain, set a different
`COBAYA_RUN_TAG` and `COBAYA_SEED` before submitting it. Never submit concurrent
jobs with the same dataset and output prefix. These scripts explicitly disable
MPI and reject `--ntasks` values other than one; the separate MPI workflow below
applies to running Cobaya directly.

```bash
export COBAYA_RUN_TAG=chain2
export COBAYA_SEED=43
bash emulator_bridge/submit_carc.sh planck --account=YOUR_CARC_ACCOUNT

squeue --me
tail -f emulator_bridge/logs/planck-JOBID.out
# Cancel a job without automatically requeuing it:
scancel JOBID
```

Scheduler references: [CARC running jobs](https://www.carc.usc.edu/user-guides/hpc-systems/using-our-hpc-systems/running-jobs),
[Slurm advance signals](https://slurm.schedmd.com/sbatch.html), and
[Slurm requeue](https://slurm.schedmd.com/scontrol.html).

## Three analyses

| Configuration prefix | Data |
| --- | --- |
| `planck` | Planck 2018 Plik-lite TT/TE/EE + low-ell TT + SRoll2 EE |
| `act` | ACT DR6 CMB-only TT/TE/EE, without Planck low-ell data |
| `act_planck` | ACT DR6 + the official PlanckActCut high-ell cuts + Planck low-ell TT/EE |

Each analysis includes three stages. For example:

```bash
# Evaluate at params.*.ref to check the interface and likelihood values.
python -m cobaya run emulator_bridge/configs/planck_evaluate.yaml
# Local posterior optimization with at most 500 evaluations.
# This does not establish a global optimum or posterior convergence.
python -m cobaya run emulator_bridge/configs/planck_minimize.yaml
# Sample parameters until the configured convergence criteria are satisfied.
python -m cobaya run emulator_bridge/configs/planck_mcmc.yaml

python -m cobaya run emulator_bridge/configs/act_mcmc.yaml
python -m cobaya run emulator_bridge/configs/act_planck_mcmc.yaml
```

Outputs are saved in `emulator_bridge/chains/`. If output files already exist, use Cobaya's
`--resume` option or change the output prefix. Multiple chains can run on a
cluster using MPI, for example `mpirun -n 4 python -m cobaya run ...`; install MPI
and mpi4py in the corresponding environment first. For interacting-neutrino
models, also start chains from different `log10_G_eff_nu` values and check mode
coverage, R−1, and effective sample sizes. A single local optimization is
insufficient for these checks.

The nine cosmological parameter names and their order come from the checkpoints.
Prior ranges come from `../CosmoCLASS/lhs_sampling.py`. `N_ur` is the massless
neutrino contribution, not the total `N_eff`, and
`ln_A_s_1e10 = ln(10^10 A_s)`. The models assume the other CLASS settings used
during training and do not support arbitrary extensions to the cosmological
model. Calibration parameters are sampled. Run `make_configs.py` to regenerate
the configurations; regeneration overwrites the YAML files.

## Compare emulator likelihood errors against CLASS spectra

Use a `classpt_sinu_test_XXXXX_cmb.npz` file generated by CosmoCLASS as the reference.
It contains `ell, tt, ee, te, pp, meta_json`. When `--predictions` is omitted, the
program extracts the parameter point from the reference file's metadata and runs
the emulator at that same point:

```bash
python -m emulator_bridge.compare \
  --truth /path/to/classpt_sinu_test_00000_cmb.npz \
  --config emulator_bridge/configs/planck_compare.yaml \
  --output emulator_bridge/comparison_planck.json
```

Use `act_compare.yaml` or `act_planck_compare.yaml` for the corresponding checks.
Add `--predictions /path/to/predicted.npz` to read previously computed predictions.
For two-dimensional spectrum arrays, use `--sample N` to select the matching test
row. If metadata are unavailable, supply the nine parameters using
`--parameters params.json`.

All inputs must be **raw, dimensionless, lensed CLASS C_l spectra**, rather than
D_l, spectra in μK², or log spectra. The ell grid must be contiguous and start at
0 or 2. The interface pads ell=0,1, converts TT/TE/EE to the temperature units
required by Cobaya, preserves the dimensionless pp convention, and applies the
appropriate ell factors.

With identical data and calibration values, the report gives
`delta_logL = logL(emulator) - logL(CLASS)` and `delta_chi2 = -2 delta_logL`.
This difference can be negative; it is not the positive-definite chi-square of
the spectrum residuals. Comparing emulator and CLASS posteriors additionally
requires inference with the reference solver and a comparison of posterior
locations and widths.

## ACT ell coverage and the joint analysis

The official ACT bandpower windows cover ell=2…8501, whereas this likelihood
version requests ell=9001 by default. The current emulator covers only
ell=2…8999. `act.py` changes the theory request to the largest ell actually used
by the windows. It preserves all windows, observations, covariance matrices, and
calibration handling, without extrapolating the spectra. If a future data version
requires ell values outside the emulator's coverage, the interface raises an
error. The corresponding test checks that full and cropped theory arrays give
the same likelihood.

The joint configuration uses the official `act_dr6_cmbonly.PlanckActCut`, with
default Planck high-ell cuts of TT≤1000 and TE/EE≤600. This follows the official
combination prescription rather than adding the complete Planck and ACT
likelihoods. All three analyses currently exclude lensing reconstruction
likelihoods, BAO, and other datasets.

References: [official ACT likelihood](https://github.com/ACTCollaboration/DR6-ACT-lite)
and [official Planck cuts for the joint analysis](https://github.com/ACTCollaboration/DR6-ACT-lite/blob/main/act_dr6_cmbonly/PlanckActCut.yaml).
