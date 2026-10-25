// frida_probe.js — 三角洲训练场数据探针（JSON 版）
//
// 旧的 console.log("%d/%s") 在 Frida 里不做替换，输出是裸数字串；这一版全部
// 走 send({...})，Python 侧直接 json.dumps，字段一一对应。
//
// 用法：
//   frida -H 127.0.0.1:27042 -n 三角洲行动 -l frida_probe.js
//   或者由 frida_hold.py 每轮 create_script 加载。

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
  SceneComponentWorld: 0x220,   // ComponentToWorld.Translation
  ActorClassPrivate: 0x10,
  ActorFlagsHidden: 0x90,       // bHidden bit0
  ActorFlagsDead: 0x95,         // bActorIsBeingDestroyed bit1
  CharacterMesh: 0x3D0,
  MeshBoneArray: 0x0A18,
  PawnTeamComp: 0x10C0,
  TeamCompTeamID: 0x108,
  PawnIsPlayerAI: 0x0E60,
  PawnWeapon: 0x1170,
  RangeHelmetID: 0x3890,
  RangeArmorID: 0x3898,
};

function posOf(actor) {
  try {
    const root = actor.add(OFF.ActorRootComponent).readPointer();
    if (root.isNull()) return null;
    const p = root.add(OFF.SceneComponentWorld);
    const x = p.readFloat(), y = p.add(4).readFloat(), z = p.add(8).readFloat();
    if (!isFinite(x) || !isFinite(y) || !isFinite(z)) return null;
    if (Math.abs(x) > 1e7) return null;
    return [Math.round(x), Math.round(y), Math.round(z)];
  } catch (e) { return null; }
}

function main() {
  const mod = Process.findModuleByName('DeltaForceClient') ||
              Process.enumerateModules().find(m => m.name.indexOf('DeltaForce') >= 0);
  if (!mod) { send({ stage: 'module', error: 'not found' }); return; }

  const base = mod.base;
  const gw = base.add(OFF.GWorld).readPointer();
  send({ stage: 'world', base: base.toString(), gworld: gw.toString() });
  if (gw.isNull()) return;

  const gi = gw.add(OFF.WorldGameInstance).readPointer();
  let pc = null, pawn = null;
  if (!gi.isNull()) {
    const lps = gi.add(OFF.GameInstanceLocalPlayers).readPointer();
    if (!lps.isNull()) {
      const lp = lps.readPointer();
      if (!lp.isNull()) pc = lp.add(OFF.LocalPlayerController).readPointer();
    }
  }
  if (pc && !pc.isNull()) pawn = pc.add(OFF.ControllerPawn).readPointer();

  const local = { gameInstance: gi.toString(), controller: pc ? pc.toString() : null,
                  pawn: pawn ? pawn.toString() : null };
  if (pawn && !pawn.isNull()) {
    local.pos = posOf(pawn);
    const tc = pawn.add(OFF.PawnTeamComp).readPointer();
    local.team = tc.isNull() ? null : tc.add(OFF.TeamCompTeamID).readS32();
    local.ai = pawn.add(OFF.PawnIsPlayerAI).readU8();
    const mesh = pawn.add(OFF.CharacterMesh).readPointer();
    local.mesh = mesh.toString();
    if (!mesh.isNull()) {
      const bd = mesh.add(OFF.MeshBoneArray).readPointer();
      local.boneData = bd.toString();
      local.boneNum = bd.isNull() ? 0 : mesh.add(OFF.MeshBoneArray + 8).readS32();
    }
    const wp = pawn.add(OFF.PawnWeapon).readPointer();
    local.weapon = wp.toString();
  }
  send({ stage: 'local', data: local });

  const level = gw.add(OFF.WorldPersistentLevel).readPointer();
  if (level.isNull()) { send({ stage: 'actors', error: 'no level' }); return; }
  const data = level.add(OFF.LevelActorsData).readPointer();
  const num = level.add(OFF.LevelActorsNum).readS32();
  send({ stage: 'level', level: level.toString(), actorData: data.toString(), num: num });
  if (data.isNull() || !num || num <= 0 || num > 20000) return;

  const list = [];
  for (let i = 0; i < num && list.length < 60; i++) {
    let actor;
    try { actor = data.add(i * 8).readPointer(); } catch (e) { continue; }
    if (actor.isNull()) continue;

    const p = posOf(actor);
    if (!p) continue;

    const rec = { i: i, actor: actor.toString(), pos: p };
    try { rec.cls = actor.add(OFF.ActorClassPrivate).readPointer().toString(); } catch (e) {}
    rec.hidden = actor.add(OFF.ActorFlagsHidden).readU8();
    rec.dead   = actor.add(OFF.ActorFlagsDead).readU8();

    const mesh = actor.add(OFF.CharacterMesh).readPointer();
    if (!mesh.isNull()) {
      rec.mesh = mesh.toString();
      const bd = mesh.add(OFF.MeshBoneArray).readPointer();
      rec.boneNum = bd.isNull() ? 0 : mesh.add(OFF.MeshBoneArray + 8).readS32();
    }
    const tc = actor.add(OFF.PawnTeamComp).readPointer();
    if (!tc.isNull()) rec.team = tc.add(OFF.TeamCompTeamID).readS32();
    rec.ai = actor.add(OFF.PawnIsPlayerAI).readU8();
    try { rec.helm = actor.add(OFF.RangeHelmetID).readPointer().toString(); } catch (e) {}
    try { rec.armor = actor.add(OFF.RangeArmorID).readPointer().toString(); } catch (e) {}
    list.push(rec);
  }
  send({ stage: 'actors', data: list });
}

setTimeout(main, 500);
