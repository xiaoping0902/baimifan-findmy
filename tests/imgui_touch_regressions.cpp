#include "MFImGuiInput.h"
#include <cstdio>
#include <cstdlib>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)
static bool checked;
static ImVec2 target;
static void Frame() {
    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(348, 520));
    ImGui::Begin("Touch test", nullptr, ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoTitleBar);
    ImGui::Checkbox("Toggle", &checked);
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    target = ImVec2((a.x+b.x)/2, (a.y+b.y)/2);
    ImGui::End();
    ImGui::Render();
}
static void Press() {
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent(target.x, target.y);
    Frame();
    io.AddMouseButtonEvent(0, true);
    Frame();
    CHECK(ImGui::GetActiveID() != 0, "the real checkbox must be pressed before testing cancellation");
}
int main() {
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.DisplaySize = ImVec2(348, 520);
    io.DeltaTime = 1.0f / 60;
    unsigned char *pixels; int w, h;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &w, &h);
    Frame(); Frame();
    Press();
    MFCancelImGuiTouch();
    Frame(); Frame();
    CHECK(!checked && ImGui::GetActiveID() == 0 && !io.MouseDown[0],
          "cancellation must neither toggle a checkbox nor leave it pressed");
    Press();
    io.AddMouseButtonEvent(0, false);
    Frame(); Frame();
    CHECK(checked, "normal release must still activate the same real checkbox");
    ImGui::DestroyContext();
    std::puts("PASS: real ImGui checkbox cancellation and normal release");
}
