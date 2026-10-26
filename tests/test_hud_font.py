"""Check the font shipped to ImGui, without a fontTools dependency in CI."""
from pathlib import Path
import struct
import unittest


FONT = Path(__file__).resolve().parents[1] / "app/Resources/NotoSansSC-full.ttf"
REQUIRED_TEXT = "小玉灵动岛真人机物资观战自身队伍人物干员名字头甲包刀枪血量未知距离统计0123456789:/·—m"
REQUIRED_TEXT += "红狼威龙无名张姐疯医女医蝶养狗的老黑比特盾狗乌鲁鲁液氮露娜骇爪老头蜂医"


def font_tables(data):
    count, = struct.unpack_from(">H", data, 4)
    tables = {}
    for index in range(count):
        tag, _, offset, length = struct.unpack_from(">4sIII", data, 12 + 16 * index)
        tables[tag] = data[offset:offset + length]
    return tables


def mapped_glyph(cmap, codepoint):
    """Read the BMP format-4 map used by stb_truetype and ImWchar16."""
    count, = struct.unpack_from(">H", cmap, 2)
    for index in range(count):
        _, _, offset = struct.unpack_from(">HHI", cmap, 4 + 8 * index)
        if struct.unpack_from(">H", cmap, offset)[0] != 4:
            continue
        segments = struct.unpack_from(">H", cmap, offset + 6)[0] // 2
        ends = offset + 14
        starts = ends + 2 * segments + 2
        deltas = starts + 2 * segments
        ranges = deltas + 2 * segments
        for segment in range(segments):
            end = struct.unpack_from(">H", cmap, ends + segment * 2)[0]
            start = struct.unpack_from(">H", cmap, starts + segment * 2)[0]
            if not start <= codepoint <= end:
                continue
            delta = struct.unpack_from(">h", cmap, deltas + segment * 2)[0]
            range_offset = struct.unpack_from(">H", cmap, ranges + segment * 2)[0]
            if not range_offset:
                return (codepoint + delta) & 0xFFFF
            address = ranges + segment * 2 + range_offset + 2 * (codepoint - start)
            glyph = struct.unpack_from(">H", cmap, address)[0]
            return (glyph + delta) & 0xFFFF if glyph else 0
    return 0


class HUDProductionFontTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tables = font_tables(FONT.read_bytes())

    def test_font_has_static_truetype_outlines_and_medium_weight(self):
        self.assertIn(b"glyf", self.tables, "stb_truetype needs TrueType outlines")
        self.assertIn(b"loca", self.tables)
        self.assertNotIn(b"fvar", self.tables, "ship an instantiated font")
        weight = struct.unpack_from(">H", self.tables[b"OS/2"], 4)[0]
        self.assertGreaterEqual(weight, 550, "small HUD text needs the requested stronger strokes")
        self.assertLessEqual(weight, 650)

    def test_menu_stats_and_person_fields_have_real_glyphs(self):
        missing = [char for char in sorted(set(REQUIRED_TEXT))
                   if mapped_glyph(self.tables[b"cmap"], ord(char)) == 0]
        self.assertEqual(missing, [], "HUD text must not fall back to a square")


if __name__ == "__main__":
    unittest.main()
