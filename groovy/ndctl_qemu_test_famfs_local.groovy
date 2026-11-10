// ndctl_qemu_test_famfs_local.groovy
//
// Jenkins job entrypoint: run the famfs daxctl mode-transition tests
// (daxctl-famfs-nfit.sh + daxctl-famfs-cxltest.sh) under run_qemu on jmg.
//
// First consumer of run_qemu_fixture.groovy. It builds the ndctl-under-test by
// cloning the local famfs repo and running `make ndctl` (which clones
// jagalactic/ndctl@famfs into famfs/ndctl and builds it), then hands that ndctl
// source to the fixture for run_qemu to rsync + rebuild inside the guest.
//
// The kernel under test is intentionally left as a placeholder for now.

node('run_qemu') {                                 // dedicated build/run_qemu agent on thing1 (local disk + KVM)
    // This repo (scripts, fixture, saved config) lands in the workspace.
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'
    def fixture = load 'groovy/run_qemu_fixture.groovy'

    String famfsRepo = '/home/jenkins/git/famfs'   // local famfs repo on jmg
    String famfsWs   = "${env.WORKSPACE}/famfs"    // fresh checkout per build

    stage('build famfs ndctl') {
        sh """
            set -eux
            rm -rf '${famfsWs}'
            git clone -b master '${famfsRepo}' '${famfsWs}'
            # 'make all' on famfs master builds famfs and its ndctl; the ndctl
            # under test ends up at famfs/ndctl.
            make -C '${famfsWs}' all
            test -f '${famfsWs}/ndctl/meson.build'
        """
    }

    fixture.call(
        // ---- kernel under test ----
        kernelRepo:     '/home/jenkins/git/linux.git',     // local bare repo on jmg
        kernelBranch:   'famfs',
        kernelDir:      "${env.WORKSPACE}/linux-famfs",    // jenkins-writable workspace cache

        // ---- ndctl under test (built above) ----
        ndctlSrc:       "${famfsWs}/ndctl",

        // ---- saved kernel .config (committed in this repo) ----
        configFile:     "${env.WORKSPACE}/configs/famfs_qemu_ndctl.config",

        // ---- run_qemu fixture knobs ----
        runQemuArgs:    '--nfit-test --cxl-test',
        timeoutMin:     30,
        autorunScript:  "${env.WORKSPACE}/scripts/autorun/rq-famfs-autorun.sh",
        kcmdAppend:     "${env.WORKSPACE}/configs/rq-ci-cmdline",
        resultSentinel: 'RQ_FAMFS_RESULT rc='
    )
}
