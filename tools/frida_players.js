// frida_players.js — 只挑"有 PlayerState 的角色"，核对 UIN / 名字 / 人机 / 队伍 / 骨骼
//
// 目的：Actor 数组里混着大量非角色对象，先按「PlayerState 指针合法」筛出真角色，
// 再把《完整数据读取清单》第 1、2、3、7 节的字段一次性打出来。

const OFF = {
  GWorld: 0x178B44E0,
  WorldGameInstance: 0x190,
  WorldPersistentLevel: 0xF8,
  GameInstanceLocalPlayers: 0x38,
  LocalPlayerController: 0x30,
  ControllerPawn: 0x3A0,

  ActorRoot: 0x180,
  ActorPlayerState: 0x390,
  ActorTeamComp: 0x10C0,
  TeamCompTeamID: 0x108,
  ActorCombatComp: 0x1020,
  CombatWeapon: 0x4D8,
  WeaponIdField: 0x838,
  CharacterMesh: 0x3D0,

  MeshBones: 0x750,

  PS_UIN: 0x490,
  PS_Name: 0x470,
  PS_AI: 0x39E,
};

function rd(p) { try { return p.readPointer(); } catch (e) { return null; } }
function ok(p) { return p && !p.isNull() && p.compare(ptr('0x100000000')) >= 0 && p.compare(ptr('0x8000000000')) < 0; }

function tryRead(ptrOrNull, fn) { try { return fn(ptrOrNull); } catch (e) { return null; } }

// UE4 FString：{ int32 Num; wchar Data[Num]; }，指针指向 FString 本体
function readFString(fs) {
  if (!ok(fs)) return null;
  const num = fs.readS32();
  if (num <= 0 || num > 64) return null;
  const data = fs.add(8);
  let s = '';
  for (let i = 0; i < num; i++) {
    const c = data.add(i * 2).readU16();
    if (c === 0) break;
    s += String.fromCharCode(c);
  }
  return s || null;
}

// 两种解释都试：+0x470 指向 FString，或 +0x470 本身就是 FString
function nameBoth(ps, off) {
  const a = tryRead(ps, p => readFString(rd(p.add(off))));        // 先解引用
  const b = tryRead(ps, p => readFString(p.add(off)));            // 内联
  return { deref: a, inline: b };
}

function posOf(actor) {
  return tryRead(actor, a => {
    const root = rd(a.add(OFF.ActorRoot));
    if (!ok(root)) return null;
    const p = root.add(0x220);
    const x = p.readFloat(), y = p.add(4).readFloat(), z = p.add(8).readFloat();
    if (!isFinite(x) || Math.abs(x) > 1e7) return null;
    return [Math.round(x), Math.round(y), Math.round(z)];
  });
}

function main() {
  const mod = Process.findModuleByName('DeltaForceClient') ||
              Process.enumerateModules().find(m => m.name.indexOf('DeltaForce') >= 0);
  if (!mod) { send({ error: 'module' }); return; }
  const gw = mod.base.add(OFF.GWorld).readPointer();
  if (!ok(gw)) { send({ error: 'gworld' }); return; }

  const gi = rd(gw.add(OFF.WorldGameInstance));
  let pawn = null;
  if (ok(gi)) {
    const lps = rd(gi.add(OFF.GameInstanceLocalPlayers));
    if (ok(lps)) {
      const lp = rd(lps);
      if (ok(lp)) {
        const pc = rd(lp.add(OFF.LocalPlayerController));
        if (ok(pc)) pawn = rd(pc.add(OFF.ControllerPawn));
      }
    }
  }
  const self = pawn ? pawn.toString() : null;

  const level = rd(gw.add(OFF.WorldPersistentLevel));
  const data = level ? rd(level.add(0x98)) : null;
  const num = level ? level.add(0xA0).readS32() : 0;
  if (!ok(data) || !num) { send({ error: 'level' }); return; }

  const players = [];
  for (let i = 0; i < num && i < 4000; i++) {
    const a = rd(data.add(i * 8));
    if (!ok(a)) continue;
    // 判据改成「有 Mesh 且骨骼数合理」——人机没有 PlayerState，按 PlayerState 筛会漏掉它们
    const mesh0 = rd(a.add(OFF.CharacterMesh));
    if (!ok(mesh0)) continue;
    const bd0 = rd(mesh0.add(OFF.MeshBones));
    if (!ok(bd0)) continue;
    const bn0 = tryRead(mesh0, m => m.add(OFF.MeshBones + 8).readS32());
    if (!bn0 || bn0 < 20 || bn0 > 300) continue;
    const ps = rd(a.add(OFF.ActorPlayerState));

    const rec = { i: i, actor: a.toString(), ps: ps.toString(),
                  self: (self && a.toString() === self) };

    rec.pos = posOf(a);
    rec.uin = tryRead(ps, p => p.add(OFF.PS_UIN).readU64().toString());
    rec.names = nameBoth(ps, OFF.PS_Name);
    rec.ai32 = tryRead(ps, p => p.add(OFF.PS_AI).readS32());
    rec.ai8  = tryRead(ps, p => p.add(OFF.PS_AI).readU8());

    const tc = rd(a.add(OFF.ActorTeamComp));
    if (ok(tc)) rec.team = tryRead(tc, t => t.add(OFF.TeamCompTeamID).readS32());

    const mesh = rd(a.add(OFF.CharacterMesh));
    if (ok(mesh)) {
      const bd = rd(mesh.add(OFF.MeshBones));
      const bn = bd ? tryRead(mesh, m => m.add(OFF.MeshBones + 8).readS32()) : 0;
      rec.bones = bn || 0;
      if (bn && bn > 20) {
        const arr = ptr(bd.toString());
        const IDX = [32,30,5,3,2,1,6,7,8,34,35,36,58,59,60,62,63,64,0];
        const zs = [];
        for (const k of IDX) {
          try { zs.push(Math.round(arr.add(k * 0x30 + 0x10 + 8).readFloat())); }
          catch (e) { zs.push(null); }
        }
        rec.boneZ = zs;
      }
    }

    const cc = rd(a.add(OFF.ActorCombatComp));
    if (ok(cc)) {
      const w = rd(cc.add(OFF.CombatWeapon));
      if (ok(w)) {
        rec.weaponObj = w.toString();
        rec.weaponId = tryRead(w, x => x.add(OFF.WeaponIdField).readU64().toString());
      }
    }
    players.push(rec);
  }
  send({ stage: 'players', self: self, count: players.length, data: players });
}

setTimeout(main, 500);
