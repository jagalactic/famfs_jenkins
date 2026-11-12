// famfs_regression.groovy
//
// Shared implementation of the famfs_{dbg,rel}_regression_public workers.
// Loaded by the thin entrypoints groovy/famfs_dbg_regression_public.groovy and
// groovy/famfs_rel_regression_public.groovy, which differ only in buildType:
//
//   debug    'make debug'   + run_smoke.sh --fuse           + ctest in debug/
//   release  'make release' + run_smoke.sh --fuse --release + ctest in release/
//
// Parameterized WORKER: build + boot ONE public kernel under run_qemu (nfit_test
// devdax), then build + smoke-test (--fuse) + unit-test MULTIPLE famfs versions
// in that single boot. The mashup of ndctl_regression_public (public kernel
// refs, N payload versions per boot, per-ref attribution, weighted mail) and
// smoke_qemu_nfit_local (the famfs smoke/unit payload on an nfit devdax).
//
// The kernel is any repo@ref (tag/branch/sha), hardlink-cloned from the local
// mirror with a fallback fetch from KERNEL_REPO (so Miklos' fuse tree tag works
// before it is in the mirror). Each famfs ref in FAMFS_REFS is cloned from
// FAMFS_REPO, prepared on the host ('make all' pulls the subrepos - the guest
// has no network) and handed to the guest as /root/famfs-<ref>. The autorun
// tests each and emits per-ref results, so failures are attributed to the exact
// famfs version. Public kernels only carry famfs in fuse mode, so --nofuse is
// not run. See docs/famfs_regression_public.md.
//
// Dispatched by scripts/famfs-regression-watch.sh (systemd timer on thing1):
// Miklos' fuse-update-7.4 tag until it is merged, then Linus' master nightly
// until the first v7.4 tag, then every release/rc/stable tag >= 7.4 plus master
// as the idle heartbeat. No Jenkins trigger of its own.
//
// Call with the entrypoint already inside node('run_qemu') and this repo
// checked out in the workspace:
//   buildType: 'debug' | 'release'
//   notifyTo:  mail recipient

def call(Map args) {
    String buildType = args.buildType ?: 'debug'
    if (!(buildType in ['debug', 'release'])) { error("famfs_regression: bad buildType '${buildType}'") }
    boolean isRelease = (buildType == 'release')
    String notifyTo  = args.notifyTo

    // Parameter defaults, also used directly on a job's very first build
    // (before this properties() call has ever registered the parameters).
    Map dflt = [
        KERNEL_REPO: 'https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git',
        KERNEL_REF:  'master',
        FAMFS_REPO:  'file:///home/jenkins/git/famfs.git',
        FAMFS_REFS:  'master',
        LIBFUSE_REF: 'famfs.extmap',
        RELEASE_CMAKE_BUILD_TYPE: 'RelWithDebInfo',
    ]
    List paramDefs = [
        string(name: 'KERNEL_REPO',
               defaultValue: dflt.KERNEL_REPO,
               description: 'Kernel git repo. Default: Linus\' tree (so KERNEL_REF=master is mainline). Use the stable tree https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git for vX.Y.Z tags, Miklos\' tree https://git.kernel.org/pub/scm/linux/kernel/git/mszeredi/fuse.git for a fuse-update-* tag.'),
        string(name: 'KERNEL_REF',
               defaultValue: dflt.KERNEL_REF,
               description: 'Kernel ref to test: tag (v7.4 / v7.4.2 / v7.5-rc1 / fuse-update-7.4), branch (master), or sha.'),
        string(name: 'FAMFS_REPO',
               defaultValue: dflt.FAMFS_REPO,
               description: 'famfs git repo (the thing1 mirror that smoke_local tests, or a url).'),
        string(name: 'FAMFS_REFS',
               defaultValue: dflt.FAMFS_REFS,
               description: 'Space-separated famfs refs to test in one boot: branches (master), release tags (v1.0), or shas.'),
        string(name: 'LIBFUSE_REF',
               defaultValue: dflt.LIBFUSE_REF,
               description: 'libfuse branch/tag/sha (github.com/jagalactic/libfuse) famfs is built against, pinned for this job (not chosen from the kernel). famfs.extmap until famfs lands in upstream libfuse; then master or a release tag.'),
    ]
    if (isRelease) {
        paramDefs << string(name: 'RELEASE_CMAKE_BUILD_TYPE',
               defaultValue: dflt.RELEASE_CMAKE_BUILD_TYPE,
               description: 'CMAKE_BUILD_TYPE exported while the guest runs \'make release\' (cmake >= 3.22 uses it when the Makefile passes none). RelWithDebInfo = -O2 -g -DNDEBUG, Release = -O3 -DNDEBUG. EMPTY = build exactly what the famfs ref\'s own \'make release\' produces.')
    }
    properties([
        disableConcurrentBuilds(),      // one run_qemu kernel build at a time per job; no multi-day pileups
        parameters(paramDefs)
    ])
    String pKernelRepo = params.KERNEL_REPO ?: dflt.KERNEL_REPO
    String pKernelRef  = params.KERNEL_REF  ?: dflt.KERNEL_REF
    String pFamfsRepo  = params.FAMFS_REPO  ?: dflt.FAMFS_REPO
    // '' is meaningful here (= no override), so only null falls back.
    String cmakeBuildType = isRelease ?
        (params.RELEASE_CMAKE_BUILD_TYPE != null ? params.RELEASE_CMAKE_BUILD_TYPE : dflt.RELEASE_CMAKE_BUILD_TYPE).trim() : ''
    if (!(cmakeBuildType ==~ /[A-Za-z]*/)) { error("bad RELEASE_CMAKE_BUILD_TYPE '${cmakeBuildType}'") }
    String buildDesc = isRelease ? "release (CMAKE_BUILD_TYPE=${cmakeBuildType ?: 'as the ref\'s make release sets it'})" : 'debug'

    String buildLink = "http://jenkins-server:8080/job/${env.JOB_NAME}/${env.BUILD_NUMBER}/"
    // Defined before try{} so the finally{} attribution/email can see them.
    List<String> famfsRefs = (params.FAMFS_REFS ?: dflt.FAMFS_REFS).trim().split(/\s+/).findAll { it }
    String treesDir = "${env.WORKSPACE}/famfs-trees"
    String libfuseRef = (params.LIBFUSE_REF ?: dflt.LIBFUSE_REF).trim()

    try {
        def fixture = load 'groovy/run_qemu_fixture.groovy'
        assert !famfsRefs.isEmpty() : 'FAMFS_REFS is empty'

        currentBuild.displayName = "k:${pKernelRef} f:[${famfsRefs.join(' ')}]"

        stage('fetch famfs x N') {
            // One clone per ref, then 'make all' ON THE HOST: that pulls every
            // subrepo (ndctl, libfuse, cmake-modules, C-Thread-Pool, mongoose)
            // and proves the tree builds, so the guest can rebuild offline.
            // run_qemu's guest copy excludes every .git/ (and build/), so the
            // guest cannot switch branches: check out the pinned LIBFUSE_REF
            // in ./libfuse HERE (the Makefile's kernel-derived choice only
            // applies to the host's fresh clone) and the guest builds it as
            // is. debug/ (host cmake cache, host paths) is dropped so the
            // guest configures fresh; ndctl/build is excluded by run_qemu.
            // .famfs-build-type tells the autorun which build to make and test.
            sh "rm -rf '${treesDir}'; mkdir -p '${treesDir}'"
            for (String ref : famfsRefs) {
                sh """
                    set -eux
                    d='${treesDir}/${ref}'
                    git clone '${pFamfsRepo}' "\$d"
                    git -C "\$d" checkout '${ref}'
                    make -C "\$d" all
                    test -d "\$d/ndctl" && test -d "\$d/libfuse"
                    git -C "\$d" rev-parse HEAD > "\$d/.famfs-sha"   # no .git in the guest
                    git -C "\$d/libfuse" fetch -q --tags origin
                    git -C "\$d/libfuse" checkout -q --detach "refs/remotes/origin/${libfuseRef}" 2>/dev/null \\
                        || git -C "\$d/libfuse" checkout -q --detach '${libfuseRef}'
                    echo "${libfuseRef} \$(git -C "\$d/libfuse" rev-parse HEAD)" | tee "\$d/.libfuse-ref"
                    echo '${buildType} ${cmakeBuildType}' > "\$d/.famfs-build-type"
                    rm -rf "\$d/debug" "\$d/release" "\$d/coverage"
                    # mongoose ships tutorials with dangling symlinks that break
                    # run_qemu's (-L) rsync; prune all dangling symlinks.
                    find "\$d" -xtype l -delete 2>/dev/null || true
                """
            }
        }

        stage('record refs') {
            // Exactly what this build tested (resolved shas) -> artifact + console.
            String refLines = famfsRefs.collect {
                "echo \"famfs ${it}: \$(git -C '${treesDir}/${it}' rev-parse HEAD)\""
            }.join('\n')
            sh """
                set -eu
                {
                    echo "kernel: ${pKernelRepo} @ ${pKernelRef}"
                    echo "famfs_build: ${buildDesc}"
                    echo "famfs_repo: ${pFamfsRepo}"
                    echo "libfuse: ${libfuseRef} \$(git -C '${treesDir}/${famfsRefs[0]}/libfuse' rev-parse HEAD)"
                    ${refLines}
                    echo "date: \$(date -u +%FT%TZ)"
                } | tee '${env.WORKSPACE}/tested-refs.txt'
            """
            archiveArtifacts artifacts: 'tested-refs.txt', allowEmptyArchive: true
        }

        // guest_srcs: rsync each famfs tree to /root/famfs-<ref> for the autorun.
        String guestSrcs = famfsRefs.collect { "famfs-${it}=${treesDir}/${it}" }.join(' ')

        fixture.call(
            // ---- kernel under test (arbitrary public ref) ----
            kernelRepo:     pKernelRepo,
            kernelRef:      pKernelRef,
            kernelMirror:   '/home/jenkins/git/linux-mirror.git',  // thing1-local bare mirror: hardlinked clone; KERNEL_REPO fallback
            kernelDir:      "${env.WORKSPACE}/linux-rq",   // persistent -> incremental builds

            // ---- multiple famfs trees under test, built+tested by the autorun ----
            guestSrcs:      guestSrcs,

            // ---- config: run_qemu-compatible base + nfit/dax/fuse fragment + assert ----
            configFile:     "${env.WORKSPACE}/configs/famfs_qemu_ndctl.config",
            configFragment: "${env.WORKSPACE}/configs/famfs_regression.fragment",
            assertConfig:   'LIBNVDIMM ACPI_NFIT BLK_DEV_PMEM DAX DEV_DAX DEV_DAX_PMEM ZONE_DEVICE FS_DAX FUSE_FS FUSE_PASSTHROUGH',

            // ---- run_qemu fixture knobs ----
            //  --no-ndctl-build: the rootfs ndctl/daxctl packages (or the famfs
            //  in-tree ndctl build) are used; don't let run_qemu build its own.
            runQemuArgs:    '--nfit-test --no-ndctl-build',
            timeoutMin:     150,                           // kernel build (once) + boot + N famfs build/smoke/unit
            autorunScript:  "${env.WORKSPACE}/scripts/autorun/rq-famfs-regression-autorun.sh",
            kcmdAppend:     "${env.WORKSPACE}/configs/rq-ci-cmdline",
            resultSentinel: 'RQ_FAMFS_RESULT rc=',         // overall (any ref failing -> UNSTABLE)
            unstableOnFail: true
        )
    } catch (err) {
        currentBuild.result = 'FAILURE'                    // make the outcome visible to the finally
        throw err
    } finally {
        // Resolved kernel commit (linux-rq is checked out by the fixture's
        // kernel:fetch, after record-refs ran). Best-effort append + re-archive.
        if (fileExists('linux-rq/.git') && fileExists('tested-refs.txt')) {
            sh 'echo "KERNEL_SHA=$(git -C linux-rq rev-parse HEAD)" >> tested-refs.txt || true'
            archiveArtifacts artifacts: 'tested-refs.txt', allowEmptyArchive: true
        }
        // ---- per-ref attribution + weighted notification ----
        // Split the console into per-ref/per-phase logs and parse each ref's
        // verdict, so a multi-famfs run says exactly which famfs failed and how
        // much it matters.
        boolean kernelIsTag = (pKernelRef ==~ /v\d+\.\d+(\.\d+)?(-rc\d+)?/)
        List<String> failedRelease = []   // released famfs (vX.Y*) fail on a tag kernel -> loud
        List<String> failedTip     = []   // master (or anything on a non-tag kernel) -> quiet
        String summary = famfsRefs.join(' ')

        if (fileExists('console.log')) {
            sh '''
                set -eu
                tr -d '\\r' < console.log | awk '
                    /===RQ_SECTION end===/ { file=""; next }
                    /===RQ_SECTION /       { s=$0; sub(/.*===RQ_SECTION /,"",s); sub(/===.*/,"",s); file=s".log"; next }
                                          { if (file) print > file }
                '
            '''
            archiveArtifacts artifacts: 'famfs-*.log', allowEmptyArchive: true

            String results = sh(returnStdout: true, script:
                "grep -aoE 'RQ_FAMFS_RESULT ref=[^ ]+ rc=[0-9]+' console.log | sort -u || true").trim()
            List<String> parts = []
            for (String ref : famfsRefs) {
                def m = (results =~ /RQ_FAMFS_RESULT ref=\Q${ref}\E rc=(\d+)/)
                String verdict
                boolean failed
                if (m.find()) {
                    int rc = m.group(1) as int
                    failed = (rc != 0)
                    switch (rc) {
                        case 0:   verdict = 'OK'; break
                        case 121: verdict = 'NOSUPPORT'; break     // kernel speaks no famfs fuse ABI
                        case 122: verdict = 'BUILDFAIL'; break
                        case 123: verdict = 'NODAX'; break         // nfit devdax setup failed (infra)
                        default:  verdict = 'FAIL'
                    }
                } else { failed = true; verdict = '?' }    // no result line = didn't run
                if (failed) {
                    if (kernelIsTag && (ref ==~ /v\d+\.\d+.*/)) failedRelease << ref else failedTip << ref
                }
                parts << "${ref}:${verdict}"
            }
            summary = parts.join(' ')
            currentBuild.displayName = "k:${pKernelRef} [${summary}]"
            writeFile file: 'test-results.txt',
                      text: "kernel: ${pKernelRef}\n" + parts.collect { "famfs ${it}" }.join('\n') + "\n"
            archiveArtifacts artifacts: 'test-results.txt', allowEmptyArchive: true
        }

        String r = currentBuild.currentResult
        boolean infra = (r == 'FAILURE')                    // kernel build / assert / boot broke
        // LOUD iff a release-grade combo broke (kernel is a version tag AND either
        // infra failure or a released famfs failed). Otherwise, if anything failed
        // on a tip (Miklos' tag, kernel-master, or famfs master), send a QUIET
        // [tip] note. All pass -> no email.
        boolean loud  = kernelIsTag && (infra || !failedRelease.isEmpty())
        boolean quiet = !loud && (r == 'FAILURE' || r == 'UNSTABLE')

        String body = """${env.JOB_NAME} ${r}

  kernel: ${pKernelRepo} @ ${pKernelRef}
  famfs:  ${pFamfsRepo}
  build:  ${buildDesc}
  per-ref: ${summary}
  ${failedRelease ? 'release-grade FAIL: ' + failedRelease.join(', ') + '\n  ' : ''}${failedTip ? 'tip-grade FAIL: ' + failedTip.join(', ') : ''}
  (UNSTABLE = a test failed, or NOSUPPORT = kernel has no famfs fuse ABI;
   FAILURE = build/boot/infra broke)

Console + per-ref artifacts: ${buildLink}console
"""
        if (loud) {
            mail to: notifyTo,
                 subject: "[Jenkins] ${env.JOB_NAME} #${env.BUILD_NUMBER} ${r} - k:${pKernelRef} [${summary}]",
                 body: body
        } else if (quiet) {
            mail to: notifyTo,
                 subject: "[Jenkins][tip] ${env.JOB_NAME} #${env.BUILD_NUMBER} ${r} - k:${pKernelRef} [${summary}]",
                 body: body
        }
    }
}

return this
