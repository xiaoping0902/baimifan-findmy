#pragma once
#import "MFGameReader.h"
#import "../Read/MFReadBackend.h"
#include "MFUEPlayerData.h"

static inline NSString *MFReadUEPlayerName(MFReadBackend *reader, uint64_t playerState) {
    const auto name = MFUEPlayerData::ReadName(playerState, [&](uint64_t address, void *out, size_t size) {
        return (bool)[reader readRemote:address into:out size:size];
    });
    if (name.empty()) return nil;
    NSString *result = [NSString stringWithCharacters:(const unichar *)name.data() length:name.size()];
    result = [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return result.length ? result : nil;
}

static inline BOOL MFIsUEFullyDead(MFReadBackend *reader, uint64_t actor) {
    return MFUEPlayerData::IsFullyDead(actor, [&](uint64_t address, void *out, size_t size) {
        return (bool)[reader readRemote:address into:out size:size];
    });
}

static inline void MFFillUEEquipmentAttributes(MFReadBackend *reader, uint64_t actor, NSMutableDictionary *attributes) {
    const auto gear = MFUEPlayerData::ReadEquipment(actor, [&](uint64_t address, void *out, size_t size) {
        return (bool)[reader readRemote:address into:out size:size];
    });
    [attributes addEntriesFromDictionary:@{
        @"equipKnown": @(gear.known),
        @"h": @(gear.head.level), @"a": @(gear.armor.level), @"b": @(gear.bag.level),
        @"hid": @(gear.head.rawID), @"aid": @(gear.armor.rawID), @"bid": @(gear.bag.rawID),
        @"hHP": @(gear.head.health), @"hMax": @(gear.head.maximum),
        @"aHP": @(gear.armor.health), @"aMax": @(gear.armor.maximum)
    }];
}

static inline void MFApplyUEEquipmentAttributes(MFEntity *entity, NSDictionary *attributes) {
    entity.helmetLevel = [attributes[@"h"] intValue];
    entity.armorLevel = [attributes[@"a"] intValue];
    entity.backpackLevel = [attributes[@"b"] intValue];
    entity.helmetRawID = [attributes[@"hid"] unsignedLongLongValue];
    entity.armorRawID = [attributes[@"aid"] unsignedLongLongValue];
    entity.bagRawID = [attributes[@"bid"] unsignedLongLongValue];
    entity.equipRawID = entity.helmetRawID ?: (entity.armorRawID ?: entity.bagRawID);
    entity.helmetHP = [attributes[@"hHP"] floatValue];
    entity.helmetMaxHP = [attributes[@"hMax"] floatValue];
    entity.armorHP = [attributes[@"aHP"] floatValue];
    entity.armorMaxHP = [attributes[@"aMax"] floatValue];
    entity.equipKnown = [attributes[@"equipKnown"] boolValue];
    entity.armorKnown = entity.equipKnown || entity.armorRawID != 0;
}
