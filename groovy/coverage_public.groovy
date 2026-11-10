node('server') {
    // Clone the repo that contains all_coverage.groovy
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'

    // Now the file should exist in the workspace
    def coverageScript = load 'groovy/coverage.groovy'

    // Call with arguments
    coverageScript.call(repoUrl: 'git@github.com:cxl-micron-reskit/famfs.git',
			repo_branch: 'master')

}
