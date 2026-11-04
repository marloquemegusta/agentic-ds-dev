# Host tests

`run-host-tests.ps1 -ProjectPath P [-Filter f] [-TailLines n]` runs, in order:

1. Each command in `project.json` `hostTests` (via `cmd.exe`, from the project
   root); the name is the `tests/test_*.py` stem if the command mentions one.
2. Each `tests/c/test_*.c`, compiled and run inside WSL.

Output: `DS_HOST_TEST=PASS|FAIL name=... ms=...` per test, then
`DS_HOST_TESTS=PASS|FAIL passed= failed=`; no tests gives `DS_HOST_TESTS=SKIP`.
`-Filter` is a wildcard on the test name (`c/<stem>`, Python file stem or command
text). `DS_HOST_TESTS_WARNING=undeclared files=...` means a `tests/test_*.py` is
mentioned by no `hostTests` command and never runs: declare it or delete it.

## Which kind

| | C test (`tests/c/test_*.c`) | Python test (`hostTests`) |
| :--- | :--- | :--- |
| Tests | The real C source, compiled with gcc | Whatever the script does |
| Checks | `-fsanitize=address,undefined`, so overflow, UB and OOB fail | None |
| Good for | Game logic, fixed-point math, state machines, data tables | Tooling, asset pipelines, generators, scenario/JSON validation |
| Avoid | Anything needing libnds hardware | Re-implementing C logic in Python or grepping C source: it passes while the C is wrong |

Prefer C tests for game logic.

## Writing a C test

```c
// DS_TEST_SOURCES: source/logic.c source/enemy.c
#include "ds_test.h"
#include "logic.h"

DS_TEST(clamp_limits_both_ends)
{
    DS_ASSERT_EQ(clamp_i32(-3, 0, 10), 0);
    DS_ASSERT(clamp_i32(99, 0, 10) == 10);
}
```

- `// DS_TEST_SOURCES:` (within the first 30 lines, may repeat) lists project
  relative `.c` files to link. Missing sources fail at `stage=compile`.
- `ds_test.h` (from `templates/host-test/`, on the include path automatically) is
  single-header: include it in exactly one translation unit; it provides `main()`.
  API: `DS_TEST(name)` (self-registering), `DS_ASSERT(cond)`, `DS_ASSERT_EQ(a, b)`
  (compared as `long long`). The first failed assert ends that test only.
- Build line: `gcc -std=gnu11 -O1 -g -fsanitize=address,undefined -DDS_HOST_TEST`
  with `-I include -I tests/c -I templates/host-test`; leaks are not checked.

## Isolating pure logic from libnds

- Put decisions in files that include only `<stdint.h>` and project headers, with
  no `<nds.h>`. The ROM calls them; the test links them directly.
- Where a file must include libnds, guard it: `#ifndef DS_HOST_TEST #include <nds.h> #endif`,
  and keep the hardware calls in a separate small file that is not in
  `DS_TEST_SOURCES`.
- For a few libnds names (`KEY_A`, `touchPosition`, ...) add stub headers under
  `tests/c/` (e.g. `tests/c/nds.h`) so `#include <nds.h>` resolves on the host
  (`-I include`, then `-I tests/c`, then the skill's `host-test` dir). Keep stubs minimal; a large
  stub means the code should be split instead.
- Fixed-point code must give the same result on host and ARM: use fixed-width
  types, not `long` or `int` assumptions, and no `float`.
- Host `int` is 32-bit and signed overflow is caught by UBSan; the ARM does not
  trap it, so a UBSan failure is a real bug.
