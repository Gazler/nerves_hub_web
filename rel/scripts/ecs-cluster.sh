#!/bin/bash

set -e

CLUSTER=nerves-hub

service_ip_addresses() {
  SERVICE=$1
  # get all tasks that are running
  TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --output json | jq -r '.taskArns[]')
  if [ ! -z "$TASKS" ]; then
    aws ecs describe-tasks --cluster $CLUSTER --tasks $TASKS --output json | jq -r '.tasks[] .containers[] .networkInterfaces[] .privateIpv4Address'
  fi
}

format_nodes() {
  for IP in $1; do echo "$2@$IP"; done
}

METADATA=`curl http://169.254.170.2/v2/metadata`
export LOCAL_IPV4=$(echo $METADATA | jq -r '.Containers[0] .Networks[] .IPv4Addresses[0]')
export AWS_REGION_NAME=us-east-1

WWW_IPS=$(service_ip_addresses nerves-hub-www)
WWW_NODES=$(format_nodes "$WWW_IPS" nerves_hub_www)

DEVICE_IPS=$(service_ip_addresses nerves-hub-device)
DEVICE_NODES=$(format_nodes "$DEVICE_IPS" nerves_hub_device)

API_IPS=$(service_ip_addresses nerves-hub-api)
API_NODES=$(format_nodes "$API_IPS" nerves_hub_api)

NODES=$(echo "$DEVICE_NODES $WWW_NODES $API_NODES" | tr '\n' ' ')

# we should now have something that looks like
# nerves_hub_www@10.0.2.120 nerves_hub_device@10.0.3.99 nerves_hub_api@10.0.3.101
export SYNC_NODES_OPTIONAL="$NODES"
echo $SYNC_NODES_OPTIONAL

exec /app/bin/$APP_NAME start
