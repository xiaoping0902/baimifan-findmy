'use strict';
/*
 * agent_esp.js — 小玉生产版数据源（Frida agent，跑在游戏进程里）
 *
 * 职责：读内存 → 过滤 → 打包 UDP → 推给 HUD（127.0.0.1:25000）
 *
 * 与旧 training-stream.js 的区别：
 *   · 旧版只认 5 个 BP_RangeTargetCharacter_C，只发坐标
 *   · 本版遍历所有「有骨骼的角色」，过滤自己/队友/死人/观战，
 *     并把队伍、头/甲/包等级、血量、手持武器、UIN 一起发过去
 *
 * 协议 v2（44 字节头 + 48 字节/实体）：
 *   header: magic 'MFFD' | ver=2 | headerSize=44 | count | seq | cam[6] | flags
 *   entity: x,y,z(f32) | isBot,isDead,kind,helmet,armor,bag,health,isSelf(u8×8)
 *           | team(u16) | uin(u64) | weaponId(u64) | classId(u32)
 */

const MOD_NAME = 'DeltaForceClient';
const mod = Process.mainModule;
if (mod.name !== MOD_NAME) throw Error('Unexpected target: ' + mod.name);

const OFF = {
  GWorld: 0x178B44E0,
  WorldGI: 0x190,
  WorldLevel: 0xF8,
  GILocalPlayers: 0x38,
  LPController: 0x30,
  CtrlPawn: 0x3A0,
  CtrlCamera: 0x408,
  LevelActors: 0x98,
  ActorRoot: 0x180,
  ActorPS: 0x390,
  ActorDead: 0xDC8,
  ActorTeam: 0x10C0,
  ActorCombat: 0x1020,
  ActorEquip: 0x24E0,
  ActorHealth: 0x10B8,
  ActorMesh: 0x3D0,
  MeshBones: 0x750,
  MeshC2W: 0x210,
  TeamID: 0x108,
  SquadID: 0x10C,
  WeaponA: 0x4D8,
  WeaponB: 0x588,
  WeaponID: 0x838,
  HealthVal: 0x258,
  PSInactive: 0x4C0,
  PSUin: 0x320,
  PSNameData: 0x470,
  PSNameNum: 0x478,
};

const MAX_ENTITIES = 64;
const ENTITY_BYTES = 48;
const HEADER_BYTES = 44;

let reads = 0, deadline = 0, ranges = [], rangeRefreshAt = 0;

function beginRead() {
  if (Date.now() - rangeRefreshAt > 1000) {
    ranges = Process.enumerateRanges({ protection: 'r--', coalesce: true });
    rangeRefreshAt = Date.now();
  }
  reads = 0;
  deadline = Date.now() + 200;
}

function raw(p, n) {
  if (++reads > 4000 || Date.now() > deadline) throw Error('read-budget');
  let lo = 0, hi = ranges.length - 1, r = null;
  while (lo <= hi) {
    const mid = (lo + hi) >>> 1, c = ranges[mid];
    if (p.compare(c.base) < 0) hi = mid - 1;
    else if (p.compare(c.base.add(c.size)) >= 0) lo = mid + 1;
    else { r = c; break; }
  }
  if (!r || p.add(n).compare(r.base.add(r.size)) > 0) throw Error('unreadable:' + p);
  const b = p.readVolatile(n);
  if (!b || b.byteLength !== n) throw Error('short-read');
  return new DataView(b);
}

const ptrOf = (d, o) => ptr('0x' + d.getBigUint64(o, true).toString(16));
const readPtr = p => { const d = raw(p, 8); const v = d.getBigUint64(0, true); return v === 0n ? null : ptr('0x' + v.toString(16)); };
const readU32 = (p, o) => raw(p.add(o || 0), 4).getUint32(0, true);
const readI32 = (p, o) => raw(p.add(o || 0), 4).getInt32(0, true);
const readU8  = (p, o) => raw(p.add(o || 0), 1).getUint8(0);
const readF32 = (p, o) => raw(p.add(o || 0), 4).getFloat32(0, true);
const readU64 = (p, o) => raw(p.add(o || 0), 8).getBigUint64(0, true);

function ok(p) { return p && !p.isNull(); }

/* ── 坐标：RootComponent + 0x220 ── */
function positionOf(actor) {
  const root = readPtr(actor.add(OFF.ActorRoot));
  if (!ok(root)) return null;
  const d = raw(root.add(0x220), 12);
  const v = [0, 4, 8].map(i => d.getFloat32(i, true));
  if (!v.every(x => Number.isFinite(x) && Math.abs(x) < 1e7)) return null;
  if (v[0] === 0 && v[1] === 0 && v[2] === 0) return null;
  return v;
}

/* ── 物品 ID 十进制解码：第2-4位类型，第8位等级 ── */
function itemTypeLevel(idBig) {
  const s = idBig.toString();
  if (s.length < 8) return null;
  const type = Number(s.slice(1, 4));
  const level = Number(s.slice(7, 8));
  if (!(level >= 1 && level <= 6)) return null;
  return { type: type, level: level };
}

function equipmentOf(actor) {
  const out = { helmet: 0, armor: 0, bag: 0 };
  const comp = readPtr(actor.add(OFF.ActorEquip));
  if (!ok(comp)) return out;
  // 槽位地址会漂，整块读 2KB 在内存里找物品 ID
  const d = raw(comp, 0x800);
  for (let off = 0; off + 8 <= 0x800; off += 8) {
    const v = d.getBigUint64(off, true);
    if (v < 10000001n || v > 0x4A87F317Fn) continue;
    const tl = itemTypeLevel(v);
    if (!tl) continue;
    if (tl.type === 101 && !out.helmet) out.helmet = tl.level;
    else if (tl.type === 105 && !out.armor) out.armor = tl.level;
    else if (tl.type === 108 && !out.bag) out.bag = tl.level;
  }
  return out;
}

function weaponOf(actor) {
  const combat = readPtr(actor.add(OFF.ActorCombat));
  if (!ok(combat)) return 0n;
  let w = null;
  try { w = readPtr(combat.add(OFF.WeaponA)); } catch (e) {}
  if (!ok(w)) { try { w = readPtr(combat.add(OFF.WeaponB)); } catch (e) { return 0n; } }
  if (!ok(w)) return 0n;
  try { return readU64(w.add(OFF.WeaponID)); } catch (e) { return 0n; }
}

function healthOf(actor) {
  const hc = readPtr(actor.add(OFF.ActorHealth));
  if (!ok(hc)) return 0;
  try {
    const v = readF32(hc.add(OFF.HealthVal));
    if (Number.isFinite(v) && v >= 0 && v <= 2000) return Math.round(v);
  } catch (e) {}
  return 0;
}

function bonesOf(actor) {
  const mesh = readPtr(actor.add(OFF.ActorMesh));
  if (!ok(mesh)) return { mesh: null, num: 0 };
  let num = 0;
  try {
    const d = raw(mesh.add(OFF.MeshBones), 16);
    const data = d.getBigUint64(0, true);
    if (data === 0n) return { mesh: mesh, num: 0 };
    num = d.getInt32(8, true);
  } catch (e) { return { mesh: mesh, num: 0 }; }
  return { mesh: mesh, num: num };
}

/* ── 发现世界 / 控制器 / Pawn / 相机 ── */
let cache = { world: null, controller: null, pawn: null, camera: null, at: 0 };

function discover() {
  beginRead();
  const world = readPtr(mod.base.add(OFF.GWorld));
  if (!ok(world)) throw Error('no-world');
  const gi = readPtr(world.add(OFF.WorldGI));
  if (!ok(gi)) throw Error('no-gi');
  const lps = readPtr(gi.add(OFF.GILocalPlayers));
  if (!ok(lps)) throw Error('no-lps');
  const lp = readPtr(lps);
  if (!ok(lp)) throw Error('no-lp');
  const pc = readPtr(lp.add(OFF.LPController));
  if (!ok(pc)) throw Error('no-pc');
  const pawn = readPtr(pc.add(OFF.CtrlPawn));
  let camera = null;
  try { camera = readPtr(pc.add(OFF.CtrlCamera)); } catch (e) {}
  return { world: world, gi: gi, controller: pc, pawn: ok(pawn) ? pawn : null, camera: camera };
}

function cameraData(cam) {
  // UPlayerCameraManager + 0x2D60 → POV 缓存：stamp@0, loc@0x10, rot@0x20, fov@0x2C
  const d = raw(cam.add(0x2D60), 0x30);
  const stamp = d.getFloat32(0, true);
  const loc = [0, 4, 8].map(i => d.getFloat32(0x10 + i, true));
  const rot = [0, 4, 8].map(i => d.getFloat32(0x20 + i, true));
  const fov = d.getFloat32(0x2C, true);
  if (!(fov > 1 && fov < 179)) throw Error('bad-fov');
  if (!loc.every(Number.isFinite)) throw Error('bad-loc');
  return { loc: loc, rot: rot, fov: fov, stamp: stamp };
}

/* ── 主快照 ── */
function snapshot() {
  beginRead();
  if (!cache.world || Date.now() - cache.at > 2000) {
    cache = Object.assign(discover(), { at: Date.now() });
  }
  const world = cache.world;
  if (!ok(world)) { cache.world = null; throw Error('world-gone'); }

  let cam = cache.camera;
  if (!ok(cam)) {
    const d = discover(); cache = Object.assign(d, { at: Date.now() });
    cam = cache.camera;
  }
  if (!ok(cam)) throw Error('no-camera');
  const camData = cameraData(cam);

  const myTeam = (() => {
    const pawn = cache.pawn;
    if (!ok(pawn)) return 0;
    try {
      const tc = readPtr(pawn.add(OFF.ActorTeam));
      if (!ok(tc)) return 0;
      return readI32(tc.add(OFF.TeamID));
    } catch (e) { return 0; }
  })();
  const myMesh = (() => {
    const pawn = cache.pawn;
    if (!ok(pawn)) return null;
    try { return readPtr(pawn.add(OFF.ActorMesh)); } catch (e) { return null; }
  })();

  const level = readPtr(world.add(OFF.WorldLevel));
  if (!ok(level)) throw Error('no-level');
  const listPtr = readPtr(level.add(OFF.LevelActors));
  const num = readI32(level.add(OFF.LevelActors + 8));
  if (!ok(listPtr) || num <= 0 || num > 4096) throw Error('bad-actor-list');

  const entities = [];
  for (let i = 0; i < num && entities.length < MAX_ENTITIES; i++) {
    let actor;
    try { actor = readPtr(listPtr.add(i * 8)); } catch (e) { continue; }
    if (!ok(actor)) continue;

    try {
      const bones = bonesOf(actor);
      if (!bones.num || bones.num < 20) continue;                 // 子弹/箱子没有骨骼
      if (ok(myMesh) && ok(bones.mesh) && bones.mesh.equals(myMesh)) continue;  // 自己
      if (ok(cache.pawn) && actor.equals(cache.pawn)) continue;

      const pos = positionOf(actor);
      if (!pos) continue;

      let dead = 0;
      try { dead = readU8(actor.add(OFF.ActorDead)); } catch (e) {}
      if (dead !== 0) continue;

      const ps = (() => { try { return readPtr(actor.add(OFF.ActorPS)); } catch (e) { return null; } })();
      const hasPS = ok(ps);
      if (hasPS) {
        try { if (readU8(ps.add(OFF.PSInactive)) & 1) continue; } catch (e) {}
      }

      const team = (() => {
        try {
          const tc = readPtr(actor.add(OFF.ActorTeam));
          return ok(tc) ? readI32(tc.add(OFF.TeamID)) : 0;
        } catch (e) { return 0; }
      })();
      if (myTeam !== 0 && team === myTeam && hasPS) continue;      // 队友

      const eq = equipmentOf(actor);
      const hp = healthOf(actor);
      const wid = weaponOf(actor);
      const uin = hasPS ? (() => { try { return readU64(ps.add(OFF.PSUin)); } catch (e) { return 0n; } })() : 0n;

      entities.push({
        x: pos[0], y: pos[1], z: pos[2],
        isBot: hasPS ? 0 : 1, isDead: 0, kind: 1,
        helmet: eq.helmet, armor: eq.armor, bag: eq.bag, health: hp, isSelf: 0,
        team: team, uin: uin, weapon: wid, classId: 0
      });
    } catch (e) { continue; }
  }

  return { camera: camData, entities: entities, myTeam: myTeam };
}

/* ── 编码 + 发送 ── */
function encode(frame, seq) {
  const n = frame.entities.length;
  const buf = new ArrayBuffer(HEADER_BYTES + n * ENTITY_BYTES);
  const d = new DataView(buf);
  d.setUint32(0, 0x4446464d, true);      // 'MFFD'
  d.setUint16(4, 2, true);               // version 2
  d.setUint16(6, HEADER_BYTES, true);
  d.setUint32(8, n, true);
  d.setUint32(12, seq, true);
  const c = frame.camera;
  const camArr = [c.loc[0], c.loc[1], c.loc[2], c.rot[0], c.rot[1], c.fov];
  camArr.forEach((v, i) => d.setFloat32(16 + i * 4, v, true));
  d.setUint32(40, 1, true);              // flags bit0 = 带相机

  frame.entities.forEach((e, i) => {
    const o = HEADER_BYTES + i * ENTITY_BYTES;
    d.setFloat32(o + 0, e.x, true);
    d.setFloat32(o + 4, e.y, true);
    d.setFloat32(o + 8, e.z, true);
    d.setUint8(o + 12, e.isBot);
    d.setUint8(o + 13, e.isDead);
    d.setUint8(o + 14, e.kind);
    d.setUint8(o + 15, e.helmet);
    d.setUint8(o + 16, e.armor);
    d.setUint8(o + 17, e.bag);
    d.setUint8(o + 18, e.health);
    d.setUint8(o + 19, e.isSelf);
    d.setUint16(o + 20, e.team & 0xffff, true);
    d.setBigUint64(o + 24, e.uin, true);
    d.setBigUint64(o + 32, e.weapon, true);
    d.setUint32(o + 40, e.classId, true);
  });
  return buf;
}

const exp = n => Module.getGlobalExportByName(n);
const socket = new NativeFunction(exp('socket'), 'int', ['int', 'int', 'int']);
const sendto = new NativeFunction(exp('sendto'), 'long', ['int', 'pointer', 'ulong', 'int', 'pointer', 'uint']);
const closeFn = new NativeFunction(exp('close'), 'int', ['int']);

const dest = Memory.alloc(16);
dest.writeByteArray([16, 2, 0x61, 0xa8, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
const packet = Memory.alloc(HEADER_BYTES + MAX_ENTITIES * ENTITY_BYTES);

let fd = -1, timer = null;
const stats = { frames: 0, sent: 0, bytes: 0, errors: 0, lastError: null, lastCount: 0, myTeam: 0 };

function tick() {
  try {
    const f = snapshot();
    stats.myTeam = f.myTeam;
    stats.lastCount = f.entities.length;
    const b = encode(f, stats.frames);
    packet.writeByteArray(b);
    const n = Number(sendto(fd, packet, b.byteLength, 0, dest, 16));
    if (n !== b.byteLength) throw Error('sendto ' + n);
    stats.frames++; stats.sent++; stats.bytes += n; stats.lastError = null;
  } catch (e) {
    stats.errors++; stats.lastError = String(e);
  }
}

rpc.exports = {
  status() { return stats; },
  stop() { if (timer) clearInterval(timer); timer = null; if (fd >= 0) closeFn(fd); fd = -1; return stats; },
  start(hz) {
    if (timer) throw Error('already running');
    fd = socket(2, 2, 0);
    if (fd < 0) throw Error('socket failed');
    const period = Math.max(20, Math.round(1000 / (hz || 20)));
    tick();
    timer = setInterval(tick, period);
    return stats;
  },
  snapshot
};
