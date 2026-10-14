#!/bin/sh
# Runs the mdock-ml client end to end from a Linux container (DOCKER_CONTEXT=mdock).
# Needs accel/ml/build/resnet50.mlpackage (see ../README.md) for the Core ML steps.
set -e
ML="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm --name ml-demo -v "$ML:/ml:ro" -w /ml/examples python:3.13-alpine sh -c '
set -e
python3 mdock_ml.py health
python3 mdock_ml.py caps
[ -d /ml/build/resnet50.mlpackage ] && python3 mdock_ml.py upload /ml/build/resnet50.mlpackage --name ml-resnet50-demo
python3 mdock_ml.py classify ml-resnet50-demo images/parrot.jpg --units cpuAndNeuralEngine
python3 mdock_ml.py bench ml-resnet50-demo images/zebra.jpg --runs 50
python3 mdock_ml.py plan ml-resnet50-demo
python3 mdock_ml.py transcribe audio/hello.wav --format verbose_json
python3 mdock_ml.py chat "Name three uses of a Neural Engine" --stream || echo "(chat unavailable: see caps)"
'
