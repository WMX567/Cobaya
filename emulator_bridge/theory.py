"""CLASS dimensionless C_l providers for Cobaya (not D_l)."""

import importlib.util
from pathlib import Path

import numpy as np

from cobaya.theory import Theory

ROOT = Path(__file__).resolve().parents[1]
SPECTRA = {"tt": "TT", "ee": "EE", "te": "TE", "pp": "PhiPhi"}


def read_spectra(path, sample=0):
    """Read a CLASS archive or an Emulator prediction archive, selecting one row."""
    with np.load(path, allow_pickle=False) as data:
        result = {"ell": np.array(data["ell"])}
        for key in SPECTRA:
            if key in data:
                values = np.asarray(data[key], dtype=float)
                if values.ndim == 2:
                    values = values[sample]
                elif sample != 0:
                    raise ValueError("Single-spectrum archive only supports sample=0")
                result[key] = values.copy()
    return validate_spectra(result)


def validate_spectra(spectra):
    ell = np.asarray(spectra["ell"])
    if (ell.ndim != 1 or not len(ell) or not np.isfinite(ell).all()
            or not np.array_equal(ell, ell.astype(int))
            or not np.array_equal(ell, np.arange(ell[0], ell[-1] + 1))
            or ell[0] not in (0, 2)):
        raise ValueError("ell must be contiguous integers starting at 0 or 2")
    result = {"ell": ell.astype(int)}
    for key, values in spectra.items():
        if key == "ell":
            continue
        values = np.asarray(values, dtype=float)
        if key not in SPECTRA or values.shape != ell.shape or not np.isfinite(values).all():
            raise ValueError(f"Invalid spectrum {key}: expected finite array matching ell")
        result[key] = values.copy()
    if len(result) == 1:
        raise ValueError("No supported spectra in archive")
    return result


class ClassClProvider(Theory):
    """Shared unit conversion and strict likelihood ell-coverage checks."""

    T_cmb: float = 2.7255

    def initialize(self):
        self._requested = {}

    def must_provide(self, **requirements):
        super().must_provide(**requirements)
        for key, lmax in (requirements.get("Cl") or {}).items():
            key = key.lower()
            if key not in SPECTRA:
                raise ValueError(f"Emulator does not provide {key}; supported: {list(SPECTRA)}")
            if int(lmax) != lmax or lmax < 2:
                raise ValueError(f"Invalid lmax for {key}: {lmax}")
            self._requested[key] = max(int(lmax), self._requested.get(key, 0))

    def _store(self, state, spectra):
        spectra = validate_spectra(spectra)
        ell = spectra["ell"]
        for key, lmax in self._requested.items():
            if key not in spectra or ell[-1] < lmax:
                raise ValueError(f"Missing {key} coverage through ell={lmax}")
        # Cobaya indexes arrays by ell, so explicitly pad the absent monopole/dipole.
        state["Cl"] = {"ell": np.arange(ell[-1] + 1)}
        for key in spectra.keys() - {"ell"}:
            values = np.zeros(ell[-1] + 1)
            values[ell] = spectra[key]
            values[:2] = 0
            state["Cl"][key] = values

    def get_Cl(self, ell_factor=False, units="FIRASmuK2"):
        factors = {"1": 1.0, "muK2": self.T_cmb * 1e6, "K2": self.T_cmb,
                   "FIRASmuK2": 2.7255e6, "FIRASK2": 2.7255}
        if units not in factors:
            raise ValueError(f"Unknown CMB units: {units}")
        result = {key: value.copy() for key, value in self.current_state["Cl"].items()}
        ll = result["ell"] * (result["ell"] + 1.0)
        for key in result.keys() - {"ell"}:
            if key != "pp":
                result[key] *= factors[units] ** 2
            if ell_factor:
                factor = ll[:len(result[key])]
                result[key] *= (factor ** 2 if key == "pp" else factor) / (2 * np.pi)
        return result


class SavedClassCl(ClassClProvider):
    """Supply a single, fixed NPZ prediction/truth to existing CMB likelihoods."""

    spectra_file: str = ""
    sample: int = 0
    params = {"cl_amplitude": 1.0}

    def initialize(self):
        super().initialize()
        self._spectra = read_spectra(self.spectra_file, self.sample)

    def calculate(self, state, want_derived=True, **params_values_dict):
        # Cobaya requires every theory component to depend on an input parameter.
        # Keep this physical spectrum amplitude fixed at one in comparisons.
        amplitude = params_values_dict.get("cl_amplitude", 1.0)
        self._store(state, {key: value if key == "ell" else value * amplitude
                            for key, value in self._spectra.items()})


class SegmentedEmulator(ClassClProvider):
    """Load trained residual networks once; predict at each Cobaya parameter point."""

    emulator_path: str = str(ROOT.parent / "Emulator")
    models_path: str = str(ROOT / "emulator_bridge" / "models")
    device: str = "cpu"
    # Must match prepare_cosmoclass.py and the checkpoint metadata exactly.
    input_params = ["omega_b", "omega_cdm", "h", "tau_reio", "n_s", "m_ncdm",
                    "ln_A_s_1e10", "N_ur", "log10_G_eff_nu"]

    def initialize(self):
        super().initialize()
        import torch

        self._torch = torch
        source = Path(self.emulator_path) / "cosmopower_pt" / "segmented.py"
        spec = importlib.util.spec_from_file_location("_cobaya_segmented", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self._load_checkpoint = module.load_checkpoint
        self._networks = {}

    def must_provide(self, **requirements):
        super().must_provide(**requirements)
        for key, lmax in self._requested.items():
            for lo, hi in ((0, 3000), (3000, 6000), (6000, 9000)):
                if lo > lmax:
                    continue
                label = (key, lo)
                if label in self._networks:
                    continue
                path = Path(self.models_path) / SPECTRA[key] / f"{lo}_{hi}" / "best.pt"
                if not path.is_file():
                    raise FileNotFoundError(f"Missing checkpoint: {path}. Run prepare_models.py first.")
                model, saved = self._load_checkpoint(path, self.device)
                if saved["parameters"] != list(self.input_params) or saved["spectrum"] != SPECTRA[key]:
                    raise ValueError(f"Checkpoint parameter order/spectrum mismatch: {path}")
                ell = saved["ell"].numpy()
                if not np.array_equal(ell, np.arange(max(2, lo), hi)):
                    raise ValueError(f"Unexpected checkpoint ell grid: {path}")
                self._networks[label] = model, saved
            if lmax >= 9000:
                raise ValueError("Emulator stops at ell=8999")

    def calculate(self, state, want_derived=True, **params_values_dict):
        torch = self._torch
        x = torch.tensor([[params_values_dict[p] for p in self.input_params]], dtype=torch.float32)
        spectra = {}
        with torch.inference_mode():
            for key, lmax in self._requested.items():
                parts = []
                for (spectrum, lo), (model, saved) in sorted(self._networks.items()):
                    if spectrum != key or lo > lmax:
                        continue
                    norm = saved["normalization"]
                    y = model(((x - norm["x_mean"]) / norm["x_std"]).to(self.device)).cpu().double()
                    y = y * norm["y_std"] + norm["y_mean"]
                    y = torch.sinh(y) * norm["te_scale"] if key == "te" else torch.exp(y)
                    parts.append(y.numpy()[0])
                spectra[key] = np.concatenate(parts)[:lmax - 1]
        # Different likelihoods can request different lmax for different spectra.
        # Store each at its own length; get_Cl consumers slice according to requirements.
        state["Cl"] = {"ell": np.arange(max(self._requested.values()) + 1)}
        for key, values in spectra.items():
            if not np.isfinite(values).all():
                raise ValueError(f"Nonfinite emulator prediction: {key}")
            state["Cl"][key] = np.concatenate(([0.0, 0.0], values))

