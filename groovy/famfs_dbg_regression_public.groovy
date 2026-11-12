// famfs_dbg_regression_public.groovy
//
// famfs against public kernels, DEBUG build of famfs: build + boot ONE public
// kernel under run_qemu (nfit_test devdax), then build ('make debug') +
// smoke-test (run_smoke.sh --fuse) + unit-test (ctest in debug/) each famfs
// ref in FAMFS_REFS in that single boot.
//
// Thin entrypoint: the whole job, including its parameters, is
// groovy/famfs_regression.groovy; this file only picks the build type. The
// sibling job is famfs_rel_regression_public. Both are dispatched by
// scripts/famfs-regression-watch.sh (no Jenkins trigger of their own). See
// docs/famfs_regression_public.md.

node('run_qemu') {                                 // build/run_qemu agent on thing1
    git url: 'git@github.com:jagalactic/famfs_jenkins.git'
    def worker = load 'groovy/famfs_regression.groovy'
    worker.call(buildType: 'debug',
                notifyTo:  '@NOTIFY_EMAIL@')       // filled in from site.conf by scripts/create-job.sh
}
