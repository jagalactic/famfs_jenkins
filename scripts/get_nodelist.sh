#!/bin/bash
set -x
# Configuration
JENKINS_URL="http://jenkins-server:8080"     # Change this
USER="your-username"                         # Optional if Jenkins doesn't require auth
API_TOKEN="your-api-token"                   # Optional
USE_AUTH=false                                # Set to false if no authentication

# Construct curl command
if [ "$USE_AUTH" = true ]; then
    AUTH="-u $USER:$API_TOKEN"
else
    AUTH=""
fi

# Query Jenkins for nodes and their labels
curl -s $AUTH "$JENKINS_URL/computer/api/json?tree=computer[displayName,offline,assignedLabels[name]]" |
jq -r '
  .computer[] |
  "\(.displayName)\tOffline: \(.offline)\tLabels: \([.assignedLabels[].name] | join(", "))"
'
