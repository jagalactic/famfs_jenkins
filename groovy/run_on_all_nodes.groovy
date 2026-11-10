def call(Map args) {
    def command = args.command
    if (!command) {
        error("Missing required parameter: command")
    }

    // All unique node labels used in coverage builds
    def nodeLabels = [
        'dax0.0 && kernel42',
        'dax0.0 && kernel43',
        'dax0.0 && fuse_v1',
        'dax0.0 && dual_v1',
        'dax0.0 && fuse_v2',
        'dax0.0 && dual_v2',
        'dax0.0 && fuse_v3',
        'dax0.0 && fuse_v4',
        'dax0.0 && extmap',
        'dax0.0 && dual_v3'
    ]

    pipeline {
        agent none

        stages {
            stage('Run on All Nodes') {
                steps {
                    script {
                        def branches = [:]

                        nodeLabels.each { label ->
                            def nodeLabel = label
                            branches[label] = {
                                node(nodeLabel) {
                                    stage("Run on ${nodeLabel}") {
                                        sh """
                                            echo "Running on: \$(hostname)"
                                            ${command}
                                        """
                                    }
                                }
                            }
                        }

                        parallel branches
                    }
                }
            }
        }
    }
}

return this
