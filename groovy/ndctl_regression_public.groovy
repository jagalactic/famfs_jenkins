// ndctl_regression_public.groovy
//
// Parameterized WORKER: build + boot ONE kernel under run_qemu, then run the
// ndctl meson suite (nfit + dax + cxl) against MULTIPLE ndctl versions in that
// single boot - amortizing the expensive kernel build + in-tree test modules
// (nfit_test/cxl_test) + rootfs + boot across all the ndctl refs. Catches
// regressions in the mainline nvdimm / dax / cxl subsystems as either the
// kernel or ndctl moves.
//
// The kernel is any repo@ref (tag/branch/sha), hardlink-cloned from the local
// mirror; ndctl is cloned directly from NDCTL_REPO at each ref in NDCTL_REFS.
// The guest autorun tests each /root/ndctl-<ref> and emits per-ref results, so
// failures are attributed to the exact ndctl version. See
// docs/ndctl_regression_public.md.

properties([
    parameters([
        string(name: 'KERNEL_REPO',
               defaultValue: 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git',
               description: 'Kernel git repo (url, or a local mirror path on thing1 for speed).'),
        string(name: 'KERNEL_REF',
               defaultValue: 'master',
               description: 'Kernel ref to test: tag (v7.2 / v7.1.3 / v7.3-rc1), branch (master), or sha.'),
        string(name: 'NDCTL_REPO',
               defaultValue: 'https://github.com/pmem/ndctl.git',
               description: 'ndctl git repo.'),
        string(name: 'NDCTL_REFS',
               defaultValue: 'pending v85',
               description: 'Space-separated ndctl refs to test in one boot: tags (v85+), branches (pending/main), or shas.'),
    ])
])

node('run_qemu') {                                 // build/run_qemu agent on thing1
    String notifyTo  = '@NOTIFY_EMAIL@'            // filled in from site.conf by scripts/create-job.sh
    String buildLink = "http://jenkins-server:8080/job/${env.JOB_NAME}/${env.BUILD_NUMBER}/"
    // Defined before try{} so the finally{} attribution/email can see them.
    List<String> ndctlRefs = (params.NDCTL_REFS ?: '').trim().split(/\s+/).findAll { it }
    String ndctlsDir = "${env.WORKSPACE}/ndctls"

    try {
        git url: 'git@github.com:jagalactic/famfs_jenkins.git'
        def fixture = load 'groovy/run_qemu_fixture.groovy'
        assert !ndctlRefs.isEmpty() : 'NDCTL_REFS is empty'

        currentBuild.displayName = "k:${params.KERNEL_REF} n:[${ndctlRefs.join(' ')}]"

        stage('fetch ndctl x N') {
            // One plain clone per ref (ndctl is small). A plain clone brings all
            // remote branches (origin/*) + tags, so checkout resolves a branch
            // (pending/main), a tag (vN), or a sha.
            sh "rm -rf '${ndctlsDir}'; mkdir -p '${ndctlsDir}'"
            for (String ref : ndctlRefs) {
                sh """
                    set -eux
                    d='${ndctlsDir}/${ref}'
                    git clone '${params.NDCTL_REPO}' "\$d"
                    git -C "\$d" checkout '${ref}'
                    test -f "\$d/meson.build"
                """
            }
        }

        stage('record refs') {
            // Exactly what this build tested (resolved shas) -> artifact + console.
            String refLines = ndctlRefs.collect {
                "echo \"ndctl ${it}: \$(git -C '${ndctlsDir}/${it}' rev-parse HEAD)\""
            }.join('\n')
            sh """
                set -eu
                {
                    echo "kernel: ${params.KERNEL_REPO} @ ${params.KERNEL_REF}"
                    echo "ndctl_repo: ${params.NDCTL_REPO}"
                    ${refLines}
                    echo "date: \$(date -u +%FT%TZ)"
                } | tee '${env.WORKSPACE}/tested-refs.txt'
            """
            archiveArtifacts artifacts: 'tested-refs.txt', allowEmptyArchive: true
        }

        // guest_srcs: rsync each ndctl tree to /root/ndctl-<ref> for the autorun.
        String guestSrcs = ndctlRefs.collect { "ndctl-${it}=${ndctlsDir}/${it}" }.join(' ')

        fixture.call(
            // ---- kernel under test (arbitrary ref) ----
            kernelRepo:     params.KERNEL_REPO,
            kernelRef:      params.KERNEL_REF,
            kernelMirror:   '/home/jenkins/git/linux-mirror.git',  // thing1-local bare mirror: hardlinked clone; public fallback
            kernelDir:      "${env.WORKSPACE}/linux-rq",   // persistent -> incremental builds

            // ---- multiple ndctl trees under test, built+tested by the autorun ----
            guestSrcs:      guestSrcs,

            // ---- config: run_qemu-compatible base + ndctl-infra fragment + assert ----
            configFile:     "${env.WORKSPACE}/configs/famfs_qemu_ndctl.config",
            configFragment: "${env.WORKSPACE}/configs/ndctl_regression.fragment",
            assertConfig:   'LIBNVDIMM ACPI_NFIT BLK_DEV_PMEM DAX DEV_DAX DEV_DAX_PMEM ZONE_DEVICE FS_DAX CXL_BUS CXL_ACPI CXL_PMEM',

            // ---- run_qemu fixture knobs ----
            //  --no-ndctl-build: the autorun builds each ndctl; don't let run_qemu build its own.
            runQemuArgs:    '--nfit-test --cxl-test --no-ndctl-build',
            timeoutMin:     180,                           // kernel build (once) + boot + N ndctl suites
            autorunScript:  "${env.WORKSPACE}/scripts/autorun/rq-ndctl-autorun.sh",
            kcmdAppend:     "${env.WORKSPACE}/configs/rq-ci-cmdline",
            resultSentinel: 'RQ_NDCTL_RESULT rc=',         // overall (any ref failing -> UNSTABLE)
            unstableOnFail: true
        )
    } catch (err) {
        currentBuild.result = 'FAILURE'                    // make the outcome visible to the finally
        throw err
    } finally {
        // Record the resolved kernel commit for the dax-regression-ledger (the
        // fixture's kernel:fetch has linux-rq checked out by now; record-refs
        // ran before it, so it only had the ref). Best-effort append + re-archive.
        if (fileExists('linux-rq/.git') && fileExists('tested-refs.txt')) {
            sh 'echo "KERNEL_SHA=$(git -C linux-rq rev-parse HEAD)" >> tested-refs.txt || true'
            archiveArtifacts artifacts: 'tested-refs.txt', allowEmptyArchive: true
        }
        // ---- per-ref attribution + weighted notification ----
        // Split the console into per-ref logs and parse each ref's verdict, so a
        // multi-ndctl run says exactly which ndctl failed and how much it matters.
        boolean kernelIsTag = (params.KERNEL_REF ==~ /v\d+\.\d+(\.\d+)?(-rc\d+)?/)
        List<String> failedRelease = []   // release ndctl (vN) fail on a tag kernel -> loud
        List<String> failedTip     = []   // pending/main, or anything on kernel-master -> quiet
        String summary = ndctlRefs.join(' ')

        if (fileExists('console.log')) {
            sh '''
                set -eu
                tr -d '\\r' < console.log | awk '
                    /===RQ_SECTION end===/ { file=""; next }
                    /===RQ_SECTION /       { s=$0; sub(/.*===RQ_SECTION /,"",s); sub(/===.*/,"",s); file=s".log"; next }
                                          { if (file) print > file }
                '
            '''
            archiveArtifacts artifacts: 'ndctl-*.log', allowEmptyArchive: true

            String results = sh(returnStdout: true, script:
                "grep -aoE 'RQ_NDCTL_RESULT ref=[^ ]+ rc=[0-9]+' console.log | sort -u || true").trim()
            List<String> parts = []
            for (String ref : ndctlRefs) {
                def m = (results =~ /RQ_NDCTL_RESULT ref=\Q${ref}\E rc=(\d+)/)
                String verdict
                boolean failed
                if (m.find()) { int rc = m.group(1) as int; failed = (rc != 0); verdict = failed ? 'FAIL' : 'OK' }
                else          { failed = true; verdict = '?' }   // no result line = didn't run
                if (failed) {
                    if (kernelIsTag && (ref ==~ /v\d+/)) failedRelease << ref else failedTip << ref
                }
                parts << "${ref}:${verdict}"
            }
            summary = parts.join(' ')
            currentBuild.displayName = "k:${params.KERNEL_REF} [${summary}]"
            writeFile file: 'test-results.txt',
                      text: "kernel: ${params.KERNEL_REF}\n" + parts.collect { "ndctl ${it}" }.join('\n') + "\n"
            archiveArtifacts artifacts: 'test-results.txt', allowEmptyArchive: true
        }

        String r = currentBuild.currentResult
        boolean infra = (r == 'FAILURE')                    // kernel build / assert / boot broke
        // LOUD iff a release-grade combo broke (kernel is a tag AND either infra
        // failure or a released ndctl failed). Otherwise, if anything failed on a
        // tip (kernel-master, or pending/main), send a QUIET [tip] note.
        boolean loud  = kernelIsTag && (infra || !failedRelease.isEmpty())
        boolean quiet = !loud && (r == 'FAILURE' || r == 'UNSTABLE')

        String body = """ndctl_regression_public ${r}

  kernel: ${params.KERNEL_REPO} @ ${params.KERNEL_REF}
  ndctl:  ${params.NDCTL_REPO}
  per-ref: ${summary}
  ${failedRelease ? 'release-grade FAIL: ' + failedRelease.join(', ') + '\n  ' : ''}${failedTip ? 'tip-grade FAIL: ' + failedTip.join(', ') : ''}
  (UNSTABLE = a test failed; FAILURE = build/boot/infra broke)

Console + per-ref artifacts: ${buildLink}console
"""
        if (loud) {
            mail to: notifyTo,
                 subject: "[Jenkins] ${env.JOB_NAME} #${env.BUILD_NUMBER} ${r} - k:${params.KERNEL_REF} [${summary}]",
                 body: body
        } else if (quiet) {
            mail to: notifyTo,
                 subject: "[Jenkins][tip] ${env.JOB_NAME} #${env.BUILD_NUMBER} ${r} - k:${params.KERNEL_REF} [${summary}]",
                 body: body
        }
        // all pass -> no email
    }
}
