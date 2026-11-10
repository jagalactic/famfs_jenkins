// smoke_qemu_cxltest_local.groovy
//
// famfs smoke + unit tests under run_qemu, on a cxl_test (mock) devdax.
// EXPERIMENTAL: probes whether famfs I/O works on cxl_test's gen_pool memory.
// Alison's "cxl_test has no real DRAM backing" is scoped to kmem onlining
// (system-ram mode), not dax read/write - the memory is system RAM, so famfs
// smoke (mount + mmap I/O) should be usable. See docs/smoke_qemu_cxltest_local.md.
//
// Guest has no DNS: famfs is prepared on the host (clone mirror + 'make all')
// and copied in via famfs=; the autorun builds it offline, picks the
// cxl_acpi.0 region's dax device (same discovery as daxctl-famfs-cxltest.sh),
// and runs run_smoke (each supported mode) + units.

node('run_qemu') {
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'
    def fixture = load 'groovy/run_qemu_fixture.groovy'

    String famfsRepo = '/home/jenkins/git/famfs'   // local mirror on thing1
    String famfsWs   = "${env.WORKSPACE}/famfs"

    stage('prepare famfs source') {
        sh """
            set -eux
            rm -rf '${famfsWs}'
            git clone -b master '${famfsRepo}' '${famfsWs}'
            make -C '${famfsWs}' all
            test -d '${famfsWs}/ndctl' && test -d '${famfsWs}/libfuse'
            # mongoose ships tutorials with dangling symlinks that break
            # run_qemu's (-L) famfs= rsync; prune all dangling symlinks.
            find '${famfsWs}' -xtype l -delete 2>/dev/null || true
        """
    }

    fixture.call(
        kernelRepo:     '/home/jenkins/git/linux.git',
        kernelBranch:   'famfs',
        kernelDir:      "${env.WORKSPACE}/linux-famfs",
        famfsSrc:       "${famfsWs}",
        // run_qemu's --cxl-test requires an ndctl source (check_ndctl_dir);
        // use famfs's own ndctl submodule (already cloned + built above).
        ndctlSrc:       "${famfsWs}/ndctl",
        configFile:     "${env.WORKSPACE}/configs/famfs_qemu_ndctl.config",
        runQemuArgs:    '--cxl-test',
        timeoutMin:     60,
        autorunScript:  "${env.WORKSPACE}/scripts/autorun/rq-famfs-smoke-cxl-autorun.sh",
        kcmdAppend:     "${env.WORKSPACE}/configs/rq-ci-cmdline",
        resultSentinel: 'RQ_FAMFS_SMOKE_RESULT rc='
    )
}
