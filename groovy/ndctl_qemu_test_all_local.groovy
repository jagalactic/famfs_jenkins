// ndctl_qemu_test_all_local.groovy
//
// Jenkins job entrypoint: run as much of the ndctl test suite as possible
// (suites ndctl + dax + cxl) under run_qemu on the famfs kernel, with the
// nfit_test + cxl_test emulated backends.
//
// Second consumer of run_qemu_fixture.groovy. It clones the ndctl-under-test
// (jagalactic/ndctl@famfs) and hands the source to the fixture; run_qemu
// rsyncs + rebuilds it in the guest, and rq-ndctl-autorun.sh runs the suite.
//
// Gating: unstableOnFail - env-dependent test failures show the build UNSTABLE
// (yellow); a missing result sentinel or a build failure stays FAILURE (red).

node('run_qemu') {                                 // dedicated build/run_qemu agent on thing1
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'
    def fixture = load 'groovy/run_qemu_fixture.groovy'

    String ndctlWs = "${env.WORKSPACE}/ndctl"      // fresh ndctl-under-test per build

    stage('fetch ndctl') {
        sh """
            set -eux
            rm -rf '${ndctlWs}'
            git clone -b famfs https://github.com/jagalactic/ndctl.git '${ndctlWs}'
            test -f '${ndctlWs}/meson.build'
        """
    }

    fixture.call(
        // ---- kernel under test (same famfs kernel as ndctl_qemu_test_famfs_local) ----
        kernelRepo:     '/home/jenkins/git/linux.git',
        kernelBranch:   'famfs',
        kernelDir:      "${env.WORKSPACE}/linux-famfs",

        // ---- ndctl under test ----
        ndctlSrc:       "${ndctlWs}",

        // ---- saved kernel .config (shared; has nfit/cxl/dax modular + famfs) ----
        configFile:     "${env.WORKSPACE}/configs/famfs_qemu_ndctl.config",

        // ---- run_qemu fixture knobs ----
        runQemuArgs:    '--nfit-test --cxl-test',
        timeoutMin:     90,
        autorunScript:  "${env.WORKSPACE}/scripts/autorun/rq-ndctl-autorun.sh",
        kcmdAppend:     "${env.WORKSPACE}/configs/rq-ci-cmdline",
        resultSentinel: 'RQ_NDCTL_RESULT rc=',
        unstableOnFail: true
    )
}
