# Jenkins Disk Cleanup Guide

## Symptoms of Disk Full

When `/var/lib/jenkins` runs out of space:
- Builds queue but never start (HTTP 201 returned, but no build number assigned)
- Jenkins logs show: `java.io.IOException: No space left on device`

Check Jenkins logs via:
```bash
curl -s -u "USER:API_KEY" "http://jenkins-server:8080/log/rss" | head -100
```

## Identifying Large Jobs

### List all jobs with build counts

```bash
# Get first/last build numbers for each job
for job in $(curl -s -u "USER:API_KEY" \
  "http://jenkins-server:8080/api/json" | \
  python3 -c "import sys,json; [print(j['name']) for j in json.load(sys.stdin)['jobs']]"); do

  data=$(curl -s -u "USER:API_KEY" \
    "http://jenkins-server:8080/job/$job/api/json?tree=lastBuild[number],firstBuild[number]")

  last=$(echo "$data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('lastBuild',{}).get('number','?') if d.get('lastBuild') else '?')" 2>/dev/null)
  first=$(echo "$data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('firstBuild',{}).get('number','?') if d.get('firstBuild') else '?')" 2>/dev/null)

  printf "%-35s %s - %s\n" "$job" "$first" "$last"
done
```

## Deleting Old Builds

### Delete a single build

```bash
curl -X POST -u "USER:API_KEY" \
  "http://jenkins-server:8080/job/JOB_NAME/BUILD_NUMBER/doDelete"
```

### Delete a range of builds (keep last 20)

```bash
# Example: job has builds 1-464, keep 445-464, delete 1-444
JOB_NAME="public-master-k42"
START=1
END=444

for i in $(seq $START $END); do
  curl -s -X POST -u "USER:API_KEY" \
    "http://jenkins-server:8080/job/$JOB_NAME/$i/doDelete" &
  # Run 20 deletions in parallel for speed
  if (( i % 20 == 0 )); then
    wait
    echo "Deleted up to build $i"
  fi
done
wait
echo "Done"
```

### Bulk cleanup script

Save as `cleanup-jenkins-builds.sh`:

```bash
#!/bin/bash
# Usage: scripts/cleanup-jenkins-builds.sh JOB_NAME KEEP_COUNT
# Example: scripts/cleanup-jenkins-builds.sh smoke_local 20

JOB_NAME="$1"
KEEP="${2:-20}"
USER="jmg"
API_KEY="YOUR_API_KEY"
JENKINS_URL="http://jenkins-server:8080"

# Get last build number
LAST=$(curl -s -u "$USER:$API_KEY" \
  "$JENKINS_URL/job/$JOB_NAME/api/json?tree=lastBuild[number]" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('lastBuild',{}).get('number',0))")

if [ "$LAST" -le "$KEEP" ]; then
  echo "Only $LAST builds exist, nothing to delete"
  exit 0
fi

DELETE_UP_TO=$((LAST - KEEP))
echo "Deleting builds 1-$DELETE_UP_TO for $JOB_NAME (keeping last $KEEP)"

for i in $(seq 1 $DELETE_UP_TO); do
  curl -s -X POST -u "$USER:$API_KEY" \
    "$JENKINS_URL/job/$JOB_NAME/$i/doDelete" &
  if (( i % 20 == 0 )); then
    wait
    echo "  deleted up to build $i"
  fi
done
wait
echo "Done with $JOB_NAME"
```

## Preventing Future Disk Issues

### Configure automatic build retention per job

1. Go to job configuration in Jenkins UI
2. Check "Discard old builds"
3. Set "Max # of builds to keep" (e.g., 20-50)

### Via Jenkins CLI/API

```groovy
// In Jenkinsfile, add at the pipeline level:
options {
    buildDiscarder(logRotator(numToKeepStr: '20'))
}
```

### Check disk usage on server

```bash
# SSH to jenkins-server
df -h /var/lib/jenkins
du -sh /var/lib/jenkins/jobs/*/builds | sort -h
```

## Quick Reference

| Task | Command |
|------|---------|
| Check job build count | `curl -s -u "U:K" "http://jenkins-server:8080/job/JOB/api/json?tree=lastBuild[number]"` |
| Delete single build | `curl -X POST -u "U:K" "http://jenkins-server:8080/job/JOB/N/doDelete"` |
| Trigger build | `curl -X POST -u "U:K" "http://jenkins-server:8080/job/JOB/build"` |
| Check queue | `curl -s -u "U:K" "http://jenkins-server:8080/queue/api/json"` |
| Check nodes | `curl -s -u "U:K" "http://jenkins-server:8080/computer/api/json"` |
