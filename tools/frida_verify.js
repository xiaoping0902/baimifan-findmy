// frida_verify.js — 按《完整数据读取清单》逐条核对偏移（真机验证）
//
// 只读、不写。输出全部走 send({...})，字段和文档一一对应。

const OFF = {
  GWorld: 0x178B44E0,
  WorldGameInstance: 0x190,
  WorldPersistentLevel: 0xF8,
  GameInstanceLocalPlayers: 0x38,
  LocalPlayerController: 0x30,
  ControllerPawn: 0x3A0,

  ActorRoot: 0x180,            // 清单 §8
  ActorPlayerState: 0x390,     // 912
  ActorDeadFlag: 0xDC8,        // 3528
  ActorTeamComp: 0x10C0,       // 4288
  TeamCompTeamID: 0x108,       // +264
  ActorCombatComp: 0x1020,     // 4128
  CombatWeapon: 0x4D8,         // 1240
  WeaponIdField: 0x838,        // 2104
  CharacterMesh: 0x3D0,

  MeshBones750: 0x750,         // 清单 §3.1：骨骼数组
  MeshC2W: 0x210,              // 528，ComponentToWorld
  BoneStride: 0x30,

  PS_UIN: 0x490,               // 1168
  PS_Name: 0x470,              // 1136 (FString*)
  PS_AIFlag: 0x39E,            // 926：==0 → 人机
  PS_Remove: 0x4C0,            // 1216
};

const BONE19 = [32,30,5,3,2,1,6,7,8,34,35,36,58,59,60,62,63,64,0];

function rd(p) { try { return p.readPointer(); } catch (e) { return null; } }
function ok(p) { return p && !p.isNull() && p.compare(ptr('0x100000000')) >= 0; }

function utf16Name(strPtr) {
  try {
    if (!ok(strPtr)) return null;
    const len = strPtr.readS32();
    const data = strPtr.add(8);
    if (len <= 0 || len > 64) return null;
    let s = '';
    for (let i = 0; i < len; i++) {
      const c = data.add(i * 2).readU16();
      if (c === 0) break;
      s += String.fromCharCode(c);
    }
    return s || null;
  } catch (e) { return null; }
}

function worldPos(actor) {
  try {
    const root = rd(actor.add(OFF.ActorRoot));
    if (!ok(root)) return null;
    const p = root.add(0x220);
    const x = p.readFloat(), y = p.add(4).readFloat(), z = p.add(8).readFloat();
    if (!isFinite(x) || Math.abs(x) > 1e7) return null;
    return [Math.round(x), Math.round(y), Math.round(z)];
  } catch (e) { return null; }
}

function boneArrayOf(mesh) {
  try {
    if (!ok(mesh)) return null;
    const d = rd(mesh.add(OFF.MeshBones750));
    if (!ok(d)) return { data: d ? d.toString() : null, num: 0 };
    const num = mesh.add(OFF.MeshBones750 + 8).readS32();
    const max = mesh.add(OFF.MeshBones750 + 12).readS32();
    return { data: d.toString(), num: num, max: max };
  } catch (e) { return null; }
}

function c2wOf(mesh) {
  try {
    if (!ok(mesh)) return null;
    const q = mesh.add(OFF.MeshC2W);
    return {
      quat: [q.readFloat(), q.add(4).readFloat(), q.add(8).readFloat(), q.add(12).readFloat()],
      trans: [q.add(0x10).readFloat(), q.add(0x14).readFloat(), q.add(0x18).readFloat()],
    };
  } catch (e) { return null; }
}

function probe(actor, tag) {
  const rec = { tag: tag, actor: actor.toString() };
  rec.pos = worldPos(actor);

  const ps = rd(actor.add(OFF.ActorPlayerState));
  if (ok(ps)) {
    rec.playerState = ps.toString();
    try { rec.uin = ps.add(OFF.PS_UIN).readU64().toString(); } catch (e) {}
    try { rec.name = utf16Name(rd(ps.add(OFF.PS_Name))); } catch (e) {}
    try { rec.aiWord = ps.add(OFF.PS_AIFlag).readS32(); } catch (e) {}
    try { rec.remove = ps.add(OFF.PS_Remove).readU8(); } catch (e) {}
  }

  const tc = rd(actor.add(OFF.ActorTeamComp));
  if (ok(tc)) { try { rec.team = tc.add(OFF.TeamCompTeamID).readS32(); } catch (e) {} }

  try { rec.dead = actor.add(OFF.ActorDeadFlag).readU8(); } catch (e) {}

  const mesh = rd(actor.add(OFF.CharacterMesh));
  if (ok(mesh)) {
    rec.mesh = mesh.toString();
    rec.bones = boneArrayOf(mesh);
    rec.c2w = c2wOf(mesh);
    if (rec.bones && rec.bones.num > 0 && rec.bones.num > 64) {
      // 用文档的 19 点表取前几根，验证索引是否合理
      const arr = ptr(rec.bones.data);
      const pts = [];
      for (let k = 0; k < 6; k++) {
        const idx = BONE19[k];
        if (idx >= rec.bones.num) { pts.push(null); continue; }
        try {
          const t = arr.add(idx * OFF.BoneStride + 0x10);
          pts.push([Math.round(t.readFloat()), Math.round(t.add(4).readFloat()),
                    Math.round(t.add(8).readFloat())]);
        } catch (e) { pts.push(null); }
      }
      rec.bonePts = pts;
    }
  }

  const combat = rd(actor.add(OFF.ActorCombatComp));
  if (ok(combat)) {
    const w = rd(combat.add(OFF.CombatWeapon));
    if (ok(w)) {
      rec.weaponObj = w.toString();
      try { rec.weaponId = w.add(OFF.WeaponIdField).readU64().toString(); } catch (e) {}
    }
  }
  return rec;
}

function main() {
  const mod = Process.findModuleByName('DeltaForceClient') ||
              Process.enumerateModules().find(m => m.name.indexOf('DeltaForce') >= 0);
  if (!mod) { send({ stage: 'module', error: 'not found' }); return; }
  const base = mod.base;
  const gw = base.add(OFF.GWorld).readPointer();
  send({ stage: 'world', base: base.toString(), gworld: gw.toString() });
  if (!ok(gw)) return;

  const gi = rd(gw.add(OFF.WorldGameInstance));
  let pc = null, pawn = null;
  if (ok(gi)) {
    const lps = rd(gi.add(OFF.GameInstanceLocalPlayers));
    if (ok(lps)) {
      const lp = rd(lps);
      if (ok(lp)) pc = rd(lp.add(OFF.LocalPlayerController));
    }
  }
  if (ok(pc)) pawn = rd(pc.add(OFF.ControllerPawn));

  if (ok(pawn)) send({ stage: 'self', data: probe(pawn, 'self') });

  const level = rd(gw.add(OFF.WorldPersistentLevel));
  if (!ok(level)) return;
  const data = rd(level.add(0x98));
  const num = level.add(0xA0).readS32();
  send({ stage: 'level', num: num });
  if (!ok(data) || !num || num <= 0 || num > 20000) return;

  const out = [];
  for (let i = 0; i < num && out.length < 12; i++) {
    const a = rd(data.add(i * 8));
    if (!ok(a)) continue;
    const p = worldPos(a);
    if (!p) continue;
    out.push(probe(a, 'idx' + i));
  }
  send({ stage: 'actors', data: out });
}

setTimeout(main, 500);
