# @author Couchbase <info@couchbase.com>
# @copyright 2023-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.
import testlib
import os
import ipaddress
import subprocess

scriptdir = os.path.dirname(os.path.realpath(__file__))
certs_path = os.path.join(scriptdir, 'resources', 'test_certs')
generate_cert_path = os.path.join(scriptdir, '..', 'deps', 'gocode', 'bin',
                                  'generate_cert')
openssl_path = os.path.join(scriptdir, '..', '..', 'install', 'bin', 'openssl')


class CertLoadTests(testlib.BaseTestSet):

    @staticmethod
    def requirements():
        return testlib.ClusterRequirements(edition='Enterprise')

    def setup(self):
        ca_path = os.path.join(certs_path, 'test_CA.pem')
        with open(ca_path, 'r') as f:
            self.ca_pem = f.read()
        ca_key = os.path.join(certs_path, 'test_CA.pkey')
        with open(ca_key, 'r') as f:
            self.ca_key = f.read()

        self.node_addr = self.cluster.connected_nodes[0].addr()
        self.loaded_CA_ids = load_ca(self.cluster.connected_nodes[0],
                                     self.ca_pem)

    def teardown(self):
        testlib.post_succ(self.cluster, '/controller/regenerateCertificate',
                          params={'forceResetCACertificate': 'false',
                                  'dropUploadedCertificates': 'true'})
        for ca_id in self.loaded_CA_ids:
            testlib.delete_succ(self.cluster,
                                f'/pools/default/trustedCAs/{ca_id}',
                                expected_code=204)

    def rsa_private_key_test(self):
        self.generate_and_load_node_cert('rsa')

    def ec_private_key_test(self):
        self.generate_and_load_node_cert('ec')

    def generate_and_load_node_cert(self, key_type):
        cert, key = generate_node_certs(self.node_addr,
                                        self.ca_pem, self.ca_key,
                                        key_type=key_type)
        load_node_cert(self.cluster.connected_nodes[0], cert, key)

    def pkcs12_certs_test(self):
        cert, key = generate_node_certs(self.node_addr,
                                        self.ca_pem, self.ca_key,
                                        key_type='rsa')
        node_data_path = self.cluster.connected_nodes[0].data_path()
        inbox_dir = os.path.join(node_data_path, 'inbox')
        os.makedirs(inbox_dir, exist_ok=True)
        pkcs12_path = os.path.join(inbox_dir, 'couchbase.p12')
        try:
            write_pkcs12(cert, key, pkcs12_path)
            testlib.post_succ(self.cluster,
                              '/node/controller/reloadCertificate')
        finally:
            if os.path.exists(pkcs12_path):
                os.remove(pkcs12_path)


def load_node_cert(node, cert, key):
    inbox_dir = os.path.join(node.data_path(), 'inbox')
    chain_path = os.path.join(inbox_dir, 'chain.pem')
    pkey_path = os.path.join(inbox_dir, 'pkey.key')
    os.makedirs(inbox_dir, exist_ok=True)
    try:
        with open(chain_path, 'w') as f:
            f.write(cert)
        with open(pkey_path, 'w') as f:
            f.write(key)

        testlib.post_succ(node, '/node/controller/reloadCertificate')
    finally:
        if os.path.exists(chain_path):
            os.remove(chain_path)
        if os.path.exists(pkey_path):
            os.remove(pkey_path)


def load_ca(node, CA):
    ca_dir = os.path.join(node.data_path(), 'inbox', 'CA')
    ca_path = os.path.join(ca_dir, 'ca.pem')
    os.makedirs(ca_dir, exist_ok=True)
    try:
        with open(ca_path, 'w') as f:
            f.write(CA)

        r = testlib.post_succ(node, '/node/controller/loadTrustedCAs')
        r = r.json()
        # Returning a list mostly to handle the case when that certificate
        # is already loaded. In this case we don't need to remove it in
        # teardown()
        return [c['id'] for c in r]
    finally:
        if os.path.exists(ca_path):
            os.remove(ca_path)


def generate_node_certs(node_addr, CA, CAKey, key_type='rsa'):
    try:
        ipaddress.ip_address(node_addr)
        is_raw = True
    except ValueError:
        is_raw = False

    args = ['--generate-leaf', '--common-name', 'TEST Server Node',
            '--san-ip-addrs' if is_raw else '--san-dns-names', node_addr,
            '--pkey-type', key_type]

    env = {'CACERT': CA, 'CAPKEY': CAKey}

    r = subprocess.run([generate_cert_path] + args,
                       capture_output=True, env=env)
    assert r.returncode == 0, f'generate_cert returned {r.returncode}'

    separator = '-----END CERTIFICATE-----'
    tokens = r.stdout.decode().split(separator)
    assert len(tokens) == 2, f'unexpected return of generate_cert: {r.output}'
    cert = tokens[0] + separator
    key = tokens[1]
    print(f'Generated cert: {cert}\nGenerated key: {key}')
    return (cert, key)


def write_pkcs12(cert, key, out_file):
    s = testlib.random_str(8)
    in_key_path = os.path.join(os.path.dirname(out_file), f"temp_key_{s}.pem")
    in_crt_path = os.path.join(os.path.dirname(out_file), f"temp_cert_{s}.pem")
    try:
        with open(in_key_path, 'w') as f:
            f.write(key)
        with open(in_crt_path, 'w') as f:
            f.write(cert)
        args = ['pkcs12', '-export', '-keypbe',  'NONE', '-certpbe', 'NONE',
                '-nomaciter', '-out', out_file, '-inkey', in_key_path, '-in',
                in_crt_path, '-passout', 'pass:']
        r = subprocess.run([openssl_path] + args, capture_output=True)
        assert r.returncode == 0, f'openssl pkcs12 returned {r.returncode}\n' \
                                  f'stdout: {r.stdout.decode()}\n' \
                                  f'stderr: {r.stderr.decode()}'
    finally:
        if os.path.exists(in_crt_path):
            os.remove(in_crt_path)
        if os.path.exists(in_key_path):
            os.remove(in_key_path)
