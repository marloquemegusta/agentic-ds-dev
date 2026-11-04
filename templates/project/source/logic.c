#include "logic.h"

int32_t clamp_i32(int32_t value, int32_t lo, int32_t hi)
{
    if (value < lo)
        return lo;
    if (value > hi)
        return hi;
    return value;
}
