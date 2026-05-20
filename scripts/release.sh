#!/usr/bin/env bash

set -euo pipefail

VERSION=$1
CHART_REPO="oci://ghcr.io/thenotary/charts"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# Validate version
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version format. Expected format: X.Y.Z"
    exit 1
fi

# Update Chart.yaml with the new version
sed -i "s/^version: .*/version: $VERSION/" Chart.yaml

# package the chart
helm package .

# Push the new release
helm push mox-$VERSION.tgz $CHART_REPO
