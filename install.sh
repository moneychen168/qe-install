#!/usr/bin/env bash
#
# install.sh - reproducible Quantum ESPRESSO build for NCHC Forerunner 1 (創進一號)
#
#   git clone <this repo> && ./<this repo>/install.sh
#
# No containers, no Spack: QE is built from a pinned upstream git tag with the
# compilers / MPI / math libraries provided by the system's Lmod modules.
# Run with --help for options. Every option can also be set via environment
# variable (see the defaults block below).

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Defaults (overridable by environment variables or command-line flags)
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

QE_VERSION="${QE_VERSION:-7.5}"
QE_TOOLCHAIN="${QE_TOOLCHAIN:-intel}"          # intel | gnu | system
QE_TARGETS="${QE_TARGETS:-all}"                 # make targets, e.g. "pw pp ph"
QE_JOBS="${QE_JOBS:-}"                          # parallel make jobs (default: min(nproc,16))
QE_REPO_URL="${QE_REPO_URL:-https://gitlab.com/QEF/q-e.git}"
QE_SOURCE_DIR="${QE_SOURCE_DIR:-}"              # use an existing source tree (offline nodes)
QE_WORK_DIR="${QE_WORK_DIR:-${SCRIPT_DIR}/work}"
QE_PREFIX="${QE_PREFIX:-}"                      # default depends on version/toolchain
QE_RUN_TEST="${QE_RUN_TEST:-1}"                 # run a small Si SCF test after install
QE_TEST_NP="${QE_TEST_NP:-2}"

# Modules used on Forerunner 1 (see https://man.twcc.ai/@f1-manual)
F1_INTEL_MODULES="${F1_INTEL_MODULES:-intel/2024_01_46}"
F1_GNU_MODULES="${F1_GNU_MODULES:-gcc/8.5.0 openmpi/4.1.6}"

# Commit each release tag points to. The checkout is verified against this so
# a moved/re-tagged upstream tag cannot silently change what gets built.
declare -A QE_PINNED_COMMITS=(
    [7.5]=770a0b2d12928a67048e2f3da8d10d057e52179e
    [7.6]=9f93ddec427d2b9a45bb72d828c6d324f62fcabd
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[qe-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[qe-install] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[qe-install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build and install Quantum ESPRESSO from source on NCHC Forerunner 1 (創進一號).

Options (environment variable in brackets):
  -v, --version VER      QE release to build                [QE_VERSION=${QE_VERSION}]
  -t, --toolchain NAME   intel | gnu | system               [QE_TOOLCHAIN=${QE_TOOLCHAIN}]
                           intel : module ${F1_INTEL_MODULES} (ifort/ifx + Intel MPI + MKL/ScaLAPACK)
                           gnu   : module ${F1_GNU_MODULES} (gfortran + Open MPI)
                           system: no modules, use whatever mpif90 is in PATH
  -p, --prefix DIR       installation directory             [QE_PREFIX, default <repo>/qe-<ver>-<toolchain>]
  -j, --jobs N           parallel make jobs                 [QE_JOBS, default min(nproc,16)]
      --targets "T..."   make targets (all, pw, ph, pp, ...) [QE_TARGETS=${QE_TARGETS}]
      --source DIR       use an existing QE source tree instead of cloning [QE_SOURCE_DIR]
      --no-test          skip the post-install Si SCF test  [QE_RUN_TEST=0]
      --clean            remove the work directory and exit
  -h, --help             show this help

After installation:
  source <prefix>/qe-env.sh      # loads the same modules and puts pw.x etc. in PATH
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)   QE_VERSION="$2"; shift 2 ;;
        -t|--toolchain) QE_TOOLCHAIN="$2"; shift 2 ;;
        -p|--prefix)    QE_PREFIX="$2"; shift 2 ;;
        -j|--jobs)      QE_JOBS="$2"; shift 2 ;;
        --targets)      QE_TARGETS="$2"; shift 2 ;;
        --source)       QE_SOURCE_DIR="$2"; shift 2 ;;
        --no-test)      QE_RUN_TEST=0; shift ;;
        --clean)        rm -rf -- "${QE_WORK_DIR}"; log "removed ${QE_WORK_DIR}"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $1" ;;
    esac
done

case "${QE_TOOLCHAIN}" in
    intel|gnu|system) ;;
    *) die "unknown toolchain '${QE_TOOLCHAIN}' (expected intel, gnu or system)" ;;
esac

QE_PREFIX="${QE_PREFIX:-${SCRIPT_DIR}/qe-${QE_VERSION}-${QE_TOOLCHAIN}}"
# QE's Makefiles (and its submodule fetch logic) break on paths with whitespace.
for p in "${QE_WORK_DIR}" "${QE_PREFIX}"; do
    [[ "${p}" != *[[:space:]]* ]] \
        || die "path '${p}' contains whitespace, which QE's build system does not support; clone into a path without spaces or set QE_WORK_DIR/--prefix"
done
mkdir -p -- "${QE_PREFIX}" "${QE_WORK_DIR}"
QE_PREFIX="$(cd -- "${QE_PREFIX}" && pwd -P)"
QE_WORK_DIR="$(cd -- "${QE_WORK_DIR}" && pwd -P)"

if [[ -z "${QE_JOBS}" ]]; then
    QE_JOBS="$(nproc 2>/dev/null || echo 4)"
    # Be nice to shared login nodes.
    (( QE_JOBS > 16 )) && QE_JOBS=16
fi

LOG_DIR="${QE_WORK_DIR}/logs"
mkdir -p -- "${LOG_DIR}"

# ----------------------------------------------------------------------------
# Toolchain / environment
# ----------------------------------------------------------------------------
ensure_module_cmd() {
    if ! type module >/dev/null 2>&1; then
        local f
        for f in /etc/profile.d/lmod.sh /etc/profile.d/z00_lmod.sh \
                 /usr/share/lmod/lmod/init/bash /etc/profile.d/modules.sh; do
            # shellcheck disable=SC1090
            [[ -r "$f" ]] && { set +u; source "$f"; set -u; break; }
        done
    fi
    type module >/dev/null 2>&1 || die "'module' command not available; use --toolchain system"
}

load_modules() {
    local mods="$1"
    ensure_module_cmd
    # Lmod init scripts are not 'set -u' clean.
    set +u
    module purge
    # shellcheck disable=SC2086
    module load ${mods} || { set -u; die "module load ${mods} failed (check 'module avail')"; }
    set -u
    log "loaded modules: ${mods}"
}

MODULES_TO_LOAD=""
CONFIGURE_ARGS=()

setup_toolchain() {
    case "${QE_TOOLCHAIN}" in
        intel)
            MODULES_TO_LOAD="${F1_INTEL_MODULES}"
            load_modules "${MODULES_TO_LOAD}"
            [[ -n "${MKLROOT:-}" ]] || die "MKLROOT not set after loading ${MODULES_TO_LOAD}"
            # ifort is the most mature compiler for QE; fall back to ifx on newer oneAPI.
            local mpif90=""
            if command -v mpiifort >/dev/null && command -v ifort >/dev/null; then
                mpif90=mpiifort
            elif command -v mpiifx >/dev/null; then
                mpif90=mpiifx
            else
                die "neither mpiifort nor mpiifx found in PATH"
            fi
            CONFIGURE_ARGS+=(MPIF90="${mpif90}" CC=icx --with-scalapack=intel)
            # silence the ifort deprecation remark that otherwise floods the log
            export FFLAGS="${FFLAGS:--O2 -assume byterecl -g -traceback -diag-disable=10448}"
            ;;
        gnu)
            MODULES_TO_LOAD="${F1_GNU_MODULES}"
            load_modules "${MODULES_TO_LOAD}"
            CONFIGURE_ARGS+=(MPIF90=mpif90 F90=gfortran CC=gcc)
            ;;
        system)
            command -v mpif90 >/dev/null || die "mpif90 not found in PATH"
            CONFIGURE_ARGS+=(MPIF90=mpif90)
            ;;
    esac
    if [[ "${QE_TOOLCHAIN}" != intel ]]; then
        # QE >= 7.3 uses the Fortran 2008 FINDLOC intrinsic, first available in gfortran 9.
        local gfc_major
        gfc_major="$(mpif90 -dumpversion 2>/dev/null | cut -d. -f1)"
        if [[ "${gfc_major}" =~ ^[0-9]+$ ]] && (( gfc_major < 9 )); then
            die "gfortran ${gfc_major} is too old for QE ${QE_VERSION} (needs >= 9); load a newer gcc/openmpi via F1_GNU_MODULES or use --toolchain intel"
        fi
    fi
    CONFIGURE_ARGS+=(--prefix="${QE_PREFIX}")
    log "compiler: $("${CONFIGURE_ARGS[0]#MPIF90=}" --version 2>&1 | head -n1 || true)"
}

# ----------------------------------------------------------------------------
# Source
# ----------------------------------------------------------------------------
fetch_source() {
    if [[ -n "${QE_SOURCE_DIR}" ]]; then
        SRC_DIR="$(cd -- "${QE_SOURCE_DIR}" && pwd -P)"
        [[ -x "${SRC_DIR}/configure" ]] || die "${SRC_DIR} does not look like a QE source tree"
        log "using existing source tree ${SRC_DIR}"
        return
    fi

    local tag="qe-${QE_VERSION}"
    SRC_DIR="${QE_WORK_DIR}/src/q-e-${QE_VERSION}"
    if [[ ! -d "${SRC_DIR}/.git" ]]; then
        command -v git >/dev/null || die "git is required to download QE"
        log "cloning ${QE_REPO_URL} (tag ${tag})"
        rm -rf -- "${SRC_DIR}"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${tag}" \
            "${QE_REPO_URL}" "${SRC_DIR}"
    fi

    local want="${QE_PINNED_COMMITS[${QE_VERSION}]:-}"
    local have
    have="$(git -C "${SRC_DIR}" rev-parse HEAD)"
    if [[ -n "${want}" ]]; then
        [[ "${have}" == "${want}" ]] \
            || die "tag ${tag} is at ${have}, expected ${want}; refusing to build unverified source"
        log "source verified: ${tag} @ ${have}"
    else
        warn "no pinned commit for QE ${QE_VERSION}; building ${tag} @ ${have} unverified"
    fi
}

# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------
build() {
    # Out-of-tree builds are not supported by QE's configure, so build in a
    # private copy per toolchain to keep intel/gnu builds from clobbering each other.
    BUILD_DIR="${QE_WORK_DIR}/build/q-e-${QE_VERSION}-${QE_TOOLCHAIN}"
    local stamp="${BUILD_DIR}/.qe-install-configured"
    local config_id="${CONFIGURE_ARGS[*]} FFLAGS=${FFLAGS:-}"

    if [[ ! -f "${stamp}" || "$(cat "${stamp}")" != "${config_id}" ]]; then
        log "preparing build directory ${BUILD_DIR}"
        rm -rf -- "${BUILD_DIR}"
        mkdir -p -- "${BUILD_DIR}"
        (cd -- "${SRC_DIR}" && tar --exclude=.git -cf - .) | tar -xf - -C "${BUILD_DIR}"

        log "configuring (log: ${LOG_DIR}/configure.log)"
        (cd -- "${BUILD_DIR}" && ./configure "${CONFIGURE_ARGS[@]}") \
            > "${LOG_DIR}/configure.log" 2>&1 \
            || { tail -n 30 "${LOG_DIR}/configure.log" >&2; die "configure failed"; }
        grep -A20 '^The following libraries' "${LOG_DIR}/configure.log" || true
        printf '%s' "${config_id}" > "${stamp}"
    else
        log "reusing configured build directory ${BUILD_DIR}"
    fi

    # QE's top-level Makefile lets 'libupf' link before the internal LAPACK/BLAS
    # ($(LAPACK) in make.inc, set when no external library was found) is built,
    # which breaks parallel builds. Build it first.
    local lapack_target
    lapack_target="$(sed -n 's/^LAPACK[[:space:]]*=[[:space:]]*//p' "${BUILD_DIR}/make.inc")"

    log "building targets '${QE_TARGETS}' with ${QE_JOBS} jobs (log: ${LOG_DIR}/make.log)"
    # shellcheck disable=SC2086
    (cd -- "${BUILD_DIR}" \
        && { [[ -z "${lapack_target}" ]] || make -j"${QE_JOBS}" ${lapack_target}; } \
        && make -j"${QE_JOBS}" ${QE_TARGETS}) \
        > "${LOG_DIR}/make.log" 2>&1 \
        || { grep -n -m 20 -iE '(error|fatal)' "${LOG_DIR}/make.log" >&2 || true
             die "build failed, see ${LOG_DIR}/make.log"; }

    log "installing into ${QE_PREFIX}"
    (cd -- "${BUILD_DIR}" && make install) > "${LOG_DIR}/install.log" 2>&1 \
        || die "make install failed, see ${LOG_DIR}/install.log"
    if [[ " ${QE_TARGETS} " == *" all "* || " ${QE_TARGETS} " == *" pw "* ]]; then
        [[ -x "${QE_PREFIX}/bin/pw.x" ]] || die "pw.x missing from ${QE_PREFIX}/bin after install"
    fi
}

# ----------------------------------------------------------------------------
# Environment file for users
# ----------------------------------------------------------------------------
write_env_file() {
    local env="${QE_PREFIX}/qe-env.sh"
    {
        echo "# Generated by qe-install on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# QE ${QE_VERSION}, toolchain ${QE_TOOLCHAIN}. Usage: source ${env}"
        if [[ -n "${MODULES_TO_LOAD}" ]]; then
            echo "module purge"
            echo "module load ${MODULES_TO_LOAD}"
        fi
        if [[ "${QE_TOOLCHAIN}" == intel ]]; then
            echo "# needed by Intel MPI when launching with srun under Slurm"
            echo "[ -e /usr/lib64/libpmi.so ] && export I_MPI_PMI_LIBRARY=/usr/lib64/libpmi.so"
        fi
        echo "export QE_ROOT=\"${QE_PREFIX}\""
        echo "export PATH=\"\${QE_ROOT}/bin:\${PATH}\""
        echo "export OMP_NUM_THREADS=\"\${OMP_NUM_THREADS:-1}\""
    } > "${env}"
    log "wrote ${env}"
}

# ----------------------------------------------------------------------------
# Smoke test: 2-atom Si SCF, compared against a reference total energy
# ----------------------------------------------------------------------------
run_test() {
    [[ "${QE_RUN_TEST}" == 1 ]] || { log "skipping test"; return; }
    [[ -x "${QE_PREFIX}/bin/pw.x" ]] || { warn "pw.x not built, skipping test"; return; }

    local dir="${QE_WORK_DIR}/test-${QE_TOOLCHAIN}"
    rm -rf -- "${dir}"; mkdir -p -- "${dir}"
    sed -e "s#@PSEUDO_DIR@#${SCRIPT_DIR}/tests/pseudo#" -e "s#@OUTDIR@#${dir}/tmp#" \
        "${SCRIPT_DIR}/tests/si.scf.in" > "${dir}/si.scf.in"

    local launcher=(mpirun -np "${QE_TEST_NP}")
    if [[ "${QE_TOOLCHAIN}" == gnu || "${QE_TOOLCHAIN}" == system ]]; then
        # Open MPI refuses to run as root (containers) and may lack slots on login nodes.
        launcher+=(--oversubscribe)
        [[ "$(id -u)" == 0 ]] && launcher+=(--allow-run-as-root)
    fi

    log "running Si SCF test with ${QE_TEST_NP} MPI ranks"
    (cd -- "${dir}" && OMP_NUM_THREADS=1 "${launcher[@]}" "${QE_PREFIX}/bin/pw.x" -in si.scf.in) \
        > "${dir}/si.scf.out" 2>&1 \
        || { tail -n 30 "${dir}/si.scf.out" >&2; die "test run failed"; }

    "${SCRIPT_DIR}/tests/check_si.sh" "${dir}/si.scf.out" \
        || die "test result mismatch, see ${dir}/si.scf.out"
}

# ----------------------------------------------------------------------------
main() {
    log "QE ${QE_VERSION} | toolchain ${QE_TOOLCHAIN} | prefix ${QE_PREFIX} | jobs ${QE_JOBS}"
    setup_toolchain
    fetch_source
    build
    write_env_file
    run_test
    log "done. To use:  source ${QE_PREFIX}/qe-env.sh && pw.x -h"
}

main
