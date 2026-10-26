#pragma once
#include <cstdint>
#include <initializer_list>
#include <string>

namespace MFNPCNames {
inline const char *SpecialName(const char *name) {
    if (!name || !*name) return nullptr;
    struct Entry { const char *alias; const char *label; };
    static const Entry names[] = {
        {u8"赛伊德",u8"[卫队长官]赛伊德"}, {u8"[卫队长官]赛伊德",u8"[卫队长官]赛伊德"},
        {u8"雷斯",u8"[地域黑鲨]雷斯"}, {u8"[地域黑鲨]雷斯",u8"[地域黑鲨]雷斯"},
        {u8"[地狱黑鲨]雷斯",u8"[地域黑鲨]雷斯"},
        {u8"德穆兰",u8"[安全总监]德穆兰"}, {u8"[安全总监]德穆兰",u8"[安全总监]德穆兰"},
        {u8"渡鸦",u8"[堕落王子]渡鸦"}, {u8"[堕落王子]渡鸦",u8"[堕落王子]渡鸦"},
        {u8"哈德森",u8"[效能部长]哈德森"}, {u8"[效能部长]哈德森",u8"[效能部长]哈德森"},
        {u8"加速部队特勤组",u8"加速部队特勤组"}, {u8"哈夫克支援战车",u8"哈夫克支援战车"},
        {u8"阿萨拉死囚",u8"阿萨拉死囚"}, {u8"哈夫克自动战车",u8"哈夫克自动战车"},
        {u8"盾兵",u8"盾兵"}
    };
    for (const auto &entry : names) if (std::string(name) == entry.alias) return entry.label;
    return nullptr;
}

// SDK GPGameplay.EAICharacterTag. These are role labels, never guessed IDs.
inline const char *RoleName(uint32_t tags) {
    for (uint8_t tag : {uint8_t(18),uint8_t(4),uint8_t(21),uint8_t(8),uint8_t(9),
                        uint8_t(5),uint8_t(10),uint8_t(3),uint8_t(6),uint8_t(7),uint8_t(1)}) {
        if (!(tags & (1u << tag))) continue;
        switch (tag) {
            case 18: case 4: return u8"盾兵";
            case 21: return u8"核清除者";
            case 8: return u8"喷火兵";
            case 9: return u8"RPG兵";
            case 5: return u8"重甲兵";
            case 10: return u8"首领";
            case 3: return u8"狙击兵";
            case 6: return u8"伞兵";
            case 7: return u8"近战兵";
            case 1: return u8"精英兵";
        }
    }
    return nullptr;
}

inline std::string Resolve(bool isBot, std::initializer_list<const char *> candidates, uint32_t tags = 0,
                           const char *localizedTemplateName = nullptr) {
    if (!isBot) return {};
    for (const char *name : candidates) if (const char *known = SpecialName(name)) return known;
    if (const char *role = RoleName(tags)) {
        // A validated NPC template supplies its localized role-specific name.
        return localizedTemplateName && *localizedTemplateName ? localizedTemplateName : role;
    }
    if (const char *known = SpecialName(localizedTemplateName)) return known;
    return u8"人机";
}
}
