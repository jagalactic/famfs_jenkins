def call(Map args) {
    def REPO_URL = args.repoUrl
    def REPO_BRANCH = args.repo_branch
    if (!REPO_URL) {
        error("Missing required parameter: repoUrl")
    }

    pipeline {
        agent none

        stages {
            stage('Parallel Build and Coverage Testing') {
                steps {
                    script {
                        def branches = [:]

                        branches['kernel42'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && kernel42', '6.9.0-rc5+',
					  'kernel42.log', 'coverage_nofuse')
                        }

                        branches['kernel43'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && kernel43', '6.11.0-rc4+',
					  'kernel43.log', 'coverage_nofuse')
                        }

                        branches['fuse_v1'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v1',
					  '7.1.0-rc1-famfs+',
					  'fuse-only-v1.log', 'coverage_fuse')
                        }

                        branches['dual_v1'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && dual_v1',
					  '7.2.0-famfs_dual+',
					  'fuse-dual-v1.log', 'coverage_dual')
                        }

                        branches['fuse_v2'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v2',
					  '6.14.11-famfs_fusev2+',
					  'fuse-only-v2.log', 'coverage_fuse')
                        }

                        branches['dual_v2'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && dual_v2',
					  '6.14.11-famfs_dualv2+',
					  'fuse-dual-v2.log', 'coverage_dual')
                        }

                        branches['fuse_v3'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v3',
					  '6.14.11-famfs_fusev3-9ec0dce5faf4',
					  'fuse-only-v3.log', 'coverage_fuse')
                        }

                        branches['fuse_v4'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && fuse_v4',
					  '7.0.0-rc6-famfs-gcd1b90907aa2',
					  'fuse-only-v4.log', 'coverage_fuse')
                        }

                        branches['extmap'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && extmap',
					  '7.4.0-rc1+',
					  'fuse-extmap.log', 'coverage_fuse')
                        }

                        branches['dual_v3'] = {
                            buildOnKernel(REPO_URL, REPO_BRANCH,
					  'dax0.0 && dual_v3',
					  '6.14.11-famfs_dualv3-8eed96d91fe7',
					  'fuse-dual-v3.log', 'coverage_dual')
                        }

                        // Allow all branches to complete even if some fail
                        parallel branches.collectEntries { name, closure ->
                            [(name): {
                                try {
                                    closure()
                                } catch (err) {
                                    echo "Branch ${name} failed: ${err.message}"
                                    currentBuild.result = 'UNSTABLE'
                                }
                            }]
                        }
                    }
                }
            }

            stage('Merge Coverage Reports') {
                // Use a Python 3.13 build node (fuse_v4) for matching gcovr version
                agent { label 'dax0.0 && fuse_v4' }
                steps {
                    script {
                        // Checkout source code (needed for gcovr --html-details)
                        checkout([$class: 'GitSCM',
                            branches: [[name: REPO_BRANCH]],
                            userRemoteConfigs: [[url: REPO_URL]]
                        ])
                        // List of coverage JSON stash names (matching safeLabel values)
                        // Excluding kernel42/kernel43 - they use Python 3.12 with old gcovr (format 0.6)
                        // while other nodes use Python 3.13 with new gcovr (format 0.11)
                        def stashNames = [
                            'fuse_only_v1',
                            'fuse_dual_v1',
                            'fuse_only_v2',
                            'fuse_dual_v2',
                            'fuse_only_v3',
                            'fuse_only_v4',
                            'fuse_dual_v3'
                        ]

                        sh "mkdir -p merged_coverage/json_inputs"

                        // Unstash all available coverage JSON files
                        stashNames.each { name ->
                            try {
                                unstash "coverage_json_${name}"
                                sh "cp archived_coverage/${name}.json merged_coverage/json_inputs/ || true"
                            } catch (Exception e) {
                                echo "No coverage stash for ${name} (may have failed): ${e.message}"
                            }
                        }

                        // Merge all JSON files with gcovr
                        sh '''
                            cd merged_coverage
                            JSON_FILES=$(ls json_inputs/*.json 2>/dev/null || true)
                            if [ -n "$JSON_FILES" ]; then
                                echo "Merging coverage from: $JSON_FILES"
                                # Build gcovr merge command with -a for each JSON file
                                MERGE_ARGS=""
                                for f in $JSON_FILES; do
                                    MERGE_ARGS="$MERGE_ARGS -a $f"
                                done
                                gcovr $MERGE_ARGS -r .. --merge-mode-functions=merge-use-line-0 --html merged_coverage.html --html-details
                                echo "Merged coverage report generated"
                            else
                                echo "No coverage JSON files found to merge"
                            fi
                        '''

                        archiveArtifacts artifacts: "merged_coverage/**", allowEmptyArchive: true
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

            // Clean the workspace *contents* in place. Tests run under sudo and
            // leave root-owned files behind, so a plain deleteDir()/cleanWs()
            // (which runs as the agent user) can't remove them - hence the
            // root-level delete here.
            //
            // We empty the directory rather than moving + recreating it: moving
            // the live workspace out from under Jenkins races with its own
            // workspace bookkeeping and intermittently failed the very next step
            // with "missing workspace <path> on <agent>" (seen on fuse_v3),
            // flipping the whole build to UNSTABLE. Deleting only the contents
            // keeps the directory Jenkins leased, so there is nothing to race
            // and no backgrounded rm to leave .old.* litter on NFS.
            sh """
                set -e
                if [ -d "${env.WORKSPACE}" ]; then
                    sudo find "${env.WORKSPACE}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
                else
                    mkdir -p "${env.WORKSPACE}"
                fi
            """

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
                    // Fix ownership of any root-owned files (tests run with sudo)
                    sh "sudo chown -R \$(id -u):\$(id -g) . || true"

                    // Always collect coverage if available
                    sh "mkdir -p archived_coverage/${safeLabel}"
                    sh "cp -r coverage/famfs_unit_coverage/* archived_coverage/${safeLabel}/ || true"
                    // Copy JSON to a predictable location for merging
                    sh "cp coverage/famfs_unit_coverage/coverage.json archived_coverage/${safeLabel}.json || true"

                    archiveArtifacts artifacts: "${finalLogFile}", allowEmptyArchive: true
                    archiveArtifacts artifacts: "archived_coverage/${safeLabel}/**", allowEmptyArchive: true
                    archiveArtifacts artifacts: "archived_coverage/${safeLabel}.json", allowEmptyArchive: true

                    // Stash JSON for later merging
                    stash name: "coverage_json_${safeLabel}", includes: "archived_coverage/${safeLabel}.json", allowEmpty: true

                    if (buildFailed) {
                        error("Build failed on ${label}")
                    }
                }
            }
        }
    }
}

return this
