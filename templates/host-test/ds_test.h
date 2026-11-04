/* ds_test.h - tiny single-header host test harness (plain C99, gcc/clang).
 *
 * In a test file:   DS_TEST(name) { DS_ASSERT_EQ(a, b); }
 * Include this header in exactly one translation unit per test binary; it
 * provides main(). Exit status is 0 when every test passes, 1 otherwise.
 * Tests register themselves with a constructor, so no manual list is needed.
 * The sources under test are named in a `// DS_TEST_SOURCES: a.c b.c` comment.
 */
#ifndef DS_TEST_H
#define DS_TEST_H

#include <stdio.h>

typedef void (*ds_test_fn)(void);
typedef struct { const char *name; ds_test_fn fn; } ds_test_entry;

#define DS_TEST_MAX 256
static ds_test_entry ds_tests[DS_TEST_MAX];
static int ds_test_count;
static int ds_test_failed;

#define DS_TEST(test_name)                                                  \
    static void test_name(void);                                            \
    __attribute__((constructor)) static void register_##test_name(void)     \
    {                                                                       \
        if (ds_test_count < DS_TEST_MAX) {                                  \
            ds_tests[ds_test_count].name = #test_name;                      \
            ds_tests[ds_test_count++].fn = test_name;                       \
        }                                                                   \
    }                                                                       \
    static void test_name(void)

#define DS_ASSERT(cond)                                                     \
    do {                                                                    \
        if (!(cond)) {                                                      \
            printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);        \
            ds_test_failed = 1;                                             \
            return;                                                         \
        }                                                                   \
    } while (0)

#define DS_ASSERT_EQ(a, b)                                                  \
    do {                                                                    \
        long long ds_a_ = (long long)(a), ds_b_ = (long long)(b);           \
        if (ds_a_ != ds_b_) {                                               \
            printf("  FAIL %s:%d: %s == %s (%lld vs %lld)\n", __FILE__,     \
                   __LINE__, #a, #b, ds_a_, ds_b_);                         \
            ds_test_failed = 1;                                             \
            return;                                                         \
        }                                                                   \
    } while (0)

int main(void)
{
    int i, failures = 0;
    for (i = 0; i < ds_test_count; i++) {
        ds_test_failed = 0;
        ds_tests[i].fn();
        printf("%s %s\n", ds_test_failed ? "not ok" : "ok    ", ds_tests[i].name);
        failures += ds_test_failed;
    }
    printf("DS_TEST %s: %d/%d passed\n", failures ? "FAIL" : "PASS",
           ds_test_count - failures, ds_test_count);
    return failures ? 1 : 0;
}

#endif /* DS_TEST_H */
