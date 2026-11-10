// smoke_qemu_nfit_local.groovy
//
// famfs smoke + unit tests under run_qemu, on an nfit_test-backed devdax.
// nfit_test pmem has real DRAM backing, so famfs can actually access the
// memory (per Alison's review) - this is the high-confidence smoke variant.
//
// Guest has no DNS: famfs is prepared on the host (clone mirror + 'make all'
// to pull subrepos) and copied into the guest via famfs=; the autorun builds
// it offline, carves a 6G devdax off ACPI.NFIT, and runs run_smoke (for each
// supported famfs mode) + the unit tests. See docs/smoke_qemu_nfit_local.md.
//
// Kernel and famfs source are selectable via Build with Parameters (the params
// register on the first run). Defaults reproduce the original job.

properties([
    parameters([
        string(name: 'KERNEL_REPO',   defaultValue: '/home/jenkins/git/linux.git',
               description: 'Kernel git repo (url or local path on thing1).'),
        string(name: 'KERNEL_BRANCH', defaultValue: 'famfs',
               description: 'Kernel branch to build.'),
        string(name: 'FAMFS_REPO',    defaultValue: '/home/jenkins/git/famfs',
               description: 'famfs git repo (url or local path on thing1).'),
        string(name: 'FAMFS_BRANCH',  defaultValue: 'master',
               description: 'famfs branch to build + test.'),
    ])
])

node('run_qemu') {
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'
    def fixture = load 'groovy/run_qemu_fixture.groovy'

    String famfsRepo = params.FAMFS_REPO
    String famfsWs   = "${env.WORKSPACE}/famfs"

    currentBuild.displayName = "k:${params.KERNEL_BRANCH} f:${params.FAMFS_BRANCH}"

    stage('prepare famfs source') {
        sh """
            set -eux
            rm -rf '${famfsWs}'
            git clone -b '${params.FAMFS_BRANCH}' '${famfsRepo}' '${famfsWs}'
            make -C '${famfsWs}' all
            test -d '${famfsWs}/ndctl' && test -d '${famfsWs}/libfuse'
            # mongoose ships tutorials with dangling symlinks that break
            # run_qemu's (-L) famfs= rsync; prune all dangling symlinks.
            find '${famfsWs}' -xtype l -delete 2>/dev/null || true
        """
    }

    try {
        fixture.call(
            kernelRepo:     params.KERNEL_REPO,
            kernelBranch:   params.KERNEL_BRANCH,
            kernelDir:      "${env.WORKSPACE}/linux-famfs",
            famfsSrc:       "${famfsWs}",
            configFile:     "${env.WORKSPACE}/configs/famfs_qemu_ndctl.config",
            runQemuArgs:    '--nfit-test',
            timeoutMin:     60,
            autorunScript:  "${env.WORKSPACE}/scripts/autorun/rq-famfs-smoke-nfit-autorun.sh",
            kcmdAppend:     "${env.WORKSPACE}/configs/rq-ci-cmdline",
            resultSentinel: 'RQ_FAMFS_SMOKE_RESULT rc='
        )
    } finally {
        // Split the interleaved guest serial console into per-mode artifacts.
        // Guest files can't be copied back, so we carve console.log on the
        // ===RQ_SECTION <name>=== markers the autorun emits, into
        // smoke-fuse.log / smoke-nofuse.log / unit.log. In finally{} so the
        // per-mode logs are produced even when the run fails (or a mode was
        // skipped, in which case its file just won't exist).
        stage('split smoke logs') {
            sh '''
                set -eu
                [ -f console.log ] || exit 0
                tr -d '\\r' < console.log | awk '
                    /===RQ_SECTION end===/ { file=""; next }
                    /===RQ_TESTLOG_END===/ { file=""; next }
                    /===RQ_SECTION /       { s=$0; sub(/.*===RQ_SECTION /,"",s); sub(/===.*/,"",s); file=s".log"; next }
                    file != ""             { print > file }
                '
            '''
            archiveArtifacts artifacts: 'smoke-fuse.log, smoke-nofuse.log, unit.log',
                             allowEmptyArchive: true
        }
    }
}
