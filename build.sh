#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

set -x

mkarchiso -v -r -w /tmp/archiso-tmp-$$ -o out/ .
