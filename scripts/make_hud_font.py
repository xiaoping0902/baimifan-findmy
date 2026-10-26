"""Create the production static, semibold TrueType font from Noto Sans SC.

Usage: python scripts/make_hud_font.py path/to/NotoSansSC[wght].ttf
Requires fontTools. The source is available under the SIL Open Font License at
https://github.com/google/fonts/tree/main/ofl/notosanssc
Do not substitute the older CFF .otf used by make_font.py: the HUD uses stb.
"""
import argparse
import hashlib
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "app/Resources/NotoSansSC-full.ttf")
    args = parser.parse_args()
    font = TTFont(args.source, recalcTimestamp=False)
    if "glyf" not in font or "fvar" not in font:
        parser.error("source must be the variable TrueType version, with glyf and fvar tables")
    original_codepoints = set(font.getBestCmap())
    instantiateVariableFont(font, {"wght": 600}, inplace=True, updateFontNames=True)
    if "fvar" in font or font["OS/2"].usWeightClass != 600:
        raise ValueError("font did not become a static semibold instance")
    if set(font.getBestCmap()) != original_codepoints:
        raise ValueError("instancing must retain the complete character coverage")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    font.save(args.output)
    print(f"Source SHA256: {hashlib.sha256(args.source.read_bytes()).hexdigest()}")
    print(f"Saved {len(original_codepoints)} codepoints, weight 600: {args.output}")
    print(f"Output SHA256: {hashlib.sha256(args.output.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
