def call(Map args) {
    def REPO_URL = args.repoUrl
    def REPO_BRANCH = args.repo_branch ?: "master" // <-- Add this
    if (!REPO_URL) {
        error("Missing required parameter: repoUrl")
    }

    pipeline {
        agent none

        stages {
            stage('Parallel Build, Smoke and Unit Testing') {
                steps {
                    script {
                        def branches = [:]

			// this will succeed fast
                        branches['succeed'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					'dax0.0 && kernel43', '6.11.0-rc4+', 'this-will-succeed.log', 'clean')
                        }

			// this will fail fast
                        branches['fail'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					'dax0.0 && kernel43', '6.11.0-rc4+', 'this-will-fail.log', 'badtarg')
                        }

                        parallel branches
                    }
                }
            }
        }
    }
}

def buildOnKernel(repoUrl, repo_branch, label, expectedKernel, logFile, make_target) {
    node(label) {
        stage("Checkout and Build on ${label}") {
            def safeLabel = logFile.replaceFirst(/\.log$/, '').replaceAll(/[^a-zA-Z0-9]/, "_")
            def finalLogFile = logFile
            def buildFailed = false

            dir("${env.WORKSPACE}") {
                checkout([$class: 'GitSCM',
                    branches: [[name: repo_branch]],
                    userRemoteConfigs: [[url: repoUrl]]
                ])

                try {
                    sh """
                        {
                            date
                            hostname
                            uname -r
                            ACTUAL_KERNEL=\$(uname -r)
                            EXPECTED_KERNEL="${expectedKernel}"
                            if [[ "\$ACTUAL_KERNEL" == "\$EXPECTED_KERNEL" ]]; then
                                echo "PASS: Kernel version matches expected value (\$EXPECTED_KERNEL)."
                            else
                                echo "FAIL: Kernel version is '\$ACTUAL_KERNEL', expected '\$EXPECTED_KERNEL'."
                                exit 1
                            fi
                            pwd
                            make ${make_target}
                        } 2>&1 | tee ${logFile}
                        exit \${PIPESTATUS[0]}
                    """
                } catch (err) {
                    buildFailed = true
                    // Rename the log to indicate failure
                    def failLog = "fail_${logFile}"
                    sh "mv ${logFile} ${failLog}"
                    finalLogFile = failLog
                    // Mark the build step as failed but continue
                    echo "Build failed on ${label}, continuing"
                } finally {
                    // Always collect coverage if available
                    sh "mkdir -p archived_coverage/${safeLabel}"
                    sh "cp -r coverage/famfs_unit_coverage/* archived_coverage/${safeLabel}/ || true"

                    archiveArtifacts artifacts: "${finalLogFile}", allowEmptyArchive: true

                    if (buildFailed) {
                        error("Build failed on ${label}")
                    }
                }
            }
        }
    }
}

return this
