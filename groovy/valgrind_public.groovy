node('server') {
    // Clone the repo that contains all_coverage.groovy
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'

    // Now the file should exist in the workspace
    def valgrindScript = load 'groovy/valgrind.groovy'

    // Call with arguments
    valgrindScript.call(repoUrl: 'git@github.com:cxl-micron-reskit/famfs.git',
			repo_branch: 'master')
}
