// Nightly trigger. Declared here (not in the Jenkins UI) so it survives
// scripts/create-job.sh re-registration, which rewrites the whole job config.
// Historically fired ~01:40 daily.
properties([pipelineTriggers([cron('H 1 * * *')])])

node('server') {
    // Clone the repo that contains all_coverage.groovy
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'

    // Now the file should exist in the workspace
    def coverageScript = load 'groovy/coverage.groovy'

    // Call with arguments
    coverageScript.call(repoUrl: 'git@github.com:jagalactic/famfs.git',
    			repo_branch: 'master')
}
