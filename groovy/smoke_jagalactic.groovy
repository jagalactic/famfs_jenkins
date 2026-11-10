node('server') {
    // Clone the repo that contains all_coverage.groovy
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'

    // Now the file should exist in the workspace
    def coverageScript = load 'groovy/smoke.groovy'

    // Call with arguments
    coverageScript.call(repoUrl: 'git@github.com:jagalactic/famfs.git',
			repo_branch: 'master')
}
