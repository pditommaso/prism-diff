// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

#ifndef PRISM_TEST_WINDOW_GUARD_H
#define PRISM_TEST_WINDOW_GUARD_H

/// Installs the guard (also done automatically when the test bundle loads).
/// Returns 1 when windows are hidden, 0 when PRISM_SHOW_TEST_WINDOWS=1.
int prism_test_window_guard_install(void);

#endif
