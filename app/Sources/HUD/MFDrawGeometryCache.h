#pragma once
#include "imgui.h"
#include <algorithm>
#include <cmath>
#include <vector>

// Cache completed category geometry between its updates. Every display frame
// still contains the whole scene; font-atlas replacement invalidates old UVs.
class MFDrawGeometryCache {
    struct Batch {
        ImVec4 clip;
        ImTextureRef texture;
        std::vector<ImDrawVert> vertices;
    };
    std::vector<Batch> batches;
    ImGuiContext *context = nullptr;
    ImTextureData *atlas = nullptr;
    int atlasID = 0, atlasWidth = 0, atlasHeight = 0, frame = -1;
    double updatedAt = -1.0;
public:
    void clear() { batches.clear(); context = nullptr; atlas = nullptr; updatedAt = -1.0; }
    bool due(double now, double hz) const {
        ImFontAtlas *fonts = ImGui::GetIO().Fonts;
        ImTextureData *current = fonts->TexData;
        return context != ImGui::GetCurrentContext() || !current || atlas != current ||
            atlasID != current->UniqueID || atlasWidth != current->Width || atlasHeight != current->Height ||
            ImGui::GetFrameCount() < frame || updatedAt < 0 || !std::isfinite(now) || now < updatedAt ||
            now - updatedAt + 1.0e-6 >= 1.0 / hz;
    }
    void capture(const ImDrawList *list, int firstIndex, double now) {
        batches.clear();
        for (const ImDrawCmd &cmd : list->CmdBuffer) {
            const unsigned int first = std::max((unsigned int)firstIndex, cmd.IdxOffset);
            const unsigned int end = cmd.IdxOffset + cmd.ElemCount;
            if (first >= end || cmd.UserCallback) continue;
            Batch batch{cmd.ClipRect, cmd.TexRef, {}};
            batch.vertices.reserve(end - first);
            for (unsigned int i = first; i < end; ++i)
                batch.vertices.push_back(list->VtxBuffer[cmd.VtxOffset + list->IdxBuffer[i]]);
            batches.push_back(std::move(batch));
        }
        context = ImGui::GetCurrentContext();
        atlas = ImGui::GetIO().Fonts->TexData;
        atlasID = atlas ? atlas->UniqueID : 0;
        atlasWidth = atlas ? atlas->Width : 0;
        atlasHeight = atlas ? atlas->Height : 0;
        frame = ImGui::GetFrameCount();
        updatedAt = now;
    }
    void append(ImDrawList *list) const {
        for (const Batch &batch : batches) {
            list->PushClipRect(ImVec2(batch.clip.x, batch.clip.y), ImVec2(batch.clip.z, batch.clip.w), true);
            list->PushTexture(batch.texture);
            // Stay below the 16-bit index limit, including large loot scenes.
            for (size_t first = 0; first < batch.vertices.size();) {
                const int count = (int)std::min<size_t>(60000, batch.vertices.size() - first);
                list->PrimReserve(count, count);
                for (int i = 0; i < count; ++i) {
                    const ImDrawVert &v = batch.vertices[first + i];
                    list->PrimWriteIdx((ImDrawIdx)list->_VtxCurrentIdx);
                    list->PrimWriteVtx(v.pos, v.uv, v.col);
                }
                first += count;
            }
            list->PopTexture();
            list->PopClipRect();
        }
    }
};
