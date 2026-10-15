#pragma once
#include "imgui.h"
#include "imgui_internal.h"

// A cancellation must not look like a normal release over a Checkbox/Button.
inline void MFCancelImGuiTouch() {
    ImGui::ClearActiveID();
    ImGuiIO &io = ImGui::GetIO();
    io.ClearEventsQueue();
    io.ClearInputMouse();
}
