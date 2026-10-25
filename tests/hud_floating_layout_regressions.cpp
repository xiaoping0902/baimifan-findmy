#include "../app/Sources/HUD/MFHUDFloatingLayout.h"
#include <cassert>
#include <cmath>
#include <cstdio>
using namespace MFHUDFloating;
static bool Near(double a, double b) { return std::abs(a-b) < 0.00001; }
int main() {
    Rect screen{0,0,390,844};
    Size island{142,36};
    const Point expected[] = {{195,30},{195,814},{360,422},{30,422}};
    for (int o=1; o<=4; ++o) {
        Size logical=LogicalSize({390,844},o);
        Point p=ToPhysical(IslandCenter(logical,island,12),screen,o);
        assert(Near(p.x,expected[o-1].x) && Near(p.y,expected[o-1].y));
        Size panel=PhysicalSize({260,330},o);
        Point low=ClampCenter({-10000,-10000},panel,screen);
        Point high=ClampCenter({10000,10000},panel,screen);
        assert(Near(low.x-panel.width/2,0) && Near(low.y-panel.height/2,0));
        assert(Near(high.x+panel.width/2,390) && Near(high.y+panel.height/2,844));
        // A physical center at the middle is invariant across all orientations.
        Point middle=ToPhysical({logical.width/2,logical.height/2},screen,o);
        assert(Near(middle.x,195) && Near(middle.y,422));
    }
    // Zoom at the edge must keep the enlarged native surface on screen.
    Point enlarged=ClampCenter({350,800},{312,400},screen);
    assert(Near(enlarged.x,234) && Near(enlarged.y,644));
    Point reduced=ClampCenter(enlarged,{180,240},screen);
    assert(Near(reduced.x,enlarged.x) && Near(reduced.y,enlarged.y));
    // Geometry also works for non-zero screen origins and small screens.
    Point shifted=ToPhysical({195,422},{20,40,390,844},1);
    assert(Near(shifted.x,215) && Near(shifted.y,462));
    Point tiny=IslandCenter({100,20},{80,36},12);
    assert(Near(tiny.x,50) && Near(tiny.y,18));
    Point oversized=ClampCenter({-20,1000},{500,1000},screen);
    assert(Near(oversized.x,195) && Near(oversized.y,422));
    std::puts("floating layout: portrait/landscape island, full-screen drag and zoom bounds passed");
}
