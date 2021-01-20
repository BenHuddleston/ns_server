# @author Couchbase <info@couchbase.com>
# @copyright 2011-2020 Couchbase, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
import os
import os.path
import subprocess
import sys
import shlex
import socket
import fnmatch
import platform
import errno
import shutil
import urllib.request
import urllib.parse
import urllib.error
import json
from functools import reduce

base_direct_port = 12000
base_api_port = 9000
base_couch_port = 9500
base_projector_port = 10000
base_xdcr_port = 13000
base_indexer_port = 9100
base_fts_port = 9200
base_eventing_port = 9300
base_cbas_port = 9600
base_prometheus_port = 9900
base_backup_http_port= 7100
base_backup_https_port= 17100
base_backup_grpc_port = 7200


def read_configuration():
    with open("build/cluster_run.configuration") as f:
        def fn(line):
            k, v = line.strip().split('=')
            return k, shlex.split(v)[0]

        return dict(fn(line) for line in f.readlines())


config = read_configuration()
PREFIX = config['prefix']

valid_bucket_types = ["ephemeral", "membase", "memcached"]
valid_service_types = {"kv", "n1ql", "index", "fts", "cbas", "eventing",
        "backup"}

def setup_extra_ns_server_app_file(force_community, start_index):
    # The extra/ebin directory contains modified versions of files also
    # contained in other directories.  The ones in extra/ebin are listed
    # in the path directory such that they will take precedence when
    # loaded.  Note the -pa option used when starting erl reverses the
    # order of the list.
    extra_dirname = "extra"
    extra_ebin_dirname = "{}/n_{}".format(extra_dirname, start_index)
    extra_ebin_path = extra_ebin_dirname + "/ebin"
    returned_path = None

    # Clean up any residual files from prior runs.
    try:
        if force_community:
            # Just delete the node-specific directory that we're going
            # to recreate with new content.  There could be concurrent
            # instances running so can't more than that.
            shutil.rmtree(extra_ebin_dirname)
        else:
            # Get rid of the entire directory as we don't want any residual
            # files being found when walking the directory (see ebin_seach).
            shutil.rmtree(extra_dirname)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            pass
        else:
            raise

    if force_community:
        found_enterprise = False
        with open("./ebin/ns_server.app", "r") as src_f:
            lines = src_f.readlines()

        lines_out = ""
        for line in lines:
            # The way to change Enterprise edition to Community edition is to
            # simply change the "vsn" in the ns_server app.
            if "vsn" in line and "enterprise" in line:
                line = line.replace("enterprise", "community")
                # Ensure only one line containing "vsn" and "enterprise".
                assert found_enterprise is False
                found_enterprise = True
            lines_out = lines_out + line

        if found_enterprise:
            # Any errors here are "real" so we want exceptions thrown
            os.makedirs(extra_ebin_path)

            with open("./{}/ns_server.app".format(
                    extra_ebin_path), "w") as dst_f:
                dst_f.write(lines_out)

            returned_path = extra_ebin_path

    return returned_path


def setup_path(ns_server_app_path):
    def ebin_search(path_name):
        dirs = os.walk(path_name)
        ebins = []

        for d, _, _ in dirs:
            if os.path.basename(d) == "ebin":
                ebins.append(d)

        return ebins

    path = ebin_search(".")
    if ns_server_app_path in path:
        # The ns_server_app_path needs to be first in the path. We remove
        # it from what was found and append it to the path (it's at the
        # end as the -pa argument used when starting erl reverses the
        # order).
        path.remove(ns_server_app_path)
        path.append(ns_server_app_path)

    couchpath = ebin_search("{0}/lib/couchdb/erlang/lib".format(PREFIX))
    couch_plugins = ebin_search("{0}/lib/couchdb/plugins".format(PREFIX))

    if len(couchpath) == 0:
        sys.exit("Couch libs wasn't found.\nCan't handle it")

    # Note the paths are passed via "-pa" to the erl process where their
    # ordering is reversed.
    return couchpath + path + couch_plugins


def maybe_mk_node_couch_config(i):
    ini_file_name = "couch/n_{0}_conf.ini".format(i)

    # If ini file exists, then don't overwrite it.
    if os.path.isfile(ini_file_name):
        return

    try:
        os.mkdir("couch")
    except os.error:
        pass

    with open(ini_file_name, "w") as f:
        f.write("[httpd]\n")
        f.write("port={0}\n".format(base_couch_port + i))
        f.write("[couchdb]\n")
        f.write("database_dir={0}/data/n_{1}/data\n".format(os.getcwd(), i))
        f.write("view_index_dir={0}/data/n_{1}/data\n".format(os.getcwd(), i))
        f.write("max_dbs_open=10000\n")
        f.write("[upr]\n")
        f.write("port={0}\n".format(base_direct_port + i * 2))
        f.write("[dcp]\n")
        f.write("port={0}\n".format(base_direct_port + i * 2))


def couch_configs(i):
    maybe_mk_node_couch_config(i)
    return ["{0}/etc/couchdb/default.ini".format(PREFIX),
            "{0}/etc/couchdb/default.d/capi.ini".format(PREFIX),
            "{0}/etc/couchdb/default.d/geocouch.ini".format(PREFIX),
            "couch/n_{0}_conf.ini".format(i)]


def os_specific(args, params):
    """Add os-specific junk to the cluster startup."""
    if platform.system() == 'Windows':
        args += ["dont_suppress_stderr_logger", "false"]
    else:
        args += ["dont_suppress_stderr_logger", "true"]
    if platform.system() == 'Darwin':
        import resource
        # OS X has a pretty tiny default fd limit.  Let's increase it
        # (if it hasn't already been).
        (soft, hard) = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < 4096:
            resource.setrlimit(resource.RLIMIT_NOFILE, (4096, 4096))
        params['env'] = {"ERL_MAX_PORTS": "4096"}
        params['env'].update(os.environ)


def prepare_start_cluster(force_community, start_index):
    ns_server_app_path = setup_extra_ns_server_app_file(force_community,
                                                        start_index)

    ebin_path = setup_path(ns_server_app_path)
    return ebin_path


def quote_string_for_erl(s):
    return '"' + s.replace("\\", "\\\\").replace("\"", "\\\"") + '"'


def generate_ssl_dist_optfile(datadir):
    cfg_dir = os.path.join(datadir, "config")
    in_file = os.path.join(os.getcwd(), "etc", "ssl_dist_opts.in")
    out_file = os.path.join(cfg_dir, "ssl_dist_opts")

    if not os.path.exists(cfg_dir):
        os.makedirs(cfg_dir, 0o755)

    with open(in_file) as f:
        content = f.read().replace('@CONFIG_PREFIX@', cfg_dir)

    with open(out_file, "w") as f:
        f.write(content)

    return out_file


def erlang_args_for_node(i, ebin_path, extra_args, args_prefix):
    logdir = os.path.abspath("logs/n_{0}".format(i))

    args = args_prefix + ["erl", "+MMmcs" "30",
                          "+A", "16", "+sbtu",
                          "+sbwt", "none",
                          "+P", "327680", "-pa"] + ebin_path
    args += [
        "-setcookie", "nocookie",
        "-kernel", "logger", "[{handler, default, undefined}]",
        "-couch_ini"] + couch_configs(i)

    datadir = os.path.abspath('data/n_{0}'.format(i))
    tempdir = os.path.abspath('tmp/')
    nodefile = os.path.join(datadir, "nodefile")
    babysitternodefile = os.path.join(
        datadir, "couchbase-server.babysitter.node")
    babysittercookiefile = os.path.join(
        datadir, "couchbase-server.babysitter.cookie")
    ssloptfile = generate_ssl_dist_optfile(datadir)
    cb_dist_config = os.path.join(datadir, "config", "dist_cfg")

    args += [
        "-name", "babysitter_of_n_{0}@cb.local".format(i),
        "-proto_dist", "cb",
        "-ssl_dist_optfile", ssloptfile,
        "-epmd_module", "cb_epmd",
        "-hidden",
        "-kernel", "dist_config_file", quote_string_for_erl(cb_dist_config),
        "-kernel", "inetrc", "\"etc/hosts.cfg\"",
        "-kernel", "external_tcp_port", "21400",
        "-kernel", "external_tls_port", "21450",
        "-ns_babysitter", "cookiefile", quote_string_for_erl(
            babysittercookiefile),
        "-ns_babysitter", "nodefile", quote_string_for_erl(babysitternodefile),
        "-ns_server", "config_path", '"etc/static_config.in"',
        "error_logger_mf_dir", quote_string_for_erl(logdir),
        "path_config_etcdir", '"priv"',
        "path_config_bindir", quote_string_for_erl(PREFIX + "/bin"),
        "path_config_libdir", quote_string_for_erl(PREFIX + "/lib"),
        "path_config_datadir", quote_string_for_erl(datadir),
        "path_config_tmpdir", quote_string_for_erl(tempdir),
        "path_config_secdir", quote_string_for_erl(PREFIX + "/etc/security"),
        "path_audit_log", quote_string_for_erl(logdir),
        "rest_port", str(base_api_port + i),
        "query_port", str(base_couch_port - 1 - i),
        "ssl_query_port", str(10000 + base_couch_port - 1 - i),
        "projector_port", str(base_projector_port + i),
        "projector_ssl_port", str(base_projector_port + i),
        "ssl_rest_port", str(10000 + base_api_port + i),
        "capi_port", str(base_couch_port + i),
        "ssl_capi_port", str(10000 + base_couch_port + i),
        "memcached_port", str(base_direct_port + i * 2),
        "memcached_dedicated_port", str(base_direct_port - i * 4 - 1),
        "memcached_ssl_port", str(base_direct_port - i * 4 - 2),
        "memcached_dedicated_ssl_port", str(base_direct_port - i * 4 - 3),
        "memcached_prometheus", str(base_direct_port - i * 4 - 4),
        "nodefile", quote_string_for_erl(nodefile),
        "short_name", quote_string_for_erl('n_{0}'.format(i)),
        "xdcr_rest_port", str(base_xdcr_port + i),
        "indexer_admin_port", str(base_indexer_port + i * 6),
        "indexer_scan_port", str(base_indexer_port + i * 6 + 1),
        "indexer_http_port", str(base_indexer_port + i * 6 + 2),
        "indexer_https_port", str(10000 + base_indexer_port + i * 6 + 2),
        "indexer_stinit_port", str(base_indexer_port + i * 6 + 3),
        "indexer_stcatchup_port", str(base_indexer_port + i * 6 + 4),
        "indexer_stmaint_port", str(base_indexer_port + i * 6 + 5),
        "fts_http_port", str(base_fts_port + i * 2),
        "fts_ssl_port", str(10000 + base_fts_port + i * 2),
        "fts_grpc_port", str(base_fts_port + i * 2 + 1),
        "fts_grpc_ssl_port", str(10000 + base_fts_port + i * 2 + 1),
        "eventing_http_port", str(base_eventing_port + i),
        "eventing_https_port", str(10000 + base_eventing_port + i),
        "eventing_debug_port", str(base_eventing_port + i * 6 + 1),
        "cbas_http_port", str(base_cbas_port + i * 15),
        "cbas_cc_http_port", str(base_cbas_port + i * 15 + 1),
        "cbas_cc_cluster_port", str(base_cbas_port + i * 15 + 2),
        "cbas_cc_client_port", str(base_cbas_port + i * 15 + 3),
        "cbas_console_port", str(base_cbas_port + i * 15 + 4),
        "cbas_cluster_port", str(base_cbas_port + i * 15 + 5),
        "cbas_data_port", str(base_cbas_port + i * 15 + 6),
        "cbas_result_port", str(base_cbas_port + i * 15 + 7),
        "cbas_messaging_port", str(base_cbas_port + i * 15 + 8),
        "cbas_debug_port", str(base_cbas_port + i * 15 + 9),
        "cbas_parent_port", str(base_cbas_port + i * 15 + 10),
        "cbas_admin_port", str(base_cbas_port + i * 15 + 11),
        "cbas_replication_port", str(base_cbas_port + i * 15 + 12),
        "cbas_metadata_port", str(base_cbas_port + i * 15 + 13),
        "cbas_metadata_callback_port", str(base_cbas_port + i * 15 + 14),
        "cbas_ssl_port", str(10000 + base_cbas_port + i),
        "prometheus_http_port", str(base_prometheus_port + i),
        "backup_http_port", str(base_backup_http_port + i),
        "backup_https_port", str(base_backup_https_port + i),
        "backup_grpc_port", str(base_backup_grpc_port + i),

    ] + extra_args

    return args

def find_primary_addr(ipv6):
    family = socket.AF_INET6 if ipv6 else socket.AF_INET
    dns_addr = "2001:4860:4860::8844" if ipv6 else "8.8.8.8"
    s = socket.socket(family, socket.SOCK_DGRAM)
    try:
        s.connect((dns_addr, 53))
        if ipv6:
            addr, port, _, _ = s.getsockname()
        else:
            addr, port = s.getsockname()

        return addr
    except socket.error:
        return None
    finally:
        s.close()

def start_cluster(num_nodes=1,
                  dont_start=False,
                  start_index=0,
                  dont_rename=False,
                  static_cookie=False,
                  loglevel='debug',
                  prepend_extras=False,
                  pluggable_config=[],
                  use_minified=False,
                  disable_autocomplete="{disable_autocomplete,false}",
                  pretend_version=None,
                  ipv6=False,
                  force_community=False,
                  dev_preview_default=None,
                  args=[]):

    extra_args = []
    if not dont_rename:
        primary_addr = find_primary_addr(ipv6)
        if primary_addr is None:
            print("was unable to detect 'internet' address of this machine."
                  + " node rename will be disabled")
        else:
            extra_args += ["rename_ip", '"' + primary_addr + '"']

    if prepend_extras:
        prepend_args = args[0:]
    else:
        prepend_args = []
        extra_args += args[0:]

    if static_cookie:
        extra_args += ["-ns_server", "dont_reset_cookie", "true"]

    if dont_start:
        extra_args += ["-run", "t", "fake_loggers"]
    else:
        extra_args += ["-noinput"]
        extra_args += ["-run", "child_erlang", "child_start",
                       "ns_babysitter_bootstrap"]
        extra_args += ["-ns_babysitter", "handle_ctrl_c", "true"]

    extra_args += ["-ns_server", "loglevel_stderr", loglevel]

    plugins_dir = '../build/cluster_run_ui_plugins'
    if os.path.isdir(plugins_dir):
        for f in os.listdir(plugins_dir):
            if fnmatch.fnmatch(f, 'pluggable-ui-*.cluster_run.json'):
                pluggable_config.append(os.path.join(plugins_dir, f))

    if pluggable_config:
        extra_args += ["-ns_server", "ui_plugins",
                       quote_string_for_erl(','.join(pluggable_config))]

    ui_env = [disable_autocomplete]

    extra_args += ["-ns_server", "use_minified",
                   "true" if use_minified else "false"]
    extra_args += ["-ns_server", "ui_env", '[' + ','.join(ui_env) + ']']

    if pretend_version is not None:
        extra_args += ["-ns_server",
                       "pretend_version", '"{}"'.format(pretend_version)]

    if dev_preview_default is not None:
        extra_args += ["-ns_server", "developer_preview_enabled_default",
                       "true" if dev_preview_default else "false"]

    ebin_path = prepare_start_cluster(force_community, start_index)

    def start_node(node_num):
        logdir = "logs/n_{0}".format(node_num)
        try:
            os.makedirs(logdir)
        except OSError:
            pass

        args = erlang_args_for_node(node_num, ebin_path, extra_args,
                                    prepend_args)

        params = {}

        os_specific(args, params)

        if 'env' not in params:
            params['env'] = {}
            params['env'].update(os.environ)
        path = params['env']['PATH']
        path = (PREFIX + "/bin") + os.pathsep + path
        if 'ERL_FULLSWEEP_AFTER' not in params['env']:
            params['env']['ERL_FULLSWEEP_AFTER'] = '512'
        params['env']['PATH'] = path

        crash_dump_base = 'erl_crash.dump.n_%d' % node_num
        params['env']['ERL_CRASH_DUMP_BASE'] = crash_dump_base
        params['env']['ERL_CRASH_DUMP'] = crash_dump_base + '.babysitter'

        params['env']['COUCHBASE_SMALLER_PKEYS'] = '1'

        params['close_fds'] = True
        if platform.system() == "Windows":
            params['close_fds'] = False

        w = None
        r = None

        if "-noinput" in args:
            (r, w) = os.pipe()

            params['stdin'] = r

            if 'setpgrp' in os.__dict__ and params.get('close_fds'):
                # this puts child out of our process group. So that
                # Ctrl-C doesn't deliver SIGINT to it, leaving us
                # ability to it shutdown carefully or otherwise
                params['preexec_fn'] = os.setpgrp

        pr = subprocess.Popen(args, **params)
        if w is not None:
            os.close(r)

        # Squirrel away the write descriptor for the pipe into the
        # subprocess.Popen object
        pr.write_side = w

        return pr

    return [start_node(i + start_index) for i in range(num_nodes)]


def kill_nodes(nodes, terminal_attrs=None):
    for n in nodes:
        if n.write_side is not None:
            print("Closing %d\n" % n.write_side)
            # this line does graceful shutdown versus quick
            # os.write(n.write_side, "shutdown\n")
            os.close(n.write_side)
        else:
            try:
                n.kill()
            except OSError:
                pass

    for n in nodes:
        n.wait()

    if terminal_attrs is not None:
        import termios
        termios.tcsetattr(sys.stdin, termios.TCSANOW, terminal_attrs)


def bool_request_value(value):
    return "1" if value else "0"


class PasswordManager(urllib.request.HTTPPasswordMgr):
    def __init__(self, username, password):
        self.auth = (username, password)

    def find_user_password(self, realm, authuri):
        return self.auth


def do_encode(input_string):
    return input_string.encode()


def connect(num_nodes=0,
            deploy=['kv'],
            buckettype="membase",
            memsize=256,
            indexmemsize=256,
            index_storage_mode=None,
            replicas=1,
            replica_index=True,
            protocol="ipv4",
            encryption=False,
            do_rebalance=True,
            storage_backend="couchstore"):
    if isinstance(deploy, list):
        services = deploy
        deploy = dict(("n%d" % i, services[:]) for i in range(num_nodes))

    if "kv" not in deploy.get("n0", []):
        deploy["n0"] = deploy.get("n0", []) + ["kv"]

    if num_nodes == 0 or buckettype not in valid_bucket_types or \
            int(memsize) < 256 or int(replicas) > 3 or \
            not set(deploy.keys()) <= \
            set(["n" + str(i) for i in range(num_nodes)]) or \
            not set(reduce(lambda x, y: x + y, deploy.values(), [])) <= \
            valid_service_types:
        usage()
        sys.exit()

    password_mgr = PasswordManager("Administrator", "asdasd")
    handler = urllib.request.HTTPBasicAuthHandler(password_mgr)
    o = urllib.request.build_opener(handler)

    print("Connecting {0} nodes, bucket type {1}, mem size {2} "
          "with {3} replica copies, password asdasd, "
          "deployment plan {4}\n".format(
              num_nodes, buckettype, memsize, replicas, str(deploy)))

    base_port = 9000

    addr = "127.0.0.1" if protocol == "ipv4" else "[::1]"
    services = deploy["n0"]
    print("Connecting node 0 with services {0}".format(str(services)))

    info = json.loads(o.open("http://{0}:{1}/pools".format(
        addr, base_port)).read())
    community_edition = info['isEnterprise'] is not True

    net_opts = do_encode(
        "afamily={0}".format(protocol) +
        "&nodeEncryption={0}".format(
            "on" if encryption else "off"))
    o.open("http://{0}:{1}/node/controller/enableExternalListener".format(
           addr, base_port), net_opts)
    o.open("http://{0}:{1}/node/controller/setupNetConfig".format(
           addr, base_port), net_opts)
    data = do_encode("services={0}".format(",".join(services)))
    o.open("http://{0}:{1}/node/controller/setupServices".format(
           addr, base_port), data).read()
    data = do_encode("memoryQuota=" + str(memsize) +
                     "&indexMemoryQuota=" + str(indexmemsize))
    o.open("http://{0}:{1}/pools/default".format(addr, base_port), data).read()
    data = do_encode("name=default" +
                     "&authType=sasl" +
                     "&saslPassword=" +
                     "&bucketType=" + buckettype +
                     "&storageBackend=" + storage_backend +
                     "&ramQuotaMB=" + str(memsize) +
                     "&replicaNumber=" + str(replicas) +
                     "&replicaIndex=" + bool_request_value(replica_index))
    o.open("http://{0}:{1}/pools/default/buckets".format(addr, base_port),
           data).read()
    data = do_encode("port=SAME&username=Administrator&password=asdasd")
    o.open("http://{0}:{1}/settings/web".format(addr, base_port),
           data).read()
    if index_storage_mode is not None:
        o.open("http://{0}:{1}/settings/indexes".format(addr, base_port),
               do_encode("storageMode=" + index_storage_mode)).read()

    for i in range(1, num_nodes):
        port = base_port + i
        services = deploy.get("n" + str(i), [])
        if not services:
            services = ["kv"]
        print("Connecting node {0} with services {1}".format(i, str(services)))
        cluster_member_port = base_port if community_edition else \
            base_port + 10000
        data = do_encode("user=Administrator&password=asdasd&" +
                         "clusterMemberHostIp={0}".format(addr) +
                         "&clusterMemberPort={0}".format(cluster_member_port) +
                         "&services={0}".format(",".join(services)))
        o.open("http://{0}:{1}/node/controller/doJoinCluster".format(
               addr, port), data).read()

    if do_rebalance:
        print("Getting node list")
        info = json.loads(o.open("http://{0}:{1}/nodeStatuses".format(
            addr, base_port)).read())

        print("Servers added, triggering rebalance.")
        data = do_encode(urllib.parse.urlencode(
            {'knownNodes': ",".join([info[k]['otpNode'] for k in info]),
                'ejectedNodes': ''}))

        o.open("http://{0}:{1}/controller/rebalance".format(addr, base_port),
               data).read()
