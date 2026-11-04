// DS_TEST_SOURCES: source/logic.c
#include "ds_test.h"
#include "logic.h"

DS_TEST(clamp_inside_range_is_unchanged)
{
    DS_ASSERT_EQ(clamp_i32(5, 0, 10), 5);
}

DS_TEST(clamp_limits_both_ends)
{
    DS_ASSERT_EQ(clamp_i32(-3, 0, 10), 0);
    DS_ASSERT_EQ(clamp_i32(99, 0, 10), 10);
}
