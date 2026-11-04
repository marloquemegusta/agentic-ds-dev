#ifndef LOGIC_H
#define LOGIC_H

#include <stdint.h>

/* Pure logic (no libnds) so it can be unit-tested on the host. */
int32_t clamp_i32(int32_t value, int32_t lo, int32_t hi);

#endif /* LOGIC_H */
