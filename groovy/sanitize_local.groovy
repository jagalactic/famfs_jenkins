// Nightly trigger. Declared here (not in the Jenkins UI) so it survives
// scripts/create-job.sh re-registration, which rewrites the whole job config.
// Historically fired ~04:07 daily.
properties([pipelineTriggers([cron('H 4 * * *')])])

node('server') {
    // Clone the repo that contains all_coverage.groovy
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'

    // Now the file should exist in the workspace
    def coverageScript = load 'groovy/sanitize.groovy'

    // Call with arguments
    coverageScript.call(repoUrl: '/home/jenkins/git/famfs',
			repo_branch: 'master')
}
