#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// A sandbox file survives simctl's console-attachment races and records whether
// the test actually entered main. The runner treats a missing result as failure.
static inline void MFOpenRegressionOutput(void) {
    const char *path = getenv("MF_REGRESSION_OUTPUT");
    if (path && *path) {
        if (!freopen(path, "w", stdout)) exit(2);
        dup2(fileno(stdout), STDERR_FILENO);
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    puts("START: HUD regression process entered main");
}
