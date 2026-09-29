# qe-install: Quantum ESPRESSO on NCHC Forerunner 1 (創進一號)

This repo builds [Quantum ESPRESSO](https://www.quantum-espresso.org/) (QE) from source with a single command. It uses the compilers, MPI, and math libraries that the system provides through its modules. It doesn't use containers or Spack.

```bash
git clone https://github.com/moneychen168/qe-install.git && ./qe-install/install.sh
```

You can run it from any directory, as any user. The script uses paths relative to the repo it lives in and never writes outside that repo (unless you pass `--prefix`).

## What it does

1. **Loads the toolchain.** It runs `module purge` and then loads the selected toolchain (default: `intel/2024_01_46`, which provides ifort/ifx, Intel MPI, MKL, and ScaLAPACK).
2. **Gets the source.** It clones the pinned QE release tag (default `qe-7.5`) from the official GitLab repo. It then checks that the checkout's commit hash matches the one recorded in the script, so a moved tag can't silently change what gets built.
3. **Configures and builds.** It copies the source into a separate build directory for each toolchain, runs `./configure` with the right MPI compiler and `--with-scalapack=intel`, then runs `make -j all` and `make install`. The build is idempotent: if you rerun it with the same settings, it reuses the configured tree.
4. **Writes an environment file.** It writes `<prefix>/qe-env.sh`, which loads the same modules and adds the QE binaries to `PATH`.
5. **Validates the install.** It runs a small Si SCF calculation with 2 MPI ranks and compares the total energy against a reference value (see [Validation](#validation)).

Build logs go to `work/logs/{configure,make,install}.log`.

## Requirements

- Forerunner 1 login node with `git`, `make`, `perl`, and the Lmod `module` command. All of these are available by default.
- Internet access to `gitlab.com` and `github.com`. The first is for the QE clone. The second is needed during `make`, when QE's own build fetches its bundled external libraries (LAPACK, FoX, libmbd, …) pinned to the commits recorded in the QE release. Run the script on a login node.
- A clone path **without spaces**. QE's Makefiles can't handle whitespace, so the script refuses such paths up front.
- For `--toolchain gnu`/`system`: **gfortran ≥ 9**. QE 7.5 uses the Fortran 2008 `FINDLOC` intrinsic, which gfortran 8 lacks, so the system's `gcc/8.5.0` can't build it. The script checks the version and stops with a clear message. In that case, use the default Intel toolchain or point `F1_GNU_MODULES` at a newer gcc + openmpi.
- About 3 GB of disk space and roughly 15 to 25 minutes with `-j 16`.

## Usage

```bash
./install.sh                              # QE 7.5, Intel toolchain, installs into ./qe-7.5-intel
F1_GNU_MODULES="gcc/<ver> openmpi/<ver>" ./install.sh --toolchain gnu   # needs gfortran >= 9
./install.sh --version 7.6 --prefix $HOME/opt/qe-7.6
./install.sh --targets "pw ph pp" -j 8    # build only some executables
./install.sh --no-test                    # skip the smoke test
./install.sh --clean                      # remove work/ (sources, build tree, logs)
./install.sh --help
```

Every flag also has a matching environment variable, for example `QE_VERSION=7.6 QE_TOOLCHAIN=gnu ./install.sh`. The full list is in `--help`. You can override the module names with `F1_INTEL_MODULES` / `F1_GNU_MODULES` if the system versions change.

| Toolchain | Modules | Compiler | BLAS/LAPACK/FFT | ScaLAPACK |
|---|---|---|---|---|
| `intel` (default) | `intel/2024_01_46` | `mpiifort` (falls back to `mpiifx`) | MKL | MKL + Intel MPI BLACS |
| `gnu` | `F1_GNU_MODULES` (default `gcc/8.5.0 openmpi/4.1.6`, which is too old, see above) | `mpif90` (gfortran ≥ 9) | system or QE-internal | none |
| `system` | none (uses `mpif90` from `PATH`) | `mpif90` | auto-detected | none |

## Running QE with Slurm

```bash
#!/bin/bash
#SBATCH --account=GOVXXXXXX
#SBATCH --partition=ct112
#SBATCH -N 1
#SBATCH -n 112
#SBATCH -t 01:00:00
#SBATCH -o qe.%j.out

source /path/to/qe-install/qe-7.5-intel/qe-env.sh   # also sets I_MPI_PMI_LIBRARY for srun
srun pw.x -nk 4 -in scf.in > scf.out
```

`examples/job.sbatch` contains a ready-made version of this script.

## Validation

`tests/si.scf.in` is a calculation on 2-atom diamond Si: LDA with the `Si.pz-vbc.UPF` pseudopotential (copied from the QE 7.5 source tree into `tests/pseudo/`), `ecutwfc = 18 Ry`, and a 4×4×4 shifted k-point mesh. `tests/check_si.sh` checks three things:

- `pw.x` finished (`JOB DONE`).
- The SCF converged.
- The final total energy is within `1e-5 Ry` of the reference, `-15.84452726 Ry`.

Different compilers and MPI rank counts only change the energy at about the `1e-8 Ry` level, so any larger mismatch points to a broken build or broken math libraries.

## Reproducibility notes

- **Pinned inputs:** the QE version and its commit hash, and the module names/versions.
- **No hidden state:** the script ignores `~/.bashrc` modules (it starts from `module purge`), doesn't depend on your working directory, and writes nothing to `$HOME`.
- **Fail-fast:** the script runs with `set -Eeuo pipefail`. Every failure names the step that failed and the log file to read.
- **Tested:** in clean containers, as a non-root user, via `git clone … && ./qe-install/install.sh --toolchain system`:
  - Rocky Linux 9 (gfortran 11.5 + Open MPI): full `make all` build, 89 executables installed. The Si test PASSES with 2, 4, and 8 ranks (identical energy −15.84452726 Ry). A second run reuses the build and finishes in seconds.
  - Rocky Linux 8 (gfortran 8.5, same as Forerunner 1's `gcc/8.5.0`): the script stops immediately with the gfortran ≥ 9 message.
  - A path containing a space: rejected up front with a clear message.
  - The `intel` toolchain path (the default on Forerunner 1) could not be tested outside Forerunner 1 and must be verified there.
