"""Evaluate truth and emulator spectra against exactly the same Cobaya likelihoods."""

import argparse
import json
from pathlib import Path

import numpy as np

from cobaya.model import get_model
from cobaya.yaml import yaml_load_file
from emulator_bridge.theory import SavedClassCl, SegmentedEmulator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--truth", type=Path, required=True, help="Raw dimensionless CLASS C_l NPZ")
    parser.add_argument("--predictions", type=Path, help="Raw dimensionless predicted C_l NPZ; otherwise run checkpoints")
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("configs") / "planck_compare.yaml")
    parser.add_argument("--sample", type=int, default=0, help="Row in batched truth/prediction NPZ")
    parser.add_argument("--parameters", type=Path, help="JSON of emulator parameters; otherwise use truth meta_json.params")
    parser.add_argument("--emulator-path", type=Path, default=Path(__file__).resolve().parents[2] / "Emulator")
    parser.add_argument("--models", type=Path, default=Path(__file__).with_name("models"))
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--packages-path", type=Path)
    parser.add_argument("--output", type=Path, default=Path("emulator_bridge/comparison.json"))
    args = parser.parse_args()
    config = yaml_load_file(str(args.config))
    # A fixed-spectrum likelihood only needs fixed nuisance parameters.
    nuisance = config.get("params", {})
    if any(not isinstance(v, (int, float)) for v in nuisance.values()):
        parser.error("Comparison config params must be fixed numeric nuisance values")
    common = {"likelihood": config["likelihood"], "params": nuisance,
              "stop_at_error": True}
    packages = str(args.packages_path) if args.packages_path else config.get("packages_path")
    if packages:
        common["packages_path"] = packages
    truth_info = {**common, "theory": {"spectra": {"external": SavedClassCl,
                  "spectra_file": str(args.truth), "sample": args.sample}}}
    if args.predictions:
        pred_info = {**common, "theory": {"spectra": {"external": SavedClassCl,
                     "spectra_file": str(args.predictions), "sample": args.sample}}}
    else:
        if args.parameters:
            parameters = json.loads(args.parameters.read_text())
        else:
            with np.load(args.truth, allow_pickle=False) as data:
                if "meta_json" not in data:
                    parser.error("Checkpoint prediction needs --parameters or truth meta_json")
                parameters = json.loads(data["meta_json"].item())["params"]
        if "ln_A_s_1e10" not in parameters and "ln10^{10}A_s" in parameters:
            parameters["ln_A_s_1e10"] = parameters["ln10^{10}A_s"]
        selected = {p: float(parameters[p]) for p in SegmentedEmulator.input_params}
        pred_info = {**common, "params": {**nuisance, **selected},
                     "theory": {"emulator": {"external": SegmentedEmulator,
                     "emulator_path": str(args.emulator_path), "models_path": str(args.models),
                     "device": args.device}}}
    with get_model(truth_info) as truth_model:
        names = list(truth_model.likelihood)
        truth_logl = np.asarray(truth_model.loglikes({}, return_derived=False))
    with get_model(pred_info) as pred_model:
        pred_logl = np.asarray(pred_model.loglikes({}, return_derived=False))
    if not np.isfinite(truth_logl).all() or not np.isfinite(pred_logl).all():
        raise ValueError("Nonfinite likelihood; inspect the spectra/configuration")
    delta = pred_logl - truth_logl
    report = {"truth": str(args.truth.resolve()),
              "predictions": str(args.predictions.resolve()) if args.predictions else "segmented checkpoints",
              "sample": args.sample, "config": str(args.config.resolve()),
              "nuisance_parameters": nuisance,
              "convention": "delta_logL = logL(emulator) - logL(truth); delta_chi2 = -2*delta_logL",
              "likelihoods": {name: {"logL_truth": float(t), "logL_emulator": float(p),
                                    "delta_logL": float(d), "delta_chi2": float(-2*d)}
                              for name, t, p, d in zip(names, truth_logl, pred_logl, delta)},
              "total": {"logL_truth": float(truth_logl.sum()),
                        "logL_emulator": float(pred_logl.sum()),
                        "delta_logL": float(delta.sum()), "delta_chi2": float(-2*delta.sum())}}
    if args.output.resolve() in {p.resolve() for p in (args.truth, args.predictions, args.config, args.parameters) if p}:
        parser.error("Output must differ from input files")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
