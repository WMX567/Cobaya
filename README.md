# Emulator → Cobaya → Planck / ACT

Run parameter inference with trained segmented emulator models and Planck / ACT
likelihoods. Run all commands from this repository root.

## Setup

Use your existing conda environment:

```bash
conda activate nanogpt
python -m pip install -r emulator_bridge/requirements.txt
bash emulator_bridge/install_data_carc.sh
python -m cobaya install polychord -p emulator_bridge/packages --no-set-global
```

Keep the `Emulator` project next to this repository, or set `EMULATOR_DIR` to its
absolute path for CARC jobs.

Use your existing model weights. The model directory must contain:

```text
models/
  TT/        # 0_3000/best.pt, 3000_6000/best.pt, 6000_9000/best.pt
  EE/        # same three segments
  TE/        # same three segments
  PhiPhi/    # same three segments
```

The default directory is `emulator_bridge/models`. To use another location:

```bash
export COBAYA_MODELS=/absolute/path/to/models
```

Models and likelihood data are not included in Git. Install or copy them onto
CARC before submitting jobs. The default data directory is
`emulator_bridge/packages`.

## Sampler settings

The submission helper defaults to **PolyChord**. Edit the `sampler.polychord`
block in the file for your dataset:

| Dataset | Configuration |
| --- | --- |
| Planck | `emulator_bridge/configs/planck_polychord.yaml` |
| ACT | `emulator_bridge/configs/act_polychord.yaml` |
| ACT + Planck | `emulator_bridge/configs/act_planck_polychord.yaml` |

```yaml
sampler:
  polychord:
    nlive: 50d
    num_repeats: 5d
    precision_criterion: 0.001
    do_clustering: true
    cluster_posteriors: true
    boost_posterior: 5
    seed: 42
```

`d` is the number of sampled parameters: 10 for Planck, 11 for ACT, and 12 for
ACT + Planck. `emulator_bridge/evaluate.yaml` is not used by the submission helper.
Running `make_configs.py` overwrites generated configurations; update its
PolyChord settings too if you regenerate them.

## Submit on CARC

```bash
# Run from the repository root. Submits all three datasets with PolyChord.
sbatch emulator_bridge/submit_carc.sh all
# If CARC requires an explicit allocation account:
# sbatch --account=YOUR_CARC_ACCOUNT emulator_bridge/submit_carc.sh all
```

The helper defaults to `polychord` and the `nanogpt` environment.
It submits three independent jobs: Planck, ACT, and ACT + Planck, each with a
10-hour limit. The launcher's allocation account is forwarded to the sampling jobs.
Set `COBAYA_MODELS` first if your weights are outside `emulator_bridge/models`.
To submit only one dataset, replace `all` with `planck`, `act`, or `act_planck`.

Default resources: one task, four CPU cores, 16 GB RAM, and **10 hours**.
Submission and job logs show the configuration being used.

- Logs: `emulator_bridge/logs/<dataset>-<jobid>.out`
- Results: `emulator_bridge/chains/<dataset>_polychord*`

After a timeout, resubmit the same command to resume from PolyChord's saved
state. PolyChord jobs do not automatically requeue. Keep the same model files,
priors, paths, and output tag when resuming.

For a separate run, set a unique tag before submitting:

```bash
export COBAYA_RUN_TAG=run2
```

Never run two jobs with the same dataset and output tag concurrently.
To use MCMC instead, use `COBAYA_SAMPLER=mcmc bash emulator_bridge/submit_carc.sh all`
and edit the corresponding
`configs/<dataset>_mcmc.yaml`. The MCMC script supports checkpoint-based automatic
requeue when permitted by CARC.

## Check before sampling

```bash
conda activate nanogpt
python -m pip check
python -m pytest -q emulator_bridge/test_bridge.py emulator_bridge/test_carc.py
python -m cobaya run emulator_bridge/configs/planck_evaluate.yaml
```

Direct YAML runs use the paths inside the YAML, rather than the CARC environment
path overrides. Set `models_path`, `emulator_path`, and `packages_path` there if
needed. Tests requiring unavailable model weights or ACT data may skip.

Historical validation is recorded in `emulator_bridge/validation_results.json`.
It does not establish MCMC convergence or emulator accuracy against CLASS.
