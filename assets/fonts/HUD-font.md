# HUD font

The production resource is `app/Resources/NotoSansSC-full.ttf`, a static
Noto Sans SC SemiBold (weight 600) TrueType instance. It retains all 30,890
codepoints in the source font, including Chinese panel labels, statistics and
equipment names. ImGui loads glyphs as needed; it does not bake the entire font
at startup.

Source: [Google Fonts Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc),
`NotoSansSC[wght].ttf`, under the SIL Open Font License 1.1. The complete license
is shipped in `app/Resources/fonts/OFL.txt`.

Source SHA256:
`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`

To regenerate with fontTools installed:

```powershell
python scripts/make_hud_font.py 'path/to/NotoSansSC[wght].ttf'
python -m unittest discover -s tests -p test_hud_font.py -v
```

The old `make_font.py` produces a source-text subset from a different CFF font.
It is not the production HUD font generator. Do not replace the TrueType
resource with a CFF OpenType font.

The modern ImGui Metal backend uses `DisplayFramebufferScale` for Retina
rasterization. Keep `ImFontConfig::RasterizerDensity` at 1, so a 3x display
uses a 3x bake rather than multiplying the density twice.
