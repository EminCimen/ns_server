#!/usr/bin/env python3
#
# @author Couchbase <info@couchbase.com>
# @copyright 2020-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.

import os
import sys
import getopt
import shutil
import inspect
import atexit
import requests
import glob
import time
import random

# Pretty prints any tracebacks that may be generated if the process dies
from traceback_with_variables import activate_by_import

scriptdir = os.path.dirname(os.path.realpath(__file__))
pylib = os.path.join(scriptdir, "..", "pylib")
sys.path.append(pylib)

import cluster_run_lib
import testlib
import authn_tests
import auto_failover_test
import sample_buckets
import ldap_tests
import tasks_test
import saml_tests
import bucket_deletion_test
import node_addition_tests
import users_backup_tests
import prom_sd_config_test
import serviceless_node_tests
import bucket_migration_test
import bucket_test
import internal_creds_rotation_tests
import pass_hashing_settings_tests
import secret_management_tests

tmp_cluster_dir = os.path.join(scriptdir, "test_cluster_data")

USAGE_STRING = """
Usage: {program_name}
    [--cluster | -c <address>:<port>]
        Specify already started cluster to connect to.
    [--user | -u <admin>]
        Username to be used when connecting to an existing cluster.
        Default: Administrator. Only used with --cluster | -c
    [--password | -p <admin_password>]
        Password to be used when connecting to an existing cluster.
        Default: asdasd. Only used with --cluster | -c
    [--num-nodes | -n <num_nodes>]
        Number of nodes available for an existing cluster. Use when not all
        nodes are already connected, for tests that need this configuration.
        When unspecified, num_nodes is assumed to be equal to the number of
        connected nodes. Only used with --cluster | -c
    [--tests | -t <test_spec>[, <test_spec> ...]]
        <test_spec> := <test_class>[.test_name]
        Start only specified tests
    [--keep-tmp-dirs | -k]
        Keep any test_cluster_data dirs after tests finish, even if they pass
    [--dont-intercept-output | -o]
        Display output from tests. By default, output is suppressed (unless the
        test fails). Setting this option forces output to be displayed even for
        successful test runs
    [--seed | -s <string>]
        Specify a seed to be set for python pseudo-random number generator
    [--help]
        Show this help
"""


def usage():
    print(USAGE_STRING.format(program_name=sys.argv[0]))


def bad_args_exit(msg):
    print(testlib.red(msg))
    usage()
    sys.exit(2)


def error_exit(msg):
    print(testlib.red(msg))
    sys.exit(2)


def remove_temp_cluster_directories():
    for dir in glob.glob(tmp_cluster_dir + "*"):
        print(f"Removing cluster dir {dir}...")
        shutil.rmtree(dir)


def kill_nodes(processes, urls, terminal_attrs):
    cluster_run_lib.kill_nodes(processes, terminal_attrs, urls)


def main():
    try:
        optlist, args = getopt.gnu_getopt(sys.argv[1:], "hkoc:u:p:n:t:s:",
                                          ["help", "keep-tmp-dirs", "cluster=",
                                           "user=", "password=", "num-nodes=",
                                           "tests=", "dont-intercept-output",
                                           "seed=", "colors="])
    except getopt.GetoptError as err:
        bad_args_exit(str(err))

    use_existing_server = False
    username = 'Administrator'
    password = 'asdasd'
    num_nodes = None
    address = '127.0.0.1'
    start_port = cluster_run_lib.base_api_port
    start_index = 0
    tests = None
    keep_tmp_dirs = False
    intercept_output = True
    seed = testlib.random_str(16)

    for o, a in optlist:
        if o in ('--cluster', '-c'):
            tokens = a.split(':')
            if len(tokens) != 2:
                bad_args_exit(f"Invalid format. Should be {o} <address>:<port>")
            address = tokens[0]
            start_port = int(tokens[1])
            start_index = start_port - cluster_run_lib.base_api_port
            use_existing_server = True
        elif o in ('--user', '-u'):
            if not use_existing_server:
                bad_args_exit(f"{o} is only supported with --cluster | -c")
            username = a
        elif o in ('--password', '-p'):
            if not use_existing_server:
                bad_args_exit(f"{o} is only supported with --cluster | -c")
            password = a
        elif o in ('--num-nodes', '-n'):
            if not use_existing_server:
                bad_args_exit(f"{o} is only supported with --cluster | -c")
            num_nodes = int(a)
        elif o in ('--tests', '-t'):
            tests = []
            for tokens in [t.strip().split(".") for t in a.split(",")]:
                if len(tokens) == 1:
                    tests.append((tokens[0], '*'))
                elif len(tokens) == 2:
                    tests.append((tokens[0], tokens[1]))
        elif o in ('--keep-tmp-dirs', '-k'):
            keep_tmp_dirs = True
        elif o in ('--dont-intercept-output', '-o'):
            intercept_output = False
        elif o in ('--seed', '-s'):
            seed = a
        elif o == '--colors':
            testlib.config['colors'] = (int(a) == 1)
        elif o in ('--help', '-h'):
            usage()
            exit(0)
        else:
            assert False, f"unhandled options: {o}"

    random.seed(seed)
    discovered_tests = discover_testsets()

    errors = {}
    not_ran = []
    # Remove any testsets that didn't correctly specify requirements
    for discovered_test in discovered_tests:
        (name, _, _, configurations) = discovered_test
        reason = None
        if not isinstance(configurations, list):
            reason = configurations
            not_ran.append((name, reason))
        for configuration in configurations:
            if not isinstance(configuration, testlib.ClusterRequirements):
                reason = configuration
                not_ran.append((name, reason))
        if reason is not None:
            discovered_tests.remove(discovered_test)

    if len(not_ran) > 0:
        msg = "Some testsets did not correctly specify requirements:\n"
        for (name, reason) in not_ran:
            msg += f"{name} - {reason}\n"
        error_exit(msg)
    testsets_str = ", ".join([c for c, _, _, _ in discovered_tests])
    print(f"Discovered testsets: {testsets_str}")

    if tests is None:
        testsets_to_run = discovered_tests
    else:
        testsets_to_run = find_tests(tests, discovered_tests)

    testsets_grouped = group_testsets(testsets_to_run)

    cluster = None
    if use_existing_server:
        # Get provided cluster
        cluster = get_existing_cluster(address, start_port,
                                       (username, password), num_nodes)
        print(f"Discovered cluster: {cluster}")
    else:
        remove_temp_cluster_directories()

    executed = 0
    test_time = 0
    start_ts = time.time_ns()
    for (configuration, testsets) in testsets_grouped:
        # Get an appropriate cluster to satisfy the configuration
        if use_existing_server:
            unmet_requirements = configuration.get_unmet_requirements(cluster)
            if len(unmet_requirements) > 0:
                for testset_name, _testset, _test_names in testsets:
                    reason = "Cluster provided does not satisfy test " \
                             f"requirements:\n" \
                             f"{[str(r) for r in unmet_requirements]}"
                    not_ran.append((testset_name, reason))
                continue
        else:
            cluster = testlib.get_appropriate_cluster(cluster,
                                                      (username, password),
                                                      start_index,
                                                      configuration,
                                                      tmp_cluster_dir,
                                                      kill_nodes)
        testset_start_ts = time.time_ns()
        # Run the testsets on the cluster
        tests_executed, testset_errors, testset_not_ran = \
            run_testsets(cluster, testsets, intercept_output=intercept_output,
                         seed=seed)
        test_time += (time.time_ns() - testset_start_ts)
        executed += tests_executed
        errors.update(testset_errors)
        not_ran += testset_not_ran

    ns_in_sec = 1000000000
    total_time = time.time_ns() - start_ts
    total_time_s = total_time / ns_in_sec
    prep_time_s = (total_time - test_time) / ns_in_sec
    test_time_s = test_time / ns_in_sec

    error_num = sum([len(errors[name]) for name in errors])
    errors_str = f"{error_num} error{'s' if error_num != 1 else ''}"
    if error_num == 0:
        colored = testlib.green
    else:
        colored = testlib.red

    def format_time(t):
        return f"{int(t//60)}m{t%60:.1f}s"

    print("\n======================================="
          "=========================================\n" +
          colored(f"Tests finished ({executed} executed, {errors_str})\n") +
          f"Total time:               {format_time(total_time_s)}\n"
          f"Total clusters prep time: {format_time(prep_time_s)}\n"
          f"Test time (no prep):      {format_time(test_time_s)}")
    if executed > 0:
        print(
          f"Avg. test time:           {format_time(total_time_s/executed)}\n"
          f"Avg. test time (no prep): {format_time(test_time_s/executed)}")

    print(f"\nSeed: {seed}\n")

    for name in errors:
        print(f"In {name}:")
        for testres in errors[name]:
            print(f"  {testres[0]} failed: {testres[1]}")
    print()

    if len(not_ran) > 0:
        print(f"Couldn't run the following tests:")
        for name, reason in not_ran:
            print(f"  {name}: {reason}")
    print()

    if len(errors) > 0:
        error_exit("Tests finished with errors")
    elif not (keep_tmp_dirs or check_for_core_files()):
        # Kill any created nodes and possibly delete directories as we don't
        # need to keep around data from successful tests
        cluster.teardown()
        remove_temp_cluster_directories()
        # Unregister the kill nodes atexit handler as the nodes are now down
        atexit.unregister(kill_nodes)


# If there are core files, the tests may have passed but something went wrong in
# erlang, so it is valuable to keep the logs in this case
def check_for_core_files():
    if keep := len(glob.glob("/tmp/core.*")) > 0:
        print("Core file(s) found. Keeping cluster logs")
    return keep


def group_testsets(testsets):
    # Group by requirements
    testsets_grouped = []
    for class_name, testset_class, test_names, configurations in testsets:
        for requirements in configurations:
            different = True
            testset_name = f"{class_name}/{requirements}"
            testset = (testset_name, testset_class, test_names)
            for (other_reqs, testsets) in testsets_grouped:
                if requirements.satisfied_by(other_reqs):
                    testsets.append(testset)
                    different = False
            if different:
                testsets_grouped.append((requirements, [testset]))
    """
    Sort testset groups by requirements string. The string lists immutable
    # requirements first, then mutable requirements. This ensures that any sets
    # of compatible configurations will be adjacent in the list. For example:
    (edition=Enterprise,num_nodes
    """
    return sorted(testsets_grouped, key=lambda x: str(x[0]))


def find_tests(test_names, discovered_list):
    results = {}
    discovered_dict = {n: (cl, t, cf) for n, cl, t, cf in discovered_list}
    for class_name, test_name in test_names:
        assert class_name in discovered_dict, \
            f"Testset {class_name} is not found. "\
            f"Available testsets: {list(discovered_dict.keys())}"
        testset, tests, configurations = discovered_dict[class_name]
        if test_name == '*':
            results[class_name] = (testset, tests, configurations)
        else:
            assert test_name in tests, \
                f"Test {test_name} is not found in {class_name}. "\
                f"Available tests: {tests})"

            if class_name in results:
                testlist = results[class_name][1]
                testlist.append(test_name)
                results[class_name] = (results[class_name][0], testlist,
                                       configurations)
            else:
                results[class_name] = (testset, [test_name], configurations)

    return [(k, results[k][0], results[k][1], results[k][2]) for k in results]


def discover_testsets():
    testsets = []

    def add_testset(testset_name, testset_class, configuration):
        tests = [test for test in dir(testset) if test.endswith('_test')]
        if len(tests) > 0:
            testsets.append((testset_name, testset_class, tests, configuration))

    for m in sys.modules.keys():
        if not hasattr(sys.modules[m], '__file__'):
            continue
        if sys.modules[m].__file__ is None:
            continue
        if scriptdir != os.path.dirname(sys.modules[m].__file__):
            continue
        for name, testset in inspect.getmembers(sys.modules[m], inspect.isclass):
            if testset == testlib.BaseTestSet:
                continue
            if issubclass(testset, testlib.BaseTestSet):
                requirements, err = testlib.safe_test_function_call(
                    testset, 'requirements', [])
                if err is not None:
                    return err
                if isinstance(requirements, list):
                    add_testset(name, testset, requirements)
                else:
                    add_testset(name, testset, [requirements])

    return testsets


def get_existing_cluster(address, start_port, auth, num_nodes):
    url = f"http://{address}:{start_port}"

    # Check that node is online
    pools_default = f"{url}/pools/default"
    try:
        response = requests.get(pools_default, auth=auth)
    except requests.exceptions.ConnectionError as e:
        error_exit(f"Failed to connect to {pools_default}\n"
                   f"{e}")
    if response.status_code != 200:
        error_exit(f"Failed to connect to {pools_default} "
                   f"({response.status_code})\n"
                   f"{response.text}")
    # Retrieve the number of nodes
    nodes_found = len(response.json().get("nodes", []))
    if nodes_found == 0:
        error_exit(f"Failed to retrieve nodes from {pools_default}")

    if num_nodes is None:
        # Assume that there are no nodes that are not already connected
        num_nodes = nodes_found

    nodes = [testlib.Node(host=address,
                          port=start_port + i,
                          auth=auth)
             for i in range(num_nodes)]

    return testlib.cluster.get_cluster(start_port, auth, [], nodes, nodes_found)


# Run each testset on the same cluster, counting how many individual tests were
# ran, and keeping track of all errors
def run_testsets(cluster, testsets, intercept_output=True, seed=None):
    executed = 0
    errors = {}
    not_ran = []
    for testset_name, testset, test_names in testsets:
        res = testlib.run_testset(testset, test_names, cluster, testset_name,
                                  intercept_output=intercept_output, seed=seed)
        executed += res[0]
        testset_errors = res[1]
        if len(testset_errors) > 0:
            errors[testset_name] = testset_errors
        not_ran += res[2]
    return executed, errors, not_ran


if __name__ == '__main__':
    main()
