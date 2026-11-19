"""Run one resumable Cobaya MCMC chain and checkpoint on Slurm advance notice."""

import argparse
import signal
import sys
from pathlib import Path

_stop_requested = False
_stopped_early = False


def request_stop(signum, frame):
    global _stop_requested
    _stop_requested = True
    print("Slurm stop notice received; waiting for a safe sampling point.", flush=True)


def check_stop(sampler):
    """Called after accepted samples, outside signal handlers and file writes."""
    global _stopped_early
    if _stop_requested and not sampler.converged:
        sampler.collection.out_update()
        sampler.write_checkpoint()
        sampler.max_samples = sampler.n()
        _stopped_early = True
        print("Samples and checkpoint saved; stopping for resubmission.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--output", required=True)
    parser.add_argument("--packages-path", required=True)
    parser.add_argument("--models-path")
    parser.add_argument("--emulator-path")
    parser.add_argument("--seed", type=int)
    args = parser.parse_args()
    signal.signal(signal.SIGUSR1, request_stop)

    from cobaya.run import run
    from cobaya.yaml import yaml_load_file

    info = yaml_load_file(str(args.config))
    if set(info.get("sampler", {})) != {"mcmc"}:
        parser.error("This runner supports only the single-process mcmc sampler")
    options = info["sampler"]["mcmc"] or {}
    if options.get("callback_function"):
        parser.error("An existing callback_function cannot be replaced safely")
    options.update(callback_every=1, output_every="30s",
                   callback_function='import_module("emulator_bridge.carc_runner").check_stop')
    if args.seed is not None:
        options["seed"] = args.seed
    info["sampler"]["mcmc"] = options
    for name, settings in info.get("theory", {}).items():
        if name.endswith("SegmentedEmulator"):
            settings = settings or {}
            if args.models_path:
                settings["models_path"] = args.models_path
            if args.emulator_path:
                settings["emulator_path"] = args.emulator_path
            info["theory"][name] = settings
    _, sampler = run(info, output=args.output, packages_path=args.packages_path,
                     resume=True, no_mpi=True)
    # A final checkpoint also records convergence or completed burn-in correctly.
    sampler.collection.out_update()
    sampler.write_checkpoint()
    return 75 if _stopped_early and not sampler.converged else 0


if __name__ == "__main__":
    # The callback is imported by module name; share its state with the handler.
    from emulator_bridge.carc_runner import main as run_main

    sys.exit(run_main())
