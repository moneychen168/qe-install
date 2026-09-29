#!/bin/bash
# Example Slurm job for Forerunner 1 (創進一號). Edit account/partition/paths.
#SBATCH --account=GOVXXXXXX
#SBATCH --partition=ct112
#SBATCH --job-name=qe-scf
#SBATCH --nodes=1
#SBATCH --ntasks=112
#SBATCH --time=01:00:00
#SBATCH --output=qe.%j.out
#SBATCH --error=qe.%j.err

set -euo pipefail

QE_ENV="${QE_ENV:-$HOME/qe-install/qe-7.5-intel/qe-env.sh}"
source "${QE_ENV}"

export OMP_NUM_THREADS=1
srun pw.x -nk 4 -in scf.in > scf.out
