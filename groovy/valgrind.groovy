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

                        branches['kernel42'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && kernel42', '6.9.0-rc5+',
					  'kernel42.log', 'smoke_valgrind_nofuse')
                        }

                        branches['kernel43'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && kernel43', '6.11.0-rc4+',
					  'kernel43.log', 'smoke_valgrind_nofuse')
                        }

                        branches['fuse_v1'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v1', '7.1.0-rc1-famfs+',
					  'fuse-only-v1.log', 'smoke_valgrind_fuse')
                        }

                        branches['dual_v1'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && dual_v1', '7.2.0-famfs_dual+',
					  'fuse-dual-v1.log', 'smoke_valgrind_dual')
                        }

                        branches['fuse_v2'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v2', '6.14.11-famfs_fusev2+',
					  'fuse-only-v2.log', 'smoke_valgrind_fuse')
                        }

                        branches['dual_v2'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && dual_v2', '6.14.11-famfs_dualv2+',
					  'fuse-dual-v2.log', 'smoke_valgrind_dual')
                        }

                        branches['fuse_v3'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v3',
					  '6.14.11-famfs_fusev3-9ec0dce5faf4',
					  'fuse-only-v3.log', 'smoke_valgrind_fuse')
                        }

                        branches['fuse_v4'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v4',
					  '7.0.0-rc6-famfs-gcd1b90907aa2',
					  'fuse-only-v4.log', 'smoke_valgrind_fuse')
                        }

                        branches['extmap'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && extmap',
					  '7.4.0-rc1+',
					  'fuse-extmap.log', 'smoke_valgrind_fuse')
                        }

                        branches['dual_v3'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && dual_v3',
					  '6.14.11-famfs_dualv3-8eed96d91fe7',
					  'fuse-dual-v3.log', 'smoke_valgrind_dual')
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
                            rm -rf libfuse
                            make clean
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
