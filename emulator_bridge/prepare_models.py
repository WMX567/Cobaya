"""Extract only best.pt from the four existing ZIPs without overwriting files."""

import argparse
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip-dir", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, default=ROOT / "emulator_bridge/models")
    args = parser.parse_args()
    for spectrum in ("TT", "EE", "TE", "PhiPhi"):
        with ZipFile(args.zip_dir / f"{spectrum}.zip") as archive:
            for segment in ("0_3000", "3000_6000", "6000_9000"):
                member = f"{segment}/best.pt"
                # Explicit member names avoid extracting arbitrary paths from ZIPs.
                target = args.output / spectrum / member
                if target.exists():
                    print(f"Exists, skipped: {target}")
                    continue
                payload = archive.read(member)
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as output:
                    output.write(payload)
                print(f"Extracted: {target}")


if __name__ == "__main__":
    main()
