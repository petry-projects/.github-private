#!/usr/bin/env bash
# Fixture: a LEGITIMATELY large resolution — it carries the pre-existing
# `legacy_shim` double declaration through unchanged (count still 2, same as the
# parent) and adds many brand-new single-declaration functions (a real upstream
# feature merge). Must produce NO integrity finding: the raw size grew, but no
# symbol's declaration count exceeds both parents. (AC #6)
set -euo pipefail

legacy_shim() {
  echo "shim v1"
}

legacy_shim() {
  echo "shim v2"
}

core_a() {
  echo a
}

feature_b() {
  echo b
}

feature_c() {
  echo c
}

feature_d() {
  echo d
}

feature_e() {
  echo e
}

feature_f() {
  echo f
}
