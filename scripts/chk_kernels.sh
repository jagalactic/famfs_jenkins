#!/usr/bin/env bash

check_kernel() {
    ACTUAL_KERNEL=$(ssh $1 uname -r)
    EXPECTED_KERNEL="$2"
    if [[ "$ACTUAL_KERNEL" == "$EXPECTED_KERNEL" ]]; then
	echo "Host: $1 kernel=${EXPECTED_KERNEL}"
    else
	echo "FAIL: $1 Kernel version is '$ACTUAL_KERNEL', expected '$EXPECTED_KERNEL'."
    fi
}
 
check_kernel jenkins-kernel43-0 "6.11.0-rc4+"
check_kernel jenkins-kernel43-1 "6.11.0-rc4+"
check_kernel jenkins-kernel42-0 "6.9.0-rc5+"
check_kernel jenkins-dualv1-0 "7.2.0-famfs_dual+"
check_kernel jenkins-dualv1-1 "7.2.0-famfs_dual+"
check_kernel jenkins-dualv2-0 "6.14.11-famfs_dualv2+"
check_kernel jenkins-dualv2-1 "6.14.11-famfs_dualv2+"
check_kernel jenkins-fusev1-0 "7.1.0-rc1-famfs+"
check_kernel jenkins-fusev2-0 "6.14.11-famfs_fusev2+"
check_kernel jenkins-fusev3-0 "6.14.11-famfs_fusev3-9ec0dce5faf4"
check_kernel jenkins-dualv3-0 "6.14.11-famfs_dualv3-8eed96d91fe7"
check_kernel jenkins-dualv3-1 "6.14.11-famfs_dualv3-8eed96d91fe7"
check_kernel jenkins-fusev4-0 "7.0.0-rc6-famfs-gcd1b90907aa2"
#check_kernel jenkins-fusev4-1 "7.0.0-rc6-famfs-gcd1b90907aa2"
check_kernel jenkins-fuse-extmap0 "7.4.0-rc1+"
check_kernel jenkins-fuse-extmap1 "7.4.0-rc1+"

