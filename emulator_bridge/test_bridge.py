"""Check Cobaya dependency wiring, CLASS units, and real checkpoint inference."""
import importlib.util
from pathlib import Path

import numpy as np
import pytest

from cobaya.likelihood import Likelihood
from cobaya.model import get_model
from emulator_bridge.theory import ROOT, SavedClassCl, SegmentedEmulator


class TestClLikelihood(Likelihood):
    __test__ = False
    params = {"test_amplitude": 1.0}

    def get_requirements(self):
        return {"Cl": {"tt": 7, "te": 7, "ee": 7, "pp": 5}}

    def logp(self, **params_values):
        raw = self.provider.get_Cl(units="1")
        scaled = self.provider.get_Cl(ell_factor=True)
        ell = raw["ell"]
        ll = ell * (ell + 1.0)
        np.testing.assert_allclose(scaled["tt"], raw["tt"] * 2.7255e6**2 * ll / (2*np.pi))
        n = len(raw["pp"])
        np.testing.assert_allclose(scaled["pp"], raw["pp"] * ll[:n]**2 / (2*np.pi))
        np.testing.assert_array_equal(raw["tt"][:2], 0)
        return -float(np.sum(raw["tt"][2:8]))


def test_saved_spectra_and_coverage(tmp_path):
    path = tmp_path / "spectra.npz"
    values = {k: np.linspace(1e-10, 2e-10, 6) for k in ("tt", "ee", "te", "pp")}
    np.savez(path, ell=np.arange(2, 8), **values)
    info = {"params": {"test_amplitude": 1.0}, "theory": {"spectra": {"external": SavedClassCl,
            "spectra_file": str(path)}}, "likelihood": {"test": TestClLikelihood}}
    with get_model(info) as model:
        result = model.loglikes({}, return_derived=False)
        np.testing.assert_allclose(result, [-values["tt"].sum()])
    theory = SavedClassCl({"spectra_file": str(path)})
    theory.must_provide(Cl={"tt": 8})
    with pytest.raises(ValueError, match="coverage"):
        theory.calculate({})


def test_real_checkpoints_match_original_predict():
    pytest.importorskip("torch")
    path = ROOT / "emulator_bridge/models/TT/0_3000/best.pt"
    if not path.is_file():
        pytest.skip("Run prepare_models first")
    source = Path(SegmentedEmulator.emulator_path) / "cosmopower_pt/segmented.py"
    spec = importlib.util.spec_from_file_location("original_segmented", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    parameters = dict(zip(SegmentedEmulator.input_params,
                          [.02237, .12, .674, .0544, .965, .06, 3.044, 2.0328, -5]))
    with get_model({"params": parameters, "theory": {"emulator": {"external": SegmentedEmulator}},
                    "likelihood": {"test": TestClLikelihood}}) as model:
        model.loglikes({}, return_derived=False)
        actual = model.provider.get_Cl(units="1")
        _, expected = module.predict(path, parameters)
        np.testing.assert_allclose(actual["tt"][2:], expected[0, :6], rtol=1e-6)
        # Each call returns independent storage; likelihoods cannot mutate the cache.
        actual["tt"][2] = 123
        assert model.provider.get_Cl(units="1")["tt"][2] != 123


def test_act_window_request_preserves_official_likelihood():
    pytest.importorskip("act_dr6_cmbonly")
    from emulator_bridge.act import ACTDR6

    packages = ROOT / "emulator_bridge/packages"
    if not (packages / "data/ACTDR6CMBonly/v1.0/dr6_data_cmbonly.fits").is_file():
        pytest.skip("Install real ACT data first")
    likelihood = ACTDR6(packages_path=str(packages))
    required = likelihood.get_requirements()["Cl"]
    assert required == {"tt": 8501, "te": 8501, "ee": 8501}
    cl = {key: np.linspace(1, 100, 9002) for key in required}
    # Removing unused theory multipoles changes no window convolution or likelihood.
    cropped = {key: values[:required[key] + 1] for key, values in cl.items()}
    np.testing.assert_allclose(likelihood.loglike(cl, 1, 1),
                               likelihood.loglike(cropped, 1, 1), rtol=1e-13)
    # Independently verify the Gaussian quadratic form without BLAS matmul.
    predicted = np.zeros_like(likelihood.data_vec)
    for entry in likelihood.spec_meta:
        predicted[entry["idx"]] = np.einsum("ij,i->j", entry["window"].weight,
                                                  cropped[entry["pol"]][entry["window"].values])
    delta = likelihood.data_vec - predicted
    expected = -.5 * np.einsum("i,ij,j->", delta, likelihood.inv_cov, delta)
    np.testing.assert_allclose(likelihood.loglike(cropped, 1, 1), expected, rtol=1e-12)
