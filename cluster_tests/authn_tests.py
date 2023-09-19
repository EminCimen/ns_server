# @author Couchbase <info@couchbase.com>
# @copyright 2023-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.
import testlib
import base64
import os
from scramp import ScramClient
import requests


class AuthnTests(testlib.BaseTestSet):

    @staticmethod
    def requirements():
        return testlib.ClusterRequirements(num_nodes=1)


    def setup(self):
        self.testEndpoint = "/pools/default"
        username = testlib.random_str(8)
        wrong_user = testlib.random_str(8)
        password = testlib.random_str(8)
        wrong_password = testlib.random_str(8)
        self.creds = (username, password)
        self.wrong_pass_creds = (username, wrong_password)
        self.wrong_user_creds = (wrong_user, password)
        testlib.put_succ(self.cluster, f'/settings/rbac/users/local/{username}',
                         data={'roles': 'ro_admin', 'password': password})


    def teardown(self):
        (username, password) = self.creds
        testlib.ensure_deleted(self.cluster,
                               f'/settings/rbac/users/local/{username}')


    def basic_auth_test(self):
        testlib.get_fail(self.cluster, '/pools/default', 401, auth=None)
        testlib.get_succ(self.cluster, self.testEndpoint, auth=self.creds)
        r = testlib.get_fail(self.cluster, self.testEndpoint, 401,
                             auth=self.wrong_user_creds)
        assert 'WWW-Authenticate' in r.headers
        assert 'Basic realm="Couchbase Server Admin / REST"' == r.headers['WWW-Authenticate']
        r = testlib.get_fail(self.cluster, self.testEndpoint, 401,
                             auth=self.wrong_pass_creds)
        assert 'WWW-Authenticate' in r.headers
        assert 'Basic realm="Couchbase Server Admin / REST"' == r.headers['WWW-Authenticate']
        r = testlib.get_fail(self.cluster, self.testEndpoint, 401,
                             auth=self.wrong_pass_creds,
                             headers={'invalid-auth-response':'on'})
        assert 'WWW-Authenticate' not in r.headers


    def scram_sha512_test(self):
        self.scram_sha_test_mech('SCRAM-SHA-512')


    def scram_sha256_test(self):
        self.scram_sha_test_mech('SCRAM-SHA-256')


    def scram_sha1_test(self):
        self.scram_sha_test_mech('SCRAM-SHA-1')


    def scram_sha_test_mech(self, mech):
        r = scram_sha_auth(mech, self.testEndpoint, self.creds, self.cluster)
        testlib.assert_http_code(200, r)
        r = scram_sha_auth(mech, self.testEndpoint, self.wrong_pass_creds,
                           self.cluster)
        testlib.assert_http_code(401, r)
        r = scram_sha_auth(mech, self.testEndpoint, self.wrong_user_creds,
                           self.cluster)
        testlib.assert_http_code(401, r)


    def local_token_test(self):
        tokenPath = os.path.join(self.cluster.connected_nodes[0].data_path(),
                                 "localtoken")
        with open(tokenPath, 'r') as f:
            token = f.read().rstrip()
            testlib.get_succ(self.cluster, '/diag/password',
                             auth=('@localtoken', token))
            testlib.get_fail(self.cluster, '/diag/password', 401,
                             auth=('@localtoken', token + 'foo'))


    def uitoken_test(self):
        (user, password) = self.creds
        (wrong_user, wrong_password) = self.wrong_pass_creds
        testlib.post_fail(self.cluster, '/uilogin', 400, auth=None,
                          data={'user': wrong_user, 'password': wrong_password})
        session = requests.Session()
        url = self.cluster.nodes[0].url + '/uilogin'
        headers={'Host': testlib.random_str(8), 'ns-server-ui': 'yes'}
        r = session.post(self.cluster.nodes[0].url + '/uilogin',
                         data={'user': user, 'password': password},
                         headers=headers)
        testlib.assert_http_code(200, r)
        r = session.get(self.cluster.nodes[0].url + self.testEndpoint,
                        headers=headers)
        testlib.assert_http_code(200, r)
        r = session.post(self.cluster.nodes[0].url + '/uilogout',
                         headers=headers)
        testlib.assert_http_code(200, r)
        r = session.get(self.cluster.nodes[0].url + self.testEndpoint,
                        headers=headers)
        testlib.assert_http_code(401, r)


    def on_behalf_of_test(self):
        (user, _) = self.creds
        OBO = base64.b64encode(f"{user}:local".encode('ascii')).decode()
        r = testlib.get_succ(self.cluster, '/whoami',
                             headers={'cb-on-behalf-of': OBO})
        res = r.json()
        assert [{'role': 'ro_admin'}] == res['roles']
        assert user == res['id']
        assert 'local' == res['domain']


def headerToScramMsg(header):
    replyDict = {}
    for t in header.split(","):
        k, v = tuple(t.split("=", 1))
        replyDict[k] = v
    assert 'data' in replyDict
    assert 'sid' in replyDict
    return replyDict


def scram_sha_auth(mech, testEndpoint, creds, cluster):
    (user, password) = creds
    c = ScramClient([mech], user, password)
    cfirst = c.get_client_first()
    cfirstBase64 = base64.b64encode(cfirst.encode('ascii')).decode()
    msg = f'realm="Couchbase Server Admin / REST",data={cfirstBase64}'
    r = testlib.get_fail(cluster, testEndpoint, 401, auth=None,
                         headers={'Authorization': mech + ' ' + msg})
    assert 'WWW-Authenticate' in r.headers
    reply = r.headers['WWW-Authenticate']
    if not reply.startswith(mech + ' '):
        raise ValueError(f"wrong 'WWW-Authenticate' value: {reply}")

    reply = reply[len(mech)+1:]
    replyDict = headerToScramMsg(reply)
    sid = replyDict['sid']
    sfirst = base64.b64decode(replyDict['data'].encode('ascii')).decode()
    c.set_server_first(sfirst)
    cfinal = c.get_client_final()
    cfinalBase64 = base64.b64encode(cfinal.encode('ascii')).decode()
    msg = f'sid={sid},data={cfinalBase64}'
    r = testlib.get(cluster, testEndpoint, auth=None,
                    headers={'Authorization': mech + ' ' + msg})
    if 'Authentication-Info' in r.headers:
        authInfo = r.headers['Authentication-Info']
        authInfoDict = headerToScramMsg(authInfo)
        ssignature = base64.b64decode(authInfoDict['data'].encode('ascii')).decode()
        c.set_server_final(ssignature)
    return r
