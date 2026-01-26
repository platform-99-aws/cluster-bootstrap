#!/bin/bash

set -eou pipefail

# Load utils
source common.sh

# Deleting clusters
echo "Deleting bootstrap cluster..."
delete_cluster "${BOOTSTRAP_CLUSTER}"
