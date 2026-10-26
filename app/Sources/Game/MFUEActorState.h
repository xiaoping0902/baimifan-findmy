#pragma once
#include "MFUEPlayerData.h"

namespace MFUEActorState {
template <typename ReadBytes>
bool IsSpectatorOrInactive(uint64_t playerState, ReadBytes read) {
    uint8_t flags = 0;
    // APlayerState is the base of ABasePlayerState / AGPPlayerState.
    // bIsSpectator=bit1, bOnlySpectator=bit2, bIsInactive=bit5 at +0x39E.
    // AGPPlayerState+0x4C0 is bFinishGame, a separate replicated flag.
    return MFUEPlayerData::ValidPointer(playerState) &&
        read(playerState + 0x39E, &flags, sizeof(flags)) && (flags & 0x26);
}
}
