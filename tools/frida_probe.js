// frida_probe.js — 三角洲训练场数据探针（配合 Frida-iPad-Memory-Guide.md）
//
// 用法（Windows，iPad 越狱 + frida-server 已起、27042 已转发）：
//   frida -H 127.0.0.1:27042 -n DeltaForceClient -l frida_probe.js
//
// 输出：本地玩家链、队伍、手持武器候选、以及 Actors 里每个角色的
//       坐标 / 队伍 / 人机标志 / Mesh / 骨数。
// 所有偏移取自 SDK 1.201.37117 与本仓库 MFUEOffsets.h。

const OFF = {
  GWorld: 0x178B44E0,
  WorldGameInstance: 0x190,
  WorldPersistentLevel: 0xF8,
  GameInstanceLocalPlayers: 0x38,
  LocalPlayerController: 0x30,
  ControllerPawn: 0x3A0,
  ControllerCameraManager: 0x408,
  LevelActorsData: 0x98,
  LevelActorsNum: 0xA0,
  ActorRootComponent: 0x180,
  SceneComponentLocation: 0x220,   // ComponentToWorld.Translation
  CharacterMesh: 0x3D0,
  MeshBoneArray: 0x0A18,           // TArray<FTransform> CachedComponentSpaceTransforms
  MeshC2W: 0x210,
  PawnTeamComp: 0x10C0,
  TeamCompTeamID: 0x108,
  PawnIsPlayerAI: 0x0E60,
  ControllerWeaponCandidates: [0x1170, 0x1158, 0x3540],
  ActorHiddenByte: 0x90,
  ActorDestroyedByte: 0x95,
};

function u64(p) { try { return p.readU64(); } catch (e) { return null; } }
function u32(p) { try { return p.readU32(); } catch (e) { return null; } }
function i32(p) { try { return p.readS32(); } catch (e) { return null; } }
function f32(p) { try { return p.readFloat(); } catch (e) { return null; } }
function u8(p)  { try { return p.readU8(); } catch (e) { return null; } }

function pos(actor) {
  const root = u64(actor.add(OFF.ActorRootComponent));
  if (!root || root < 0x10000) return null;
  const p = ptr(root).add(OFF.SceneComponentLocation);
  const x = f32(p), y = f32(p.add(4)), z = f32(p.add(8));
  if (x === null || y === null || z === null) return null;
  if (!isFinite(x) || Math.abs(x) > 1e7) return null;
  return [x, y, z];
}

function main() {
  const mod = Process.findModuleByName('DeltaForceClient') ||
              Process.enumerateModules().find(m => m.name.indexOf('DeltaForce') >= 0);
  if (!mod) { console.log('[-] 找不到 DeltaForceClient 模块'); return; }
  const base = mod.base;
  console.log('[+] base =', base);

  const gw = u64(base.add(OFF.GWorld));
  console.log('[+] GWorld =', gw);
  if (!gw) return;

  const gi = u64(ptr(gw).add(OFF.WorldGameInstance));
  const lp = gi ? u64(ptr(gi).add(OFF.GameInstanceLocalPlayers)) : null;
  const localPlayer = lp ? u64(ptr(lp)) : null;
  const pc = localPlayer ? u64(ptr(localPlayer).add(OFF.LocalPlayerController)) : null;
  const pawn = pc ? u64(ptr(pc).add(OFF.ControllerPawn)) : null;
  console.log('[+] GameInstance=%s LocalPlayer=%s Controller=%s Pawn=%s', gi, localPlayer, pc, pawn);

  if (pawn) {
    const pp = pos(ptr(pawn));
    const teamComp = u64(ptr(pawn).add(OFF.PawnTeamComp));
    const teamID = teamComp ? i32(ptr(teamComp).add(OFF.TeamCompTeamID)) : null;
    const ai = u8(ptr(pawn).add(OFF.PawnIsPlayerAI));
    const mesh = u64(ptr(pawn).add(OFF.CharacterMesh));
    console.log('[本地] pos=%j team=%s ai=%s mesh=%s', pp, teamID, ai, mesh);

    for (const off of OFF.ControllerWeaponCandidates) {
      const w = u64(ptr(pc).add(off));
      if (w && w > 0x10000) console.log('[武器候选] Controller+0x%s -> %s', off.toString(16), w);
      const w2 = u64(ptr(pawn).add(off));
      if (w2 && w2 > 0x10000) console.log('[武器候选] Pawn+0x%s -> %s', off.toString(16), w2);
    }
  }

  const level = u64(ptr(gw).add(OFF.WorldPersistentLevel));
  const data = level ? u64(ptr(level).add(OFF.LevelActorsData)) : null;
  const num = level ? i32(ptr(level).add(OFF.LevelActorsNum)) : 0;
  console.log('[+] Level=%s actorsData=%s num=%s', level, data, num);
  if (!data || !num || num <= 0 || num > 20000) return;

  let shown = 0;
  for (let i = 0; i < num && shown < 40; i++) {
    const actor = u64(ptr(data).add(i * 8));
    if (!actor || actor < 0x10000) continue;

    const a = ptr(actor);
    const hidden = u8(a.add(OFF.ActorHiddenByte));
    const destroyed = u8(a.add(OFF.ActorDestroyedByte));
    const p = pos(a);
    if (!p) continue;

    const mesh = u64(a.add(OFF.CharacterMesh));
    let boneNum = 0, boneData = 0;
    if (mesh && mesh > 0x10000) {
      boneData = u64(ptr(mesh).add(OFF.MeshBoneArray));
      boneNum = i32(ptr(mesh).add(OFF.MeshBoneArray + 8)) || 0;
    }
    const teamComp = u64(a.add(OFF.PawnTeamComp));
    const team = teamComp ? i32(ptr(teamComp).add(OFF.TeamCompTeamID)) : null;
    const ai = u8(a.add(OFF.PawnIsPlayerAI));

    const self = (pawn && actor === pawn) ? ' <== 自己' : '';
    console.log('#%d actor=%s pos=[%s] team=%s ai=%s hidden=%s dead=%d mesh=%s bones=%d%s',
      i, actor, p.map(v => v.toFixed(0)).join(','), team, ai, hidden, destroyed, mesh, boneNum, self);
    shown++;
  }
}

setTimeout(main, 800);
