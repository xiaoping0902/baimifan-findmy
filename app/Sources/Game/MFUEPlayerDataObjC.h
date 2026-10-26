#pragma once
#import "MFGameReader.h"
#import "../Read/MFReadBackend.h"
#include "MFUEPlayerData.h"
#include "MFUEDataTable.h"
#include "MFUEHeading.h"
#include "MFHeldWeapons.h"
#include "MFHeroNames.h"
#import "MFUEReader.h"
#import "MFUEGNames.h"

static inline NSString *MFResolveUEHeroName(uint64_t heroID, NSString *localized) {
    const char *name = MFHeroNames::Resolve(heroID, localized.UTF8String);
    return name ? [NSString stringWithUTF8String:name] : nil;
}

static inline NSString *MFReadUEHeroName(MFReadBackend *reader, uint64_t heroID) {
    if (!heroID) return nil;
    static NSMutableDictionary<NSNumber *, NSString *> *names;
    static uint64_t cachedBase = 0;
    static uint32_t cachedTask = 0;
    static CFAbsoluteTime retryAt = 0;
    const uint64_t base = [MFUEReader shared].libBase;
    @synchronized (MFUEReader.class) {
        if (!names || cachedBase != base || cachedTask != reader.targetTaskPort) {
            names = [NSMutableDictionary dictionary];
            cachedBase = base; cachedTask = reader.targetTaskPort; retryAt = 0;
        }
        if (names[@(heroID)]) return names[@(heroID)];
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!base || (retryAt > 0 && now - retryAt < 5.0)) return MFResolveUEHeroName(heroID, nil);
        retryAt = now;
        const auto read = [reader](uint64_t address, void *out, size_t size) {
            return (bool)[reader readRemote:address into:out size:size];
        };
        // SDK GObjects: HeroData.HeroData and DFMGlobalDefines.HeroDataRow.
        const uint64_t table = MFUEDataTable::ObjectAtIndex(base, 0x1B604, read);
        const uint64_t rowStruct = MFUEDataTable::ObjectAtIndex(base, 0x717E, read);
        for (const auto &row : MFUEDataTable::ReadRows(table, rowStruct, read)) {
            uint32_t heroFName = 0;
            if (!read(row.address + 0x10, &heroFName, 4)) continue;
            NSString *idName = [[MFUEGNames shared] classNameForID:(int32_t)heroFName];
            uint64_t id = MFUEDataTable::NumericID(idName.UTF8String);
            if (!id) {
                idName = [[MFUEGNames shared] classNameForID:(int32_t)row.comparisonIndex];
                id = MFUEDataTable::NumericID(idName.UTF8String);
            }
            const auto text = MFUEPlayerData::ReadFText(row.address + 0x18, read);
            if (!id || text.empty()) continue;
            NSString *name = [NSString stringWithCharacters:(const unichar *)text.data() length:text.size()];
            name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (name.length) names[@(id)] = name;
        }
        return MFResolveUEHeroName(heroID, names[@(heroID)]);
    }
}

static inline void MFFillUEHeroAttributes(MFReadBackend *reader, uint64_t actor, NSMutableDictionary *attributes) {
    const uint64_t heroID = MFUEPlayerData::ReadHeroID(actor, [reader](uint64_t address, void *out, size_t size) {
        return (bool)[reader readRemote:address into:out size:size];
    });
    attributes[@"heroID"] = @(heroID);
    NSString *name = MFReadUEHeroName(reader, heroID);
    if (name.length) attributes[@"heroName"] = name;
}

static inline void MFApplyUEHeroAttributes(MFEntity *entity, NSDictionary *attributes) {
    entity.heroID = [attributes[@"heroID"] unsignedLongLongValue];
    entity.heroName = attributes[@"heroName"];
}

static inline void MFApplyUEHeading(MFEntity *entity, MFReadBackend *reader, uint32_t rootOffset) {
    static NSMutableDictionary<NSNumber *, NSDictionary *> *cache;
    static uint32_t cachedTask = 0;
    @synchronized (MFUEReader.class) {
        if (!cache || cachedTask != reader.targetTaskPort) {
            cache = [NSMutableDictionary dictionary]; cachedTask = reader.targetTaskPort;
        }
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSNumber *key = @(entity.address);
        NSDictionary *sample = cache[key];
        if (!sample || now - [sample[@"t"] doubleValue] >= 1.0 / 15.0) {
            const float world[3] = {entity.worldX, entity.worldY, entity.worldZ};
            const float yaw = MFUEHeading::Read(entity.address, world, [reader](uint64_t address, void *out, size_t size) {
                return (bool)[reader readRemote:address into:out size:size];
            }, rootOffset);
            sample = @{@"t": @(now), @"yaw": @(yaw)};
            if (cache.count > 1024) [cache removeAllObjects];
            cache[key] = sample;
        }
        entity.yawDeg = now - [sample[@"t"] doubleValue] <= 0.20 ? [sample[@"yaw"] floatValue] : NAN;
    }
}

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
    entity.helmetHP = attributes[@"hHP"] ? [attributes[@"hHP"] floatValue] : NAN;
    entity.helmetMaxHP = attributes[@"hMax"] ? [attributes[@"hMax"] floatValue] : NAN;
    entity.armorHP = attributes[@"aHP"] ? [attributes[@"aHP"] floatValue] : NAN;
    entity.armorMaxHP = attributes[@"aMax"] ? [attributes[@"aMax"] floatValue] : NAN;
    entity.equipKnown = [attributes[@"equipKnown"] boolValue];
    entity.armorKnown = entity.equipKnown || entity.armorRawID != 0;
}
