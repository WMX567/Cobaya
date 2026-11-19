"""Run PolyChord with the CARC path overrides and its native resume files."""

import argparse
import json
import os
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", choices=["planck", "act", "act_planck"])
    args = parser.parse_args()
    from cobaya.run import run
    from cobaya.yaml import yaml_load_file

    root = Path(__file__).resolve().parents[1]
    config = root / f"emulator_bridge/configs/{args.dataset}_polychord.yaml"
    info = yaml_load_file(str(config))
    if set(info.get("sampler", {})) != {"polychord"}:
        parser.error("Expected a polychord sampler configuration")
    tag = os.environ.get("COBAYA_RUN_TAG", "")
    if tag and not all(c.isascii() and (c.isalnum() or c in "_-") for c in tag):
        parser.error("COBAYA_RUN_TAG may contain only letters, digits, underscores and hyphens")
    theory = info["theory"]["emulator_bridge.theory.SegmentedEmulator"]
    theory["models_path"] = os.environ.get("COBAYA_MODELS", str(root / "emulator_bridge/models"))
    theory["emulator_path"] = os.environ.get("EMULATOR_DIR", str(root.parent / "Emulator"))
    if os.environ.get("COBAYA_SEED"):
        info["sampler"]["polychord"]["seed"] = int(os.environ["COBAYA_SEED"])
    chains = Path(os.environ.get("COBAYA_CHAINS_DIR", str(root / "emulator_bridge/chains")))
    prefix = chains / f"{args.dataset}_polychord{('_' + tag) if tag else ''}"
    print(f"Python: {sys.executable}", flush=True)
    print(f"Configuration YAML: {config.resolve()}", flush=True)
    print("Requested sampler: " + json.dumps(info["sampler"], sort_keys=True), flush=True)
    print(f"Output prefix: {prefix}", flush=True)
    run(info, output=str(prefix), packages_path=os.environ.get(
        "COBAYA_PACKAGES_PATH", str(root / "emulator_bridge/packages")),
        resume=True, no_mpi=True)


if __name__ == "__main__":
    main()
