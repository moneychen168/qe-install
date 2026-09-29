#!/usr/bin/env bash
# Validate the output of tests/si.scf.in against a reference total energy.
# Usage: check_si.sh si.scf.out
set -euo pipefail

out="${1:?usage: $0 si.scf.out}"
REF_ENERGY="${REF_ENERGY:--15.84452726}"   # Ry, see README "Validation"
TOL="${TOL:-1.0e-5}"                 # Ry; compiler/MPI round-off is ~1e-8

grep -q 'JOB DONE' "${out}" || { echo "FAIL: pw.x did not finish (no 'JOB DONE')"; exit 1; }
grep -q 'convergence has been achieved' "${out}" || { echo "FAIL: SCF not converged"; exit 1; }

energy="$(awk '/^!/ {print $5}' "${out}" | tail -n1)"
[[ -n "${energy}" ]] || { echo "FAIL: no total energy found"; exit 1; }

awk -v e="${energy}" -v r="${REF_ENERGY}" -v t="${TOL}" 'BEGIN {
    d = e - r; if (d < 0) d = -d
    printf "total energy = %.8f Ry, reference = %.8f Ry, |diff| = %.2e Ry (tol %.1e)\n", e, r, d, t
    if (d > t) { print "FAIL"; exit 1 } else { print "PASS" }
}'
