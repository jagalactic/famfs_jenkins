node('server') {
    // Clone the repo that contains coverage_unit.groovy
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'

    // Now the file should exist in the workspace
    def coverageUnitScript = load 'groovy/coverage_unit.groovy'

    // Call with arguments
    coverageUnitScript.call(repoUrl: '/home/jenkins/git/famfs.git',
			 repo_branch: 'master')
}
