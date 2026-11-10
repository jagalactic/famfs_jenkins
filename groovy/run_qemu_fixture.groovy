// run_qemu_fixture.groovy
//
// Reusable run_qemu test fixture for famfs_jenkins. load() this from a job
// entrypoint that is already inside a node{} block, then .call(args).
//
// It clones/updates a kernel tree and pmem/run_qemu, drops in a saved .config,
// then has run_qemu build the kernel, build a rootfs (with the ndctl you point
// it at), boot it, and run your --autorun script. The autorun script is
// expected to print a result sentinel line "<sentinel><rc>" on the guest
// console; this fixture parses it and fails the build on a non-zero rc (or if
// the sentinel is missing, which means the guest never finished).
//
// Required args:
//   kernelRepo     - git URL of the kernel to test
//   kernelBranch   - branch/tag to build
//   configFile     - path to a complete .config to copy into the kernel tree
//   autorunScript  - path to the in-guest test runner (run_qemu --autorun)
//   (and at least one source to test: ndctlSrc and/or famfsSrc)
//
// Optional args:
//   ndctlSrc       - path to an ndctl source tree (run_qemu rsyncs+builds it
//                    in the guest at /root/ndctl)
//   famfsSrc       - path to a famfs source tree (run_qemu rsyncs it to
//                    /root/famfs; the autorun builds + tests it in the guest)
//   kernelDir      - persistent kernel checkout (default $WORKSPACE/linux-rq)
//   runQemuRepo    - default git@github.com:jagalactic/run_qemu.git (famfs fork)
//   runQemuBranch  - branch to build (default 'famfs')
//   runQemuDir     - persistent run_qemu checkout (default $WORKSPACE/run_qemu)
//   buildDir       - run_qemu build dir (mkosi caches/rootfs). Default
//                    /home/jenkins/rq-build/$JOB_NAME/qbuild -- OUTSIDE the
//                    workspace so its root-owned mkosi files don't break the
//                    workspace clean, and so the mkosi caches persist.
//   runQemuArgs    - extra run_qemu flags (default '--nfit-test --qmp')
//   runQemuEnv     - extra env prefixed to run_qemu (e.g. 'cxl_t3_size=8G')
//   kcmdAppend     - file of extra kernel cmdline opts (e.g. rq_poweroff)
//   timeoutMin     - run_qemu --timeout, in minutes (default 30)
//   resultSentinel - console marker to parse (default 'RQ_RESULT rc=')
//   unstableOnFail - if true, a non-zero test rc marks the build UNSTABLE
//                    instead of FAILURE (a missing sentinel still fails);
//                    useful for max-coverage suites (default false)

def call(Map a) {
    assert a.kernelRepo    : "run_qemu_fixture: kernelRepo required"
    assert a.kernelBranch || a.kernelRef : "run_qemu_fixture: kernelBranch or kernelRef required"
    assert a.configFile    : "run_qemu_fixture: configFile required"
    assert a.autorunScript : "run_qemu_fixture: autorunScript required"
    assert a.ndctlSrc || a.famfsSrc || a.guestSrcs : "run_qemu_fixture: need ndctlSrc, famfsSrc, and/or guestSrcs"

    // run_qemu env prefix: copy whichever source trees are provided into the
    // guest (ndctl=-> /root/ndctl built by run_qemu; famfs=-> /root/famfs built
    // by the autorun; guestSrcs=-> one or more /root/<label> trees built by the
    // autorun, e.g. several ndctl versions tested in one boot).
    String srcEnv = ''
    if (a.ndctlSrc)  { srcEnv += "ndctl='${a.ndctlSrc}' " }
    if (a.famfsSrc)  { srcEnv += "famfs='${a.famfsSrc}' " }
    if (a.guestSrcs) { srcEnv += "guest_srcs='${a.guestSrcs}' " }
    // Extra env prefixed to the run_qemu invocation, e.g. 'cxl_t3_size=8G'.
    String extraEnv = a.runQemuEnv ? "${a.runQemuEnv} " : ''

    String kernelDir   = a.kernelDir   ?: "${env.WORKSPACE}/linux-rq"
    // Default to the famfs fork of run_qemu: its 'famfs' branch keeps the build
    // initramfs in $builddir instead of mkosi.extra/boot, so mkosi doesn't copy
    // it onto the size-capped (512M) ESP and overflow it on a clean build.
    String runQemuRepo   = a.runQemuRepo   ?: 'git@github.com:jagalactic/run_qemu.git'
    String runQemuBranch = a.runQemuBranch ?: 'famfs'
    String runQemuDir    = a.runQemuDir    ?: "${env.WORKSPACE}/run_qemu"
    String runQemuArgs = a.runQemuArgs ?: '--nfit-test --qmp'
    String sentinel    = a.resultSentinel ?: 'RQ_RESULT rc='
    int    timeoutMin  = (a.timeoutMin ?: 30) as int
    boolean unstableOnFail = (a.unstableOnFail ?: false)
    String kcmdOpt     = a.kcmdAppend ? "--kcmd-append '${a.kcmdAppend}'" : ''
    String consoleLog  = "${env.WORKSPACE}/console.log"
    // run_qemu's build dir (mkosi.cache / mkosi.builddir / the rootfs image /
    // the mnt mountpoints). mkosi runs privileged, so it fills these with
    // root-owned files that the Jenkins workspace clean cannot delete
    // ("Operation not permitted" -> failed checkout). Keep it OUTSIDE
    // ${WORKSPACE}, on the agent's local (xattr-capable) disk, so the workspace
    // clean never touches root-owned files and the mkosi incremental caches
    // persist across builds. Jenkins-owned.
    // Keyed per job AND per executor: concurrent builds of the same job (e.g.
    // the kernel-branch matrix) run on different executors, and each must own
    // its own buildDir - otherwise they share one mkosi staging dir and stomp
    // each other's rootfs build (and their kernels accumulate in a single ESP).
    // This mirrors the per-executor qemu '--instance' below. Caches are still
    // reused across builds landing on the same executor.
    // (run_qemu honors the 'builddir' env override; default is ./qbuild.)
    String executorId  = (env.EXECUTOR_NUMBER ?: '0')
    String buildDir    = a.buildDir ?: "/home/jenkins/rq-build/${env.JOB_NAME}/exec${executorId}/qbuild"
    // Where mkosi stages the transient guest rootfs. mkosi defaults this to
    // /var/tmp (on thing1's 50G root fs); N concurrent builds each stage a ~5G
    // Fedora rootfs there and exhaust '/' (dnf5 "needs more space on the /
    // filesystem" -> make_rootfs fails). Keep it on this big local disk instead,
    // per executor, via mkosi.local.conf (written below). Must be a SIBLING of
    // buildDir, not a child: mkosi treats builddir as a build source and rejects
    // a WorkspaceDirectory nested under a source dir.
    String mkosiWs     = "${buildDir.substring(0, buildDir.lastIndexOf('/'))}/mkosi-ws"
    // Shared mkosi package cache (downloaded RPMs + repo metadata) across ALL
    // executors and run_qemu jobs - safe to share (mkosi/dnf lock it) and cuts
    // WAN re-downloads to once per package instead of once per per-executor
    // cache. This is the PACKAGE cache only; the incremental IMAGE cache stays
    // per-executor in the builddir's mkosi.cache.
    String pkgCache    = a.pkgCache ?: '/home/jenkins/rq-build/pkgcache'
    // Optional: check out an arbitrary kernel ref (tag/sha/branch) instead of a
    // tracked branch. When set, 'kernel: fetch' does a detached checkout and
    // skips reset-to-origin/<branch>. Back-compat: unset -> kernelBranch path.
    String kernelRef      = a.kernelRef      ?: ''
    // Optional: a local bare kernel mirror (same filesystem as kernelDir) to
    // clone/fetch from instead of the network. A same-fs 'git clone' HARDLINKS
    // the object store -> near-instant, minimal disk vs a full multi-GB network
    // clone per executor. Only used by the kernelRef path. If a requested ref
    // isn't in the mirror yet (it's refreshed on a daily timer), the fixture
    // falls back to a tag fetch from kernelRepo (the authoritative source).
    String kernelMirror   = a.kernelMirror   ?: ''
    // Optional: merge a CONFIG fragment onto configFile (for building arbitrary
    // mainline kernels), then assert required symbols survived olddefconfig.
    String configFragment = a.configFragment ?: ''
    String assertConfig   = a.assertConfig   ?: ''   // space-separated CONFIG_ names, no CONFIG_ prefix

    stage('run_qemu: fetch') {
        sh """
            set -eux
            if [ -d '${runQemuDir}/.git' ]; then
                git -C '${runQemuDir}' remote set-url origin '${runQemuRepo}'
                git -C '${runQemuDir}' fetch --prune origin
                git -C '${runQemuDir}' checkout '${runQemuBranch}'
                git -C '${runQemuDir}' reset --hard 'origin/${runQemuBranch}'
            else
                mkdir -p "\$(dirname '${runQemuDir}')"
                git clone -b '${runQemuBranch}' '${runQemuRepo}' '${runQemuDir}'
            fi
        """
    }

    stage('kernel: fetch') {
        // Update (or clone) the kernel tree, then check out either an arbitrary
        // ref (kernelRef: tag/sha/branch, detached) or the tracked branch. The
        // tree persists across builds so the kernel build stays incremental.
        // (safe.directory: the source repo may be owned by another user, which
        // trips git's "dubious ownership" guard on clone/fetch.)
        if (kernelRef) {
            sh """
                set -eux
                # Source to clone/fetch from: the local mirror when present (same
                # fs -> hardlinked objects), else the authoritative repo directly.
                if [ -n '${kernelMirror}' ] && [ -d '${kernelMirror}' ]; then
                    rsrc='${kernelMirror}'
                else
                    rsrc='${a.kernelRepo}'
                fi
                if [ ! -d '${kernelDir}/.git' ]; then
                    mkdir -p "\$(dirname '${kernelDir}')"
                    git -c safe.directory="\$rsrc" clone "\$rsrc" '${kernelDir}'
                fi
                # Fetch by URL with an explicit refspec: a bare 'git fetch <url>'
                # only writes FETCH_HEAD and leaves refs/remotes/origin/* at
                # their clone-time values, so a branch ref like 'master' would
                # keep rebuilding the same stale commit on a re-used tree.
                git -C '${kernelDir}' -c safe.directory="\$rsrc" fetch --prune --tags "\$rsrc" '+refs/heads/*:refs/remotes/origin/*'
                # Resolve the target: prefer the fetched remote-branch tip (so a
                # branch ref like 'master' tracks latest), else the tag/sha of
                # that name. If absent - the mirror is refreshed only daily, so a
                # brand-new tag may not be in it yet - fall back to a tag fetch
                # from the authoritative source and re-resolve. Detached build.
                ktgt=''
                # A BRANCH of a repo that is not the mirror's source (e.g. master
                # of Linus' tree while the mirror follows linux-stable, whose
                # master trails it) must come from that repo: the mirror's
                # origin/<branch> is a different tip. Tags and shas are the same
                # objects everywhere, so they keep coming from the mirror.
                if [ "\$rsrc" != '${a.kernelRepo}' ] \\
                   && [ "\$(git -c safe.directory="\$rsrc" -C "\$rsrc" remote get-url origin 2>/dev/null)" != '${a.kernelRepo}' ] \\
                   && git ls-remote --exit-code --heads '${a.kernelRepo}' '${kernelRef}' >/dev/null 2>&1; then
                    echo "kernel ref ${kernelRef} is a branch of ${a.kernelRepo}, not of the mirror's source; fetching it from there"
                    git -C '${kernelDir}' -c safe.directory='${a.kernelRepo}' fetch '${a.kernelRepo}' '${kernelRef}'
                    ktgt='FETCH_HEAD'
                fi
                if [ -n "\$ktgt" ]; then
                    :
                elif git -C '${kernelDir}' rev-parse -q --verify "refs/remotes/origin/${kernelRef}^{commit}" >/dev/null 2>&1; then
                    ktgt='origin/${kernelRef}'
                elif git -C '${kernelDir}' rev-parse -q --verify "refs/tags/${kernelRef}^{commit}" >/dev/null 2>&1; then
                    ktgt='${kernelRef}'
                fi
                if [ -z "\$ktgt" ]; then
                    echo "kernel ref ${kernelRef} not in \$rsrc; fetching from source ${a.kernelRepo}"
                    git -C '${kernelDir}' -c safe.directory='${a.kernelRepo}' fetch --tags '${a.kernelRepo}'
                    if git -C '${kernelDir}' rev-parse -q --verify "refs/remotes/origin/${kernelRef}^{commit}" >/dev/null 2>&1; then
                        ktgt='origin/${kernelRef}'
                    elif git -C '${kernelDir}' rev-parse -q --verify "${kernelRef}^{commit}" >/dev/null 2>&1; then
                        ktgt='${kernelRef}'                 # a tag just fetched, or a sha
                    else
                        # A branch of a NON-origin repo (e.g. for-next in Miklos'
                        # fuse tree): --tags brought no refs/remotes for it, so
                        # fetch the ref by name and build its FETCH_HEAD.
                        git -C '${kernelDir}' -c safe.directory='${a.kernelRepo}' fetch '${a.kernelRepo}' '${kernelRef}'
                        ktgt='FETCH_HEAD'
                    fi
                fi
                git -C '${kernelDir}' checkout -f --detach "\$ktgt"
                git -C '${kernelDir}' reset --hard "\$ktgt"
            """
        } else {
            sh """
                set -eux
                if [ -d '${kernelDir}/.git' ]; then
                    git -C '${kernelDir}' -c safe.directory='${a.kernelRepo}' fetch --prune --tags origin
                    # kernelBranch may name a branch OR a tag/sha. Prefer the
                    # fetched remote-branch tip (so a branch input gets the
                    # latest); else fall back to the ref of that name. A tag has
                    # no origin/<tag> remote-tracking ref, so 'reset --hard
                    # origin/<tag>' failed once the tree was re-used (a fresh
                    # 'clone -b <tag>' had masked it). Detached build either way.
                    if git -C '${kernelDir}' rev-parse -q --verify "refs/remotes/origin/${a.kernelBranch}^{commit}" >/dev/null; then
                        ktgt='origin/${a.kernelBranch}'
                    else
                        ktgt='${a.kernelBranch}'
                    fi
                    git -C '${kernelDir}' checkout -f --detach "\$ktgt"
                    git -C '${kernelDir}' reset --hard "\$ktgt"
                else
                    mkdir -p "\$(dirname '${kernelDir}')"
                    git -c safe.directory='${a.kernelRepo}' clone -b '${a.kernelBranch}' '${a.kernelRepo}' '${kernelDir}'
                fi
            """
        }
    }

    stage('kernel: configure') {
        // The kernel tree persists across builds, so its generated .cmd deps
        // pin absolute host compiler paths. After a host toolchain change
        // (e.g. the Fedora 43->44 upgrade: gcc 15 -> 16) the stale deps
        // reference headers that no longer exist and make dies with "No rule
        // to make target /usr/lib/gcc/.../15/include/stddef.h" (seen in
        // ndctl_regression_public #106). Stamp the toolchain and mrproper on
        // change; the .config is re-applied right below anyway.
        sh """
            set -eu
            cd '${kernelDir}'
            # Before builds moved out of the tree (buildDir), an in-tree
            # ./qbuild held mkosi caches whose dirs are read-only
            # (dr-xr-xr-x), and 'make mrproper' (find | xargs rm) dies on them
            # with EACCES (ndctl_regression_public #108). Drop any stale
            # in-tree qbuild that is not the configured buildDir.
            if [ -d qbuild ] && [ "\$(readlink -f qbuild)" != "\$(readlink -f '${buildDir}')" ]; then
                echo "run_qemu_fixture: removing stale in-tree qbuild (builds go to ${buildDir})"
                chmod -R u+w qbuild || true
                rm -rf qbuild
            fi
            tc="\$(gcc -dumpfullversion 2>/dev/null || echo unknown)-\$(ld --version 2>/dev/null | head -1 | tr -d ' ')"
            # No stamp yet (tree predates this check) also cleans once: the
            # existing deps may already be stale.
            if [ "\$(cat .rq-toolchain 2>/dev/null || echo none)" != "\$tc" ] && [ -f Makefile ]; then
                echo "run_qemu_fixture: host toolchain \$(cat .rq-toolchain 2>/dev/null || echo none) -> \$tc; make mrproper"
                make mrproper >/dev/null
            fi
            echo "\$tc" > .rq-toolchain
        """
        if (configFragment) {
            // base (run_qemu-compatible) + fragment (forces the nvdimm/dax/cxl
            // infra on for an arbitrary mainline kernel), then resolve deps.
            sh """
                set -eux
                cd '${kernelDir}'
                scripts/kconfig/merge_config.sh -m -O . '${a.configFile}' '${configFragment}'
                make olddefconfig
            """
            if (assertConfig) {
                // Fail as infra (no sentinel -> red) if olddefconfig dropped a
                // symbol the test infra needs, rather than silently mis-testing.
                sh """
                    set -eu
                    miss=
                    for s in ${assertConfig}; do
                        grep -qE "^CONFIG_\${s}=(y|m)" '${kernelDir}/.config' || miss="\$miss \$s"
                    done
                    if [ -n "\$miss" ]; then
                        echo "run_qemu_fixture: CONFIG assertion FAILED - missing/disabled:\$miss" >&2
                        exit 1
                    fi
                    echo "run_qemu_fixture: CONFIG assertion OK"
                """
            }
        } else {
            sh """
                set -eux
                cp '${a.configFile}' '${kernelDir}/.config'
                make -C '${kernelDir}' olddefconfig
            """
        }
    }

    stage('run_qemu: build + boot + test') {
        // Jenkins-level hang protection. run_qemu's own --timeout needs
        // qmp-shell (often absent on the agent), so we don't pass it; the
        // Jenkins timeout aborts the build and ProcessTreeKiller reaps qemu.
        timeout(time: timeoutMin, unit: 'MINUTES') {
            sh """
                set -eux
                rm -f '${consoleLog}'
                cd '${kernelDir}'
                # Persistent, jenkins-owned run_qemu build dir outside the
                # workspace (see buildDir above): keeps root-owned mkosi
                # artifacts out of the wiped workspace and persists the mkosi
                # incremental caches across builds.
                mkdir -p '${buildDir}'
                # Purge stale kernel staging from prior builds on this executor.
                # run_qemu drops the freshly built kernel into mkosi.extra/boot
                # each run but does NOT remove the previous one, so across the
                # persistent buildDir they accumulate; mkosi then builds a UKI
                # (~300M) per kernel found there and overflows the small vfat ESP
                # (mcopy "Disk full" -> systemd-repart fails -> make_rootfs fails).
                # Keep only the current build's kernel. mkosi.cache (dnf metadata)
                # is left intact so incremental rootfs builds stay fast. rm -f so
                # the empty-glob / first-build (dir absent) cases are no-ops.
                rm -f '${buildDir}'/mkosi.extra/boot/vmlinuz-* \
                      '${buildDir}'/mkosi.extra/boot/System.map-* \
                      '${buildDir}'/mkosi.extra/boot/*.efi \
                      '${buildDir}'/initramfs-*.img
                # run_qemu never cleans mkosi.postinst, so a stale ndctl-build
                # postinst from a prior --ndctl-build run persists and runs
                # reinstall_ndctl.sh (cd /root/ndctl -> fails) even under
                # --no-ndctl-build. Drop it (and the script) so run_qemu
                # regenerates only what this build actually needs.
                rm -f '${buildDir}/mkosi.postinst' \
                      '${buildDir}'/mkosi.extra/root/reinstall_ndctl.sh
                # Relocate mkosi's transient rootfs staging OFF the small (50G)
                # root fs (see mkosiWs above). run_qemu regenerates mkosi.conf /
                # mkosi.conf.d each run but preserves mkosi.local.conf, and mkosi
                # reads it last (highest precedence), so this override wins.
                # WorkspaceDirectory is in the [Build] section (mkosi >= 25).
                mkdir -p '${mkosiWs}' '${pkgCache}'
                # Clear any stale mkosi-workspace-* leaked by a prior *aborted*
                # build on THIS executor (mkosi cleans up on a normal exit; a
                # killed run can leave one). Safe: buildDir is per-executor, so
                # no concurrent build shares '${mkosiWs}'.
                rm -rf '${mkosiWs}'/mkosi-workspace-*
                printf '[Build]\\nWorkspaceDirectory=%s\\nPackageCacheDirectory=%s\\n' '${mkosiWs}' '${pkgCache}' > '${buildDir}/mkosi.local.conf'
                # Run run_qemu in the background and stream the guest serial
                # console (--log) into this step's stdout via 'tail -F', so the
                # in-guest build/boot/test output shows LIVE in the Jenkins
                # console (and is tailable during the run) instead of only being
                # archived at the end. 'tail --pid' exits when run_qemu does;
                # run_qemu's exit status is preserved.
                ${extraEnv}${srcEnv}builddir='${buildDir}' '${runQemuDir}/run_qemu.sh' \
                    --instance "\${EXECUTOR_NUMBER:-0}" \
                    ${runQemuArgs} \
                    --log '${consoleLog}' -r img \
                    ${kcmdOpt} \
                    --autorun '${a.autorunScript}' &
                rq_pid=\$!
                tail -n +1 --pid=\$rq_pid -F '${consoleLog}' &
                tail_pid=\$!
                set +e
                wait \$rq_pid; rq_rc=\$?
                wait \$tail_pid 2>/dev/null
                set -e
                exit \$rq_rc
            """
        }
    }

    stage('result') {
        String rc = sh(returnStdout: true, script: """
            grep -aoE '${sentinel}[0-9]+' '${consoleLog}' | tail -1 | grep -oE '[0-9]+\$' || true
        """).trim()

        // Pull the clean meson testlog the guest emitted between markers (strip
        // serial-console CRs) into a readable per-test artifact.
        sh """
            set -eu
            {
                echo '# run_qemu guest test results'
                echo '# sentinel: ${sentinel}${rc}'
                echo
                awk '/===RQ_TESTLOG_BEGIN===/{f=1;next} /===RQ_TESTLOG_END===/{f=0} f' '${consoleLog}' | tr -d '\\r'
            } > '${env.WORKSPACE}/test-results.txt'
            # Compact one-line-per-test PASS/FAIL/SKIP list (+ counts).
            {
                echo '# ${sentinel}${rc}'
                awk -f '${env.WORKSPACE}/scripts/test-summary.awk' '${env.WORKSPACE}/test-results.txt'
            } > '${env.WORKSPACE}/test-summary.txt'
        """
        archiveArtifacts artifacts: 'console.log, test-results.txt, test-summary.txt', allowEmptyArchive: true

        if (!rc) {
            error("run_qemu_fixture: result sentinel '${sentinel}' not found on console - guest did not finish (build/boot/timeout?)")
        }
        echo "run_qemu_fixture: parsed test rc=${rc}"
        if (rc != '0') {
            if (unstableOnFail) {
                echo "run_qemu_fixture: test rc=${rc} != 0 - marking build UNSTABLE (unstableOnFail)"
                currentBuild.result = 'UNSTABLE'
            } else {
                error("run_qemu_fixture: tests failed (rc=${rc})")
            }
        }
    }
}

return this
