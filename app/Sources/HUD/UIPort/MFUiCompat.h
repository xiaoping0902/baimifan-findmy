#pragma once
/*
 * MFUiCompat.h —— 让小玉原版 UI（ui.h / ios_ui.h / ios_pages.h）原样编译的替身层。
 *
 * 原文件依赖 aim_assist.h / mortar_math.h 里的枚举、AimSettings、上限常量。
 * 本工程目前没有自瞄/追踪实现，所以这里给出**字段与默认值完全一致**的结构体：
 * 面板可以正常显示、拖动、保存，但「自瞄 / 追踪」两组开关暂时只改状态、不产生行为。
 *
 * 枚举顺序对齐原版用法（pages 里按 int(point) 索引「头部/胸部/动态」等标签）。
 */
#include "imgui.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>

/* ── 原 aim_assist.h 的枚举 ───────────────────────────── */
enum class AimTriggerMode : int { Fire = 0, Ads = 1, FireOrAds = 2 };
enum class AimPointMode : int { Head = 0, Chest = 1, Dynamic = 2 };
enum class AimTargetMode : int { All = 0, Human = 1 };
enum class AimTrackingPointMode : int { Head = 0, Chest = 1, Random = 2 };
enum class AimVisibility : unsigned char { Visible = 0, Hidden = 1 };
enum class AimScopeTier : int { Hip = 0, Reflex = 1, Scope2x = 2, Scope3x = 3, Scope4x = 4, Scope6x = 5, Scope8x = 6 };

/* ── 原 aim_assist.h 的上限常量（值取自原文件）─────────── */
inline constexpr float kAimStrengthMaximum = 3.0f;
inline constexpr float kAimScopeSensitivityMaximum = 3.0f;
inline constexpr float kAimLockSpeedMaximum = 3.0f;
inline constexpr float kAimRecoilStrengthMaximum = 5.0f;

/* ── 原 mortar_math.h 的常量 ──────────────────────────── */
static constexpr float kMortarHipMaximumM = 163.0f;
static constexpr float kMortarAdsMaximumM = 391.0f;
static constexpr float kMortarGravityMps2 = 9.8f;
static const float kMortarAdsSpeedMps =
    std::sqrt(kMortarAdsMaximumM * kMortarGravityMps2);

/* ── 原 aim_assist.h 的 AimSettings（字段/默认值照抄）──── */
struct AimSettings
{
    bool enabled = false;
    AimTriggerMode trigger = AimTriggerMode::Fire;
    AimPointMode point = AimPointMode::Dynamic;
    AimTargetMode target = AimTargetMode::All;
    float fovScale = 0.16f;
    float maxDistanceM = 300.0f;
    float prediction = 0.35f;
    bool predictionEnabled = true;
    bool visibleOnly = true;
    bool ignoreDowned = true;
    bool drawFov = true;
    bool stableLock = true;
    bool recoilCompensation = true;
    float gyroStrength = 0.50f;
    float recoilStrength = 0.30f;
    float lockSpeed = 1.00f;
    float nearDamping = 0.70f;
    float gyroHipSensitivity = 0.80f;
    float gyroReflexSensitivity = 1.00f;
    float gyro2xSensitivity = 1.00f;
    float gyro3xSensitivity = 1.00f;
    float gyro4xSensitivity = 1.00f;
    float gyro6xSensitivity = 1.00f;
    float gyro8xSensitivity = 1.00f;
    float recoilScopeScale[7] = {1.00f, 1.00f, 1.15f, 1.35f, 1.60f, 1.90f, 2.20f};
    bool trackingEnabled = true;
    bool singleShotTracking = true;
    bool explosiveBowTracking = true;
    bool rifleTracking = true;
    bool pursuitCannonTracking = true;
    float singleShotTrackingProbability = 0.75f;
    float rifleTrackingProbability = 0.55f;
    float singleShotTrackingDistanceM = 220.0f;
    float rifleTrackingDistanceM = 160.0f;
    float singleShotTrackingFovScale = 0.14f;
    float rifleTrackingFovScale = 0.12f;
    AimTrackingPointMode singleShotTrackingPoint = AimTrackingPointMode::Head;
    AimTrackingPointMode rifleTrackingPoint = AimTrackingPointMode::Head;
    bool trackingIgnoreBots = false;
    bool humanize = false;
    float hipAimMaxDistanceM = 50.0f;
    float hipTrackMaxDistanceM = 50.0f;
};

/* ── 原 font_chars_generated.h（kGeneratedFontChars）───── */
#include "MFUiFontChars.h"
