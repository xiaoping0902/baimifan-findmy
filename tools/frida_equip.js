// frida_equip.js — 读每个角色的装备槽物品 ID（头/甲/包）
//
// 链路（《完整数据读取清单》§6）：
//   actor + 0x24E0 → 装备组件
//          + 0x1D8 → 槽位数组（10 槽 × 0x30 字节，槽内 +0 是 uint64 物品 ID）
//
// 输出原始十进制 ID + 几种候选解析，便于和数据对照（用户已知：6头6甲 / 5套 / 1级套）。

const OFF = {
  GWorld: 0x178B44E0,
  WorldGameInstance: 0x190,
  WorldPersistentLevel: 0xF8,
  GameInstanceLocalPlayers: 0x38,
  LocalPlayerController: 0x30,
  ControllerPawn: 0x3A0,

  ActorRoot: 0x180,
  CharacterMesh: 0x3D0,
  MeshBones: 0x750,
  EquipComp: 0x24E0,
  EquipSlots: 0x1D8,
  SlotStride: 0x30,
  SlotCount: 10,
};

function rd(p) { try { return p.readPointer(); } catch (e) { return null; } }
function ok(p) { return p && !p.isNull() && p.compare(ptr('0x100000000')) >= 0 && p.compare(ptr('0x8000000000')) < 0; }

function parseCandidates(idStr) {
  const s = idStr;
  const out = { len: s.length };
  if (s.length >= 8) {
    out.A_type = Number(s.slice(1, 4));   // 文档：第2-4位
    out.A_lv   = Number(s.slice(7, 8));   // 文档：第8位
  }
  if (s.length >= 6) {
    out.B_type = Number(s.slice(0, 3));   // 另一种可能：前3位
    out.B_lv   = Number(s.slice(5, 6));
    out.tail2  = Number(s.slice(-2));
    out.tail1  = Number(s.slice(-1));
  }
  return out;
}

function main() {
  const mod = Process.findModuleByName('DeltaForceClient') ||
              Process.enumerateModules().find(m => m.name.indexOf('DeltaForce') >= 0);
  const gw = mod.base.add(OFF.GWorld).readPointer();
  if (!ok(gw)) { send({ error: 'gworld' }); return; }

  const level = rd(gw.add(OFF.WorldPersistentLevel));
  const data = level ? rd(level.add(0x98)) : null;
  const num = level ? level.add(0xA0).readS32() : 0;
  if (!ok(data) || !num) { send({ error: 'level' }); return; }

  const chars = [];
  for (let i = 0; i < num && i < 4000; i++) {
    const a = rd(data.add(i * 8));
    if (!ok(a)) continue;

    const mesh = rd(a.add(OFF.CharacterMesh));
    if (!ok(mesh)) continue;
    const bd = rd(mesh.add(OFF.MeshBones));
    if (!ok(bd)) continue;
    const bn = mesh.add(OFF.MeshBones + 8).readS32();
    if (!bn || bn < 20 || bn > 300) continue;

    let pos = null;
    try {
      const root = rd(a.add(OFF.ActorRoot));
      if (ok(root)) {
        const p = root.add(0x220);
        const x = p.readFloat(), y = p.add(4).readFloat(), z = p.add(8).readFloat();
        if (isFinite(x) && Math.abs(x) < 1e7) pos = [Math.round(x), Math.round(y), Math.round(z)];
      }
    } catch (e) {}

    const rec = { i: i, actor: a.toString(), bones: bn, pos: pos };
    try {
      const ps = rd(a.add(0x390));
      rec.hasPS = ok(ps);
    } catch (e) {}

    const ec = rd(a.add(OFF.EquipComp));
    if (ok(ec)) {
      rec.equipComp = ec.toString();
      const slots = rd(ec.add(OFF.EquipSlots));
      if (ok(slots)) {
        rec.slotsPtr = slots.toString();
        const ids = [];
        for (let s = 0; s < OFF.SlotCount; s++) {
          try {
            const id = slots.add(s * OFF.SlotStride).readU64();
            if (id.compare(0) !== 0) {
              const str = id.toString();
              ids.push({ s: s, id: str, parse: parseCandidates(str) });
            }
          } catch (e) {}
        }
        rec.ids = ids;
      }
    }
    chars.push(rec);
  }
  send({ stage: 'chars', count: chars.length, data: chars });
}

setTimeout(main, 500);
