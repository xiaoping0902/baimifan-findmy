#pragma once
#include <algorithm>
#include <cmath>

// UIKit-independent geometry shared by the native window and regression tests.
// Orientation values follow UIInterfaceOrientation (portrait=1, upside=2,
// landscapeRight=3, landscapeLeft=4). All positions are in screen points.
namespace MFHUDFloating {
struct Size { double width, height; };
struct Point { double x, y; };
struct Rect { double x, y, width, height; };
inline bool Landscape(int orientation) { return orientation == 3 || orientation == 4; }
inline Size LogicalSize(Size fixed, int orientation) {
    return Landscape(orientation) ? Size{fixed.height, fixed.width} : fixed;
}
inline Size PhysicalSize(Size logical, int orientation) {
    return LogicalSize(logical, orientation);
}
inline double Angle(int orientation) {
    constexpr double pi = 3.14159265358979323846;
    return orientation == 2 ? pi : orientation == 4 ? -pi/2 : orientation == 3 ? pi/2 : 0;
}
inline Point ToPhysical(Point logicalPoint, Rect fixed, int orientation) {
    Size logical = LogicalSize({fixed.width, fixed.height}, orientation);
    double dx = logicalPoint.x - logical.width/2, dy = logicalPoint.y - logical.height/2;
    double a = Angle(orientation);
    return {fixed.x + fixed.width/2 + std::cos(a)*dx - std::sin(a)*dy,
            fixed.y + fixed.height/2 + std::sin(a)*dx + std::cos(a)*dy};
}
inline Point ClampCenter(Point center, Size surface, Rect screen) {
    // Oversized surfaces are centered; never produce reversed clamp limits.
    double halfW = std::min(surface.width, screen.width)/2;
    double halfH = std::min(surface.height, screen.height)/2;
    return {std::clamp(center.x, screen.x + halfW, screen.x + screen.width - halfW),
            std::clamp(center.y, screen.y + halfH, screen.y + screen.height - halfH)};
}
inline Point IslandCenter(Size screen, Size island, double top) {
    double inset = std::clamp(top, 0.0, std::max(0.0, screen.height-island.height));
    return {screen.width/2, inset + island.height/2};
}
}
