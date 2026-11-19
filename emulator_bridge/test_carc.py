"""Exercise signal/checkpoint/resume behavior without a Slurm installation."""

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def wait_for_sampling(process, logfile):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        content = logfile.read_text()
        if "Sampling!" in content:
            return
        assert process.poll() is None, content
        time.sleep(0.1)
    raise AssertionError("Runner did not begin sampling")


def test_slurm_notice_requeues_and_resumes_but_cancel_does_not(tmp_path):
    configs = tmp_path / "emulator_bridge/configs"
    configs.mkdir(parents=True)
    (configs / "planck_mcmc.yaml").write_text(yaml.safe_dump({
        "params": {"x": {"prior": {"min": -10, "max": 10}, "ref": 0, "proposal": 1}},
        "likelihood": {"toy": {"external": "lambda x: -0.5*x*x"}},
        "sampler": {"mcmc": {"burn_in": 0, "max_samples": 10000000,
                              "Rminus1_stop": 0, "Rminus1_cl_stop": 0, "seed": 123}},
    }))
    binary = tmp_path / "bin"
    binary.mkdir()
    scontrol = binary / "scontrol"
    scontrol.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$MOCK_REQUEUES"\n')
    scontrol.chmod(0o755)
    requeues = tmp_path / "requeues"
    environment = {**os.environ, "COBAYA_DIR": str(tmp_path), "COBAYA_PYTHON": sys.executable,
                   "PYTHONPATH": str(ROOT), "SLURM_JOB_ID": "12345", "SLURM_NTASKS": "1",
                   "SLURM_RESTART_COUNT": "0", "COBAYA_AUTO_REQUEUE": "1",
                   "MOCK_REQUEUES": str(requeues), "PATH": f"{binary}:{os.environ['PATH']}"}
    counts = []
    for attempt in range(3):
        logfile = tmp_path / f"job{attempt}.log"
        with logfile.open("w") as log:
            process = subprocess.Popen(["bash", str(ROOT / "emulator_bridge/run_carc.sh"), "planck"],
                                       env=environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                wait_for_sampling(process, logfile)
                time.sleep(0.3)
                process.send_signal(signal.SIGUSR1 if attempt < 2 else signal.SIGTERM)
                status = process.wait(timeout=25)
                assert status == (0 if attempt < 2 else 143), logfile.read_text()
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        if attempt < 2:
            sample = tmp_path / "emulator_bridge/chains/planck_mcmc.1.txt"
            counts.append(sum(not line.startswith("#") for line in sample.read_text().splitlines()))
    assert counts[1] > counts[0] > 0
    assert "Resuming from previous sample!" in (tmp_path / "job1.log").read_text()
    assert requeues.read_text().splitlines() == ["requeue 12345", "requeue 12345"]


def test_submission_helper_forwards_options_for_all_datasets(tmp_path):
    bridge = tmp_path / "emulator_bridge"
    bridge.mkdir()
    (bridge / "run_carc.sh").touch()
    binary = tmp_path / "bin"
    binary.mkdir()
    sbatch = binary / "sbatch"
    sbatch.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$MOCK_SUBMISSIONS"\necho 12345\n')
    sbatch.chmod(0o755)
    record = tmp_path / "submissions"
    environment = {**os.environ, "COBAYA_DIR": str(tmp_path), "MOCK_SUBMISSIONS": str(record),
                   "PATH": f"{binary}:{os.environ['PATH']}"}
    subprocess.run(["bash", str(ROOT / "emulator_bridge/submit_carc.sh"), "all",
                    "--account=test-account", "--time=01:00:00"],
                   env=environment, check=True, capture_output=True, text=True)
    submissions = record.read_text().splitlines()
    assert len(submissions) == 3
    for dataset, command in zip(["planck", "act", "act_planck"], submissions):
        assert command.endswith(f"run_carc.sh {dataset}")
        assert "--account=test-account" in command and "--time=01:00:00" in command


def test_submission_helper_uses_submission_directory_from_spool(tmp_path):
    project = tmp_path / "Cobaya"
    bridge = project / "emulator_bridge"
    bridge.mkdir(parents=True)
    (bridge / "run_carc.sh").touch()
    spool = tmp_path / "spool/slurm/d/job123"
    spool.mkdir(parents=True)
    copied = spool / "slurm_script"
    copied.write_text((ROOT / "emulator_bridge/submit_carc.sh").read_text())
    binary = tmp_path / "bin"
    binary.mkdir()
    sbatch = binary / "sbatch"
    sbatch.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n')
    sbatch.chmod(0o755)
    environment = {**os.environ, "SLURM_SUBMIT_DIR": str(project),
                   "PATH": f"{binary}:{os.environ['PATH']}"}
    environment.pop("COBAYA_DIR", None)
    result = subprocess.run(["bash", str(copied), "planck"], cwd=spool,
                            env=environment, check=True, capture_output=True, text=True)
    assert str(bridge / "run_carc.sh") in result.stdout
    assert (bridge / "logs").is_dir()
    assert not (spool.parent / "emulator_bridge").exists()


def test_batch_scripts_use_submission_directory_when_copied_to_spool(tmp_path):
    project = tmp_path / "Cobaya"
    configs = project / "emulator_bridge/configs"
    configs.mkdir(parents=True)
    (configs / "planck_mcmc.yaml").write_text("sampler: {mcmc: null}\n")
    spool = tmp_path / "spool/slurm/job123"
    spool.mkdir(parents=True)
    python = tmp_path / "mock-python"
    python.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n')
    python.chmod(0o755)
    environment = {**os.environ, "SLURM_SUBMIT_DIR": str(project),
                   "COBAYA_PYTHON": str(python), "SLURM_NTASKS": "1"}
    for key in ("COBAYA_DIR", "COBAYA_PACKAGES_PATH", "COBAYA_CHAINS_DIR"):
        environment.pop(key, None)
    for script in ("install_data_carc.sh", "run_carc.sh"):
        copied = spool / "slurm_script"
        copied.write_text((ROOT / "emulator_bridge" / script).read_text())
        result = subprocess.run(["bash", str(copied)], env=environment, cwd=spool,
                                check=True, capture_output=True, text=True)
        assert str(project / "emulator_bridge/packages") in result.stdout
        assert not (spool.parent / "emulator_bridge").exists()
