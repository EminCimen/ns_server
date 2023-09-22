# @author Couchbase <info@couchbase.com>
# @copyright 2023-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.
from abc import ABC, abstractmethod
from enum import Enum
from typing import Dict, List, Union

import testlib
from testlib.cluster import Cluster, build_cluster
from testlib import get_succ


class ClusterRequirements:
    @testlib.no_output_decorator
    def __init__(self, edition=None, num_nodes=None, min_num_nodes=None,
                 memsize=None, min_memsize=None, num_connected=None,
                 min_num_connected=None, afamily=None, services=None,
                 master_password_state=None, num_vbuckets=None,
                 encryption=None):

        def maybe(f, *args):
            if all(x is None for x in args):
                return None
            return f(*args)

        self.requirements = \
            {
                'edition': maybe(lambda x: Edition(x), edition),
                'num_nodes': maybe(lambda *x: NumNodes(*x),
                                   num_nodes, min_num_nodes, num_connected,
                                   min_num_connected),
                'memsize': maybe(lambda *x: MemSize(*x), memsize, min_memsize),
                'afamily': maybe(lambda x: AFamily(x), afamily),
                'services': maybe(lambda x: Services(x), services),
                'master_password_state':
                    maybe(lambda x: MasterPasswordState(x),
                          master_password_state),
                'num_vbuckets': maybe(lambda x: NumVbuckets(x), num_vbuckets),
                'encryption': maybe(lambda x: N2nEncryption(x), encryption)
            }

    def __str__(self):
        all_reqs = sorted(self.as_list(), key= lambda x: x.__class__.__name__)
        immutable_requirements = list(filter(lambda x: not x.can_be_met(),
                                             all_reqs))
        mutable_requirements = list(filter(lambda x: x.can_be_met(),
                                           all_reqs))
        # List the requirements with mutables last, so that compatible
        # configurations would be adjacent when ordered by string
        requirements = immutable_requirements + mutable_requirements
        return ','.join([str(req) for req in requirements])

    def __repr__(self):
        return str(self)

    @staticmethod
    def get_default_start_args():
        return {
                # Don't rename first node when second node joins the cluster,
                # as this makes node removal / addition testing more complicated
                'dont_rename': True,
                # Wait until nodes are up before cluster_run_lib returns
                'wait_for_start': True,
                # Without this we would have cluster outputs overlapping test
                # output
                'nooutput': True,
                'num_nodes': 1,
                # Reduce the default num vbuckets to 16 to aid with faster
                # rebalance time. If a specific test needs 1024 vbuckets,
                # it can be passed down as a requirement.
                'num_vbuckets': 16,
                # The BYPASS_SASLAUTHD env affects external authentication,
                # and as a consequence affects external authentication tests.
                # Setting explicit value for BYPASS_SASLAUTHD here makes tests
                # more deterministic. None is used by default because
                # extenal authentication should not be passed by by default.
                'env': {'BYPASS_SASLAUTHD': None}
        }

    @staticmethod
    def get_default_connect_args(start_args):
        return {
                'protocol': "ipv4",
                'num_nodes': start_args['num_nodes'],
                # We don't want to create a bucket by default as we can rely on
                # test sets creating a bucket if needed in setup, and eventually
                # with an explicit cluster requirement, to offload bucket
                # creation and teardown to the test framework
                'create_bucket': False
               }

    def as_list(self):
        return list(filter(lambda x: x is not None, self.requirements.values()))

    @testlib.no_output_decorator
    def create_cluster(self, auth, start_index, tmp_cluster_dir, kill_nodes):
        start_args = {'start_index': start_index,
                      'root_dir': f"{tmp_cluster_dir}-{start_index}"}
        start_args.update(self.get_default_start_args())
        for requirement in self.as_list():
            start_args.update(requirement.start_args)

        connect_args = {'start_index': start_index}
        connect_args.update(self.get_default_connect_args(start_args))
        for requirement in self.as_list():
            connect_args.update(requirement.connect_args)

        cluster = build_cluster(auth=auth,
                                 start_args=start_args,
                                 connect_args=connect_args,
                                 kill_nodes=kill_nodes)

        still_unmet = self.get_unmet_requirements(cluster)
        if len(still_unmet) > 0:
            unmet_str = ', '.join(str(r) for r in still_unmet)
            raise RuntimeError("Newly created cluster still has the following "
                               f"requirements unmet: {unmet_str}")
        return cluster

    # Given a cluster, checks if any requirements are not satisfied, and
    # returns the unsatisfied requirements
    @testlib.no_output_decorator
    def is_satisfiable(self, cluster):
        unsatisfied = []
        satisfiable = True
        for requirement in self.as_list():
            if not requirement.is_met(cluster):
                unsatisfied.append(requirement)
                if not requirement.can_be_met():
                    satisfiable = False
        return satisfiable, unsatisfied

    @testlib.no_output_decorator
    def get_unmet_requirements(self, cluster):
        unmet_requirements = []
        for requirement in self.as_list():
            if not requirement.is_met(cluster):
                unmet_requirements.append(requirement)
        return unmet_requirements

    # Determines whether this set of requirements will be satisfiable with a
    # cluster satisfying some 'other' ClusterRequirements
    @testlib.no_output_decorator
    def satisfied_by(self, other):
        for requirement in self.as_list():
            if not (any(requirement == other_requirement
                        for other_requirement in other.requirements)):
                return False
        return True

    @testlib.no_output_decorator
    def intersect(self, other):
        new_reqs = ClusterRequirements()
        for k in self.requirements:
            r1 = self.requirements[k]
            r2 = other.requirements[k]
            if r1 == r2:
                new_reqs.requirements[k] = r1
            elif r1 is None:
                new_reqs.requirements[k] = r2
            elif r2 is None:
                new_reqs.requirements[k] = r1
            else:
                res, new_r = r1.intersect(r2)
                if res:
                    new_reqs.requirements[k] = new_r
                else:
                    return False, new_reqs

        return True, new_reqs


class Requirement(ABC):
    def __init__(self, **kwargs):
        # In order to provide a string representation of the requirement, we
        # need to be provided with a names and values in the form of kwargs
        self._kwargs = kwargs

        # Override to make a requirement that depends on arguments for
        # cluster_run_lib.start()
        self.start_args = {}
        # Override to make a requirement that depends on arguments for
        # cluster_run_lib.connect()
        self.connect_args = {}

    def __str__(self):
        return ",".join([f"{key}={value}"
                        for key, value in self._kwargs.items()
                        if value is not None])

    def __repr__(self):
        return self.__dict__.__repr__()

    def __eq__(self, other):
        return str(self) == str(other)

    @abstractmethod
    def is_met(self, cluster):
        raise NotImplementedError()

    # Override if make_met can be called on an existing cluster
    def can_be_met(self):
        return False

    # Override to provide a way of satisfying a requirement after the cluster
    # has already been created
    def make_met(self, cluster):
        raise RuntimeError(f"Cannot change Requirement {self} after cluster "
                           f"created")

    def intersect(self, other):
        return False, None


class Edition(Requirement):
    editions = ["Community", "Enterprise", "Serverless", "Provisioned"]

    def __init__(self, edition):
        super().__init__(edition=edition)
        if edition not in Edition.editions:
            raise ValueError(f"Edition must be in {Edition.editions}")

        self.edition = edition

        if self.edition == "Community":
            self.start_args = {'force_community': True,
                               'run_serverless': False}
        elif self.edition == "Enterprise":
            self.start_args = {'force_community': False,
                               'run_serverless': False}
        elif self.edition == "Serverless":
            self.start_args = {'force_community': False,
                               'run_serverless': True}
        elif self.edition == "Provisioned":
            self.start_args = {'force_community': False,
                               'run_provisioned': True}

    def is_met(self, cluster: Cluster):
        if self.edition == "Community":
            return not cluster.is_enterprise and not cluster.is_serverless
        elif self.edition == "Enterprise":
            return cluster.is_enterprise and not cluster.is_serverless
        elif self.edition == "Serverless":
            return cluster.is_enterprise and cluster.is_serverless
        elif self.edition == "Provisioned":
            return cluster.is_enterprise and cluster.is_provisioned


class NumNodes(Requirement):
    def __init__(self, num_nodes, min_num_nodes, num_connected,
                 min_num_connected):
        super().__init__(num_nodes=num_nodes, min_num_nodes=min_num_nodes,
                         num_connected=num_connected,
                         min_num_connected=min_num_connected)
        # Check requirement values are valid
        if num_nodes is None and min_num_nodes is None:
            raise ValueError("num_nodes and min_num_nodes can't both be None")
        if num_nodes is not None and min_num_nodes is not None:
            raise ValueError("num_nodes and min_num_nodes are mutually " \
                             "exclusive")
        if num_connected is not None and min_num_connected is not None:
            raise ValueError("num_connected and min_num_connected are " \
                             "mutually exclusive")
        if num_nodes is not None and num_nodes < 1:
            raise ValueError(f"num_nodes must be a positive integer")
        if min_num_nodes is not None and min_num_nodes < 1:
            raise ValueError(f"min_num_nodes must be a positive integer")
        if num_connected is not None and num_connected < 1:
            raise ValueError("num_connected must be at least 1")
        if min_num_connected is not None and min_num_connected < 1:
            raise ValueError("min_num_connected must be at least 1")
        if num_connected is not None:
            if num_nodes is not None:
                if num_connected > num_nodes:
                    raise ValueError("num_nodes cannot be less than " \
                                     "num_connected")
            elif min_num_nodes is not None:
                if num_connected > min_num_nodes:
                    raise ValueError("min_num_nodes cannot be less than " \
                                     "num_connected")
        if min_num_connected is not None:
            if num_nodes is not None:
                if min_num_connected > num_nodes:
                    raise ValueError("num_nodes cannot be less than " \
                                     "min_num_connected")
            elif min_num_nodes is not None:
                if min_num_connected > min_num_nodes:
                    raise ValueError("min_num_nodes cannot be less than " \
                                     "min_num_connected")

        self.num_nodes = num_nodes
        self.min_num_nodes = min_num_nodes
        self.num_connected = num_connected
        self.min_num_connected = min_num_connected
        # We use None as a placeholder for when we want all nodes connected
        if self.num_connected is None and self.min_num_connected is None:
            self.num_connected = self.num_nodes
            self.min_num_connected = self.min_num_nodes
        self.start_args = {'num_nodes': num_nodes if num_nodes is not None
                                                  else min_num_nodes}
        self.connect_args = \
            {'num_nodes': self.num_connected if self.num_connected is not None
                                             else self.min_num_nodes}

        if (self.num_connected is not None and self.num_connected > 1) or \
           (self.min_num_connected is not None and self.min_num_connected > 1):
            self.connect_args.update({'do_rebalance': True,
                                      'do_wait_for_rebalance': True})
        else:
            self.connect_args.update({'do_rebalance': False})


    def is_met(self, cluster):
        if self.num_nodes is not None and \
           len(cluster.nodes) != self.num_nodes:
            return False
        if self.num_connected is not None and \
           len(cluster.connected_nodes) != self.num_connected:
            return False
        if self.min_num_nodes is not None and \
           len(cluster.nodes) < self.min_num_nodes:
            return False
        if self.min_num_connected is not None and \
           len(cluster.connected_nodes) < self.min_num_connected:
            return False
        return True


    def intersect(self, other):
        res1, new_min, new_num = intersect_limits(self.min_num_nodes,
                                                  self.num_nodes,
                                                  other.min_num_nodes,
                                                  other.num_nodes)

        res2, new_min_con, new_con = intersect_limits(self.min_num_connected,
                                                      self.num_connected,
                                                      other.min_num_connected,
                                                      other.num_connected)
        if res1 and res2:
            return True, NumNodes(new_num, new_min, new_con, new_min_con)
        return False, None


class MemSize(Requirement):
    def __init__(self, memsize, min_memsize):
        super().__init__(memsize=memsize, min_memsize=min_memsize)
        if memsize is not None and min_memsize is not None:
            raise ValueError("memsize and min_memsize are mutually exclusive")
        if memsize is not None and memsize < 256:
            raise ValueError(f"memsize must be a positive integer >= 256")
        if min_memsize is not None and min_memsize < 256:
            raise ValueError(f"min_memsize must be a positive integer >= 256")
        self.memsize = memsize
        self.min_memsize = min_memsize
        if memsize is not None:
            self.memsize_to_use = memsize
        elif min_memsize is not None:
            self.memsize_to_use = min_memsize
        self.connect_args = {'memsize': self.memsize_to_use}

    def is_met(self, cluster):
        if self.memsize is not None:
            return cluster.memsize == self.memsize
        return cluster.memsize >= self.min_memsize

    def can_be_met(self):
        return True

    def make_met(self, cluster):
        testlib.post_succ(cluster, "/pools/default",
                          data={"memoryQuota": self.memsize_to_use})
        cluster.memsize = self.memsize_to_use

    def intersect(self, other):
        res, new_min, new_mem = intersect_limits(self.min_memsize,
                                                 self.memsize,
                                                 other.min_memsize,
                                                 other.memsize)
        if res:
            return True, MemSize(new_mem, new_min)
        return False, None


class AFamily(Requirement):
    def __init__(self, afamily):
        super().__init__(afamily=afamily)
        self.afamily = afamily
        self.connect_args = {"protocol": afamily}

    def is_met(self, cluster):
        # The address family is labeled using "inet" in /pools/nodes
        afamily_translate = {
            "ipv4": "inet",
            "ipv6": "inet6"
        }
        res = get_succ(cluster, "/pools/nodes")
        return all([node["addressFamily"] == afamily_translate[self.afamily]
                    for node in res.json()["nodes"]])


class Service(Enum):
    KV = "kv"
    INDEX = "index"
    QUERY = "n1ql"
    FTS = "fts"
    BACKUP = "backup"
    EVENTING = "eventing"
    CBAS = "cbas"


class Services(Requirement):
    def __init__(self, deploy: Union[List[Service], Dict[int, Service]]):
        if isinstance(deploy, list):
            self.deploy = [service.value for service in deploy]
        elif isinstance(deploy, dict):
            self.deploy = {node: service.value
                           for node, service in deploy.items()}
        else:
            raise ValueError(f"Invalid services: {deploy}. "
                             f"Expected a list or a dict.")
        super().__init__(deploy=self.deploy)

        self.connect_args = {"deploy": self.deploy}

    def is_met(self, cluster):
        for i, node in enumerate(cluster.connected_nodes):
            # We can't take information for all nodes from a single /pools/nodes
            # because we don't know which node is which
            res = get_succ(node, "/pools/nodes").json()
            this_node_services = []
            for node_info in res['nodes']:
                if 'thisNode' in node_info and node_info['thisNode']:
                    this_node_services = node_info['services']

            services_to_check = []
            if isinstance(self.deploy, list):
                services_to_check = self.deploy
            else:
                nname = f'n{i}'
                if nname in self.deploy:
                    services_to_check = self.deploy[nname]

            for s in services_to_check:
                if s not in this_node_services:
                    return False

        return True


# We are not enforcing it when creating a cluster (like by setting something
# in connect_args), because
# (1) in practice we only need to check that master password is not set, which
#     is the default behavior
# (2) it would be an extra work with no real benefit
#
# We also are not implementing make_met() because in order to do that we would
# need to use the API that we want to test (which would be strange)
class MasterPasswordState(Requirement):
    def __init__(self, state):
        super().__init__(master_password_state=state)
        self.master_password_state=state

    def is_met(self, cluster):
        for n in cluster.connected_nodes:
            r = get_succ(n, "/nodes/self/secretsManagement")
            r = r.json()
            pass_state = r['encryptionService']['passwordState']
            if pass_state != self.master_password_state:
                return False

        return True


class NumVbuckets(Requirement):
    def __init__(self, num_vbuckets):
        super().__init__(num_vbuckets=num_vbuckets)

        if num_vbuckets <= 0:
            raise ValueError("num_vbuckets needs to be > 0")

        if num_vbuckets > 1024:
            raise ValueError("num_vbuckets needs to be <= 1024")

        self.num_vbuckets = num_vbuckets
        self.start_args = {"num_vbuckets": num_vbuckets}

    def is_met(self, cluster):
        r = testlib.diag_eval(cluster,
                              code="ns_bucket:get_default_num_vbuckets()")
        default_num_vbuckets = r.content.decode('ascii')
        return int(default_num_vbuckets) == self.num_vbuckets


class N2nEncryption(Requirement):
    def __init__(self, encryption):
        super().__init__(encryption=encryption)
        self.encryption = encryption
        self.connect_args = {"encryption": encryption}

    def is_met(self, cluster):
        res = get_succ(cluster, "/pools/nodes")
        return all([node["nodeEncryption"] == self.encryption
                    for node in res.json()["nodes"]])

    def can_be_met(self):
        return True

    def make_met(self, cluster):
        cluster.toggle_n2n_encryption(enable=self.encryption)

# Intersects two limits where each limit is defined either by exact match,
# or by a min value. Note that min and exact params are mutually exclusive.
# If intersection is empty, the function returns False, None, None.
# If intersection is not empty, it returns True, NewMin, NewExact.
def intersect_limits(min_val1, exact_val1, min_val2, exact_val2):
    if exact_val1 is not None:
        if exact_val2 is not None:
            if exact_val1 != exact_val2:
                return False, None, None
        else: # min_val2 is set
            if exact_val1 < min_val2:
                return False, None, None
        return True, None, exact_val1
    else: # min_val1 is set
        if exact_val2 is not None:
            if exact_val2 < min_val1:
                return False, None, None
            return True, None, exact_val2
        else: # min_val2 is set
            return True, max(min_val1, min_val2), None
