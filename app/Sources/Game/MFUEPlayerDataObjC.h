#pragma once
#import "MFGameReader.h"
#import "../Read/MFReadBackend.h"
#include "MFUEPlayerData.h"
#include "MFUEDataTable.h"
#include "MFUEHeading.h"
#include "MFHeldWeapons.h"
#include "MFHeroNames.h"
#include "MFNPCNames.h"
#import "MFUEReader.h"
#import "MFUEGNames.h"

static inline NSString *MFResolveUEHeroName(uint64_t expertID, NSString *localized) {
    const char *name = MFHeroNames::Resolve(expertID, localized.UTF8String);
    return name ? [NSString stringWithUTF8String:name] : nil;
}

static inline NSString *MFReadUEHeroName(MFReadBackend *reader, uint64_t heroID, uint64_t expertID) {
    if (!heroID) return MFResolveUEHeroName(expertID, nil);
    static NSMutableDictionary<NSNumber *, NSString *> *names;
    static uint64_t cachedBase = 0;
    static uint64_t cachedTask = 0;
    static CFAbsoluteTime retryAt = 0;
    const uint64_t base = [MFUEReader shared].libBase;
    @synchronized (MFUEReader.class) {
        if (!names || cachedBase != base || cachedTask != [MFReadBackend shared].sessionToken) {
            names = [NSMutableDictionary dictionary];
            cachedBase = base; cachedTask = [MFReadBackend shared].sessionToken; retryAt = 0;
        }
        if (names[@(heroID)]) return names[@(heroID)];
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!base || (retryAt > 0 && now - retryAt < 5.0)) return MFResolveUEHeroName(expertID, nil);
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
        return MFResolveUEHeroName(expertID, names[@(heroID)]);
    }
}

static inline void MFFillUEHeroAttributes(MFReadBackend *reader, uint64_t actor, NSMutableDictionary *attributes) {
    const auto read = [reader](uint64_t address, void *out, size_t size) {
        return (bool)[reader readRemote:address into:out size:size];
    };
    const uint64_t heroID = MFUEPlayerData::ReadHeroID(actor, read);
    const uint64_t expertID = MFUEPlayerData::ReadExpertID(actor, read);
    attributes[@"heroID"] = @(heroID);
    attributes[@"expertID"] = @(expertID);
    NSString *name = MFReadUEHeroName(reader, heroID, expertID);
    if (name.length) attributes[@"heroName"] = name;
}

static inline void MFApplyUEHeroAttributes(MFEntity *entity, NSDictionary *attributes) {
    entity.heroID = [attributes[@"heroID"] unsignedLongLongValue];
    entity.expertID = [attributes[@"expertID"] unsignedLongLongValue];
    entity.heroName = attributes[@"heroName"];
    entity.isBot = MFHeroNames::UsesBotHUD(entity.isBot, entity.expertID);
}

static inline NSString *MFNPCString(const std::u16string &text) {
    if (text.empty()) return nil;
    NSString *name = [NSString stringWithCharacters:(const unichar *)text.data() length:text.size()];
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static inline NSString *MFReadUENPCTemplateName(MFReadBackend *reader, const MFUEPlayerData::NPCIdentity &npc) {
    if (!npc.templateTable || !npc.npcIndex) return nil;
    const uint64_t base = [MFUEReader shared].libBase;
    if (!base) return nil;
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static uint64_t cachedBase = 0;
    static uint64_t cachedTask = 0;
    @synchronized (MFUEReader.class) {
        if (!cache || cachedBase != base || cachedTask != [MFReadBackend shared].sessionToken) {
            cache = [NSMutableDictionary dictionary]; cachedBase = base; cachedTask = [MFReadBackend shared].sessionToken;
        }
        NSString *key = [NSString stringWithFormat:@"%llx:%u:%u", (unsigned long long)npc.templateTable,
                         npc.npcIndex, npc.npcNumber];
        NSDictionary *entry = cache[key];
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (entry && (entry[@"name"] || now - [entry[@"t"] doubleValue] < 5)) return entry[@"name"];
        const auto read = [reader](uint64_t address, void *out, size_t size) {
            return (bool)[reader readRemote:address into:out size:size];
        };
        MFUEPlayerData::ArrayHeader header{};
        NSString *name = nil;
        // SDK AIInfo.NpcTemplateTable uses CharacterTemplateTable rows. Bound
        // the table before traversal and validate RowStruct against GObjects.
        if (read(npc.templateTable + 0x30, &header, sizeof(header)) && header.num > 0 && header.num <= 4096) {
            const uint64_t rowStruct = MFUEDataTable::ObjectAtIndex(base, 0x6AD9, read);
            for (const auto &row : MFUEDataTable::ReadRows(npc.templateTable, rowStruct, read)) {
                if (row.comparisonIndex != npc.npcIndex || row.number != npc.npcNumber) continue;
                name = MFNPCString(MFUEPlayerData::ReadFText(row.address + 0x38, read));
                break;
            }
        }
        if (cache.count > 512) [cache removeAllObjects];
        cache[key] = name.length ? @{@"t":@(now), @"name":name} : @{@"t":@(now)};
        return name;
    }
}

static inline void MFFillUENPCAttributes(MFReadBackend *reader, uint64_t actor, BOOL isBot,
                                        NSString *existingName, NSMutableDictionary *attributes) {
    if (!MFHeroNames::UsesBotHUD(isBot, [attributes[@"expertID"] unsignedLongLongValue])) return;
    static NSMutableDictionary<NSNumber *, NSDictionary *> *cache;
    static uint64_t cachedBase = 0;
    static uint64_t cachedTask = 0;
    const uint64_t base = [MFUEReader shared].libBase;
    @synchronized (MFUEReader.class) {
        if (!cache || cachedBase != base || cachedTask != [MFReadBackend shared].sessionToken) {
            cache = [NSMutableDictionary dictionary]; cachedBase = base; cachedTask = [MFReadBackend shared].sessionToken;
        }
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSDictionary *cached = cache[@(actor)];
        NSString *source = existingName ?: @"";
        if (cached && now - [cached[@"t"] doubleValue] < 1.0 && [cached[@"source"] isEqualToString:source]) {
            attributes[@"npcName"] = cached[@"name"]; return;
        }
        const auto read = [reader](uint64_t address, void *out, size_t size) {
            return (bool)[reader readRemote:address into:out size:size];
        };
        const bool aiSubclass = MFUEPlayerData::IsAICharacterClass(actor, read, [](uint64_t cls) {
            NSString *name = [[MFUEGNames shared] classNameForObject:cls];
            return std::string(name.UTF8String ?: "");
        });
        const auto npc = MFUEPlayerData::ReadNPCIdentity(actor, true, aiSubclass, read);
        NSString *chosen = MFNPCString(npc.chosenName), *chosenText = MFNPCString(npc.chosenText);
        NSString *character = npc.characterIndex ? [[MFUEGNames shared] classNameForID:(int32_t)npc.characterIndex] : nil;
        NSString *config = npc.npcIndex ? [[MFUEGNames shared] classNameForID:(int32_t)npc.npcIndex] : nil;
        NSString *localized = MFReadUENPCTemplateName(reader, npc);
        const auto display = MFNPCNames::Resolve(true,
            {existingName.UTF8String, chosen.UTF8String, chosenText.UTF8String, character.UTF8String, config.UTF8String},
            npc.tagMask, localized.UTF8String);
        NSString *name = [NSString stringWithUTF8String:display.c_str()];
        attributes[@"npcName"] = name;
        if (cache.count > 1024) [cache removeAllObjects];
        cache[@(actor)] = @{@"t":@(now), @"name":name, @"source":source};
    }
}

static inline void MFApplyUENPCAttributes(MFEntity *entity, NSDictionary *attributes) {
    entity.npcName = entity.isBot ? attributes[@"npcName"] : nil;
}

static inline BOOL MFIsUEBot(MFReadBackend *reader,uint64_t actor,uint32_t aiOffset=0xE60) {
    const auto read=[reader](uint64_t address,void *out,size_t size){
        return (bool)[reader readRemote:address into:out size:size];
    };
    if(MFUEPlayerData::ReadBotIdentity(actor,read,aiOffset))return YES;
    return MFUEPlayerData::IsAICharacterClass(actor,read,[](uint64_t cls){
        NSString *name=[[MFUEGNames shared]classNameForObject:cls];
        return std::string(name.UTF8String?:"");
    });
}

static inline void MFApplyUEHeading(MFEntity *entity, MFReadBackend *reader, uint32_t rootOffset) {
    static NSMutableDictionary<NSNumber *, NSDictionary *> *cache;
    static uint64_t cachedTask = 0;
    @synchronized (MFUEReader.class) {
        if (!cache || cachedTask != [MFReadBackend shared].sessionToken) {
            cache = [NSMutableDictionary dictionary]; cachedTask = [MFReadBackend shared].sessionToken;
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
