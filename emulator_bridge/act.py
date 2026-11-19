"""Use the official ACT likelihood with its exact bandpower-window ell coverage."""

from act_dr6_cmbonly import ACTDR6CMBonly


class ACTDR6(ACTDR6CMBonly):
    """Change only the theory request, preserving all ACT data, windows and cuts.

    The public v1.0 windows use ell <= 8501, whereas the upstream default requests
    ell=9001. Infer the exact required maximum from the loaded windows so that
    the emulator's ell=8999 limit is sufficient without extrapolation or padding.
    If future data require higher ell the emulator will explicitly reject them.
    """

    def get_requirements(self):
        requirements = super().get_requirements()
        maxima = {}
        for spectrum in self.spec_meta:
            key = spectrum["pol"]
            maxima[key] = max(maxima.get(key, 0), int(spectrum["window"].values.max()))
        requirements["Cl"] = maxima
        return requirements
