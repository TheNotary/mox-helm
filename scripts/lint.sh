#!/usr/bin/env bash
#
# Run Helm lint, template render, and (optionally) kubeconform validation
# against all ci/ test fixtures.
#
# Usage:
#   ./ci/lint.sh              # lint + template only
#   ./ci/lint.sh --validate   # also run kubeconform (must be on PATH)

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_DIR="$CHART_DIR/ci"
VALIDATE=false
K8S_VERSION="${K8S_VERSION:-1.30.0}"

for arg in "$@"; do
  case "$arg" in
    --validate) VALIDATE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "==> Helm lint (default values)"
helm lint "$CHART_DIR"

for values_file in "$CI_DIR"/*-values.yaml; do
  name="$(basename "$values_file")"
  echo ""
  echo "==> Helm lint ($name)"
  helm lint "$CHART_DIR" -f "$values_file"

  echo "==> Helm template ($name)"
  output="$(helm template mox "$CHART_DIR" -f "$values_file")"

  if [ "$VALIDATE" = true ]; then
    if ! command -v kubeconform &>/dev/null; then
      echo "ERROR: kubeconform not found on PATH. Install it or run without --validate."
      exit 1
    fi
    echo "==> Kubeconform ($name)"
    echo "$output" | kubeconform -strict -ignore-missing-schemas -kubernetes-version "$K8S_VERSION" -summary
  fi
done

echo ""
echo "All checks passed."
