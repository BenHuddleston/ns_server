%% @author Couchbase <info@couchbase.com>
%% @copyright 2010-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc Macros used all over the place.
%%

-ifndef(_NS_COMMON__HRL_).
-define(_NS_COMMON__HRL_,).

-type bucket_name() :: nonempty_string().
-type bucket_type() :: memcached | membase.
-type vbucket_map() :: [[atom(), ...], ...].
-type mc_error_atom() :: key_enoent | key_eexists | e2big | einval |
                         not_stored | delta_badval | not_my_vbucket |
                         unknown_command | enomem | not_supported | internal |
                         ebusy | etmpfail | auth_error | auth_continue.
-type mc_error() :: {memcached_error, mc_error_atom(), binary() | undefined}.
-type vbucket_id() :: non_neg_integer().
-type vbucket_state() :: active | dead | replica | pending.
-type rev_id() :: <<_:128>>.
-type seq_no() :: non_neg_integer().
-type rev() :: {seq_no(), rev_id()}.
-type rebalance_vbucket_state() :: passive | undefined | paused.
-type janitor_item() :: services | {bucket, bucket_name()}.

-type ext_bucket_name() :: bucket_name() | binary().
%% ext vbucket id is vbucket id (potentially as binary) or <<"master">>
-type ext_vbucket_id() :: vbucket_id() | binary().

-type version() :: {list(integer()), candidate | release, integer()}.

-type dcp_error() :: {dcp_error, mc_error_atom(), binary()}.
-type dcp_conn_name() :: nonempty_string().
-type dcp_conn_type() :: consumer | producer | notifier.

-type service() :: kv | index | n1ql | fts | eventing | cbas | backup.
-type tcp_port() :: 0..65535.

-define(MULTICALL_DEFAULT_TIMEOUT, 30000).

-define(MIB, 1048576).

-define(MAX_BUCKETS_SUPPORTED, 30).

-define(MAX_SCOPES_SUPPORTED, 1200).
-define(MAX_COLLECTIONS_SUPPORTED, 1200).

-define(MAX_DCP_CONNECTION_NAME, 200).

-define(DEFAULT_LOG_FILENAME, "info.log").
-define(ERRORS_LOG_FILENAME, "error.log").
-define(VIEWS_LOG_FILENAME, "views.log").
-define(MAPREDUCE_ERRORS_LOG_FILENAME, "mapreduce_errors.log").
-define(COUCHDB_LOG_FILENAME, "couchdb.log").
-define(DEBUG_LOG_FILENAME, "debug.log").
-define(XDCR_TARGET_LOG_FILENAME, "xdcr_target.log").
-define(STATS_LOG_FILENAME, "stats.log").
-define(BABYSITTER_LOG_FILENAME, "babysitter.log").
-define(NS_COUCHDB_LOG_FILENAME, "ns_couchdb.log").
-define(REPORTS_LOG_FILENAME, "reports.log").
-define(ACCESS_LOG_FILENAME, "http_access.log").
-define(INT_ACCESS_LOG_FILENAME, "http_access_internal.log").
-define(GOXDCR_LOG_FILENAME, "goxdcr.log").
-define(QUERY_LOG_FILENAME, "query.log").
-define(PROJECTOR_LOG_FILENAME, "projector.log").
-define(INDEXER_LOG_FILENAME, "indexer.log").
-define(METAKV_LOG_FILENAME, "metakv.log").
-define(FTS_LOG_FILENAME, "fts.log").
-define(JSON_RPC_LOG_FILENAME, "json_rpc.log").
-define(EVENTING_LOG_FILENAME, "eventing.log").
-define(CBAS_LOG_FILENAME, "analytics_info.log").
-define(BACKUP_LOG_FILENAME, "backup_service.log").
-define(TLS_KEY_LOG_FILENAME, "key.log").

-define(NS_SERVER_LOGGER, ns_server).
-define(COUCHDB_LOGGER, couchdb).
-define(USER_LOGGER, user).
-define(MENELAUS_LOGGER, menelaus).
-define(NS_DOCTOR_LOGGER, ns_doctor).
-define(STATS_LOGGER, stats).
-define(REBALANCE_LOGGER, rebalance).
-define(CLUSTER_LOGGER, cluster).
-define(VIEWS_LOGGER, views).
%% The mapreduce logger is used by the couchdb component, hence don't wonder
%% if you can't find any calls to it in ns_server
-define(MAPREDUCE_ERRORS_LOGGER, mapreduce_errors).
-define(XDCR_LOGGER, xdcr).
-define(ACCESS_LOGGER, access).
-define(METAKV_LOGGER, metakv).
-define(JSON_RPC_LOGGER, json_rpc).
-define(CHRONICLE_ALE_LOGGER, chronicle).
-define(TLS_KEY_LOGGER, tls_key).

-define(LOGGERS, [?NS_SERVER_LOGGER,
                  ?USER_LOGGER, ?MENELAUS_LOGGER,
                  ?NS_DOCTOR_LOGGER, ?STATS_LOGGER,
                  ?REBALANCE_LOGGER, ?CLUSTER_LOGGER,
                  ?XDCR_LOGGER, ?METAKV_LOGGER,
                  ?JSON_RPC_LOGGER]).

-define(NS_COUCHDB_LOGGERS, [?NS_SERVER_LOGGER,
                             ?COUCHDB_LOGGER,
                             ?VIEWS_LOGGER,
                             ?MAPREDUCE_ERRORS_LOGGER,
                             ?XDCR_LOGGER]).

-define(ALE_LOG(Level, Format, Args),
        ale:log(?NS_SERVER_LOGGER, Level, Format, Args)).

%% ale:{log, error, debug, warning, critical} are parse transformed to
%% add the Module, Function, Line of the caller.
%%
%% If new definitions are added to the loggers defined below, make sure
%% the parse transform logic works on those too.

-define(log_debug(Format, Args, Opts), ale:debug(?NS_SERVER_LOGGER, Format, Args, Opts)).
-define(log_debug(Format, Args), ale:debug(?NS_SERVER_LOGGER, Format, Args)).
-define(log_debug(Msg), ale:debug(?NS_SERVER_LOGGER, Msg)).

-define(log_info(Format, Args, Opts), ale:info(?NS_SERVER_LOGGER, Format, Args, Opts)).
-define(log_info(Format, Args), ale:info(?NS_SERVER_LOGGER, Format, Args)).
-define(log_info(Msg), ale:info(?NS_SERVER_LOGGER, Msg)).

-define(log_warning(Format, Args, Opts), ale:warn(?NS_SERVER_LOGGER, Format, Args, Opts)).
-define(log_warning(Format, Args), ale:warn(?NS_SERVER_LOGGER, Format, Args)).
-define(log_warning(Msg), ale:warn(?NS_SERVER_LOGGER, Msg)).

-define(log_error(Format, Args, Opts), ale:error(?NS_SERVER_LOGGER, Format, Args, Opts)).
-define(log_error(Format, Args), ale:error(?NS_SERVER_LOGGER, Format, Args)).
-define(log_error(Msg), ale:error(?NS_SERVER_LOGGER, Msg)).

%% Log to user visible logs using combination of ns_log and ale routines.
-define(user_log(Code, Msg), ?user_log_mod(?MODULE, Code, Msg)).
-define(user_log_mod(Module, Code, Msg),
        ale:xlog(?USER_LOGGER, ns_log_sink:get_loglevel(Module, Code),
                 {Module, Code}, Msg)).

-define(user_log(Code, Fmt, Args), ?user_log_mod(?MODULE, Code, Fmt, Args)).
-define(user_log_mod(Module, Code, Fmt, Args),
        ale:xlog(?USER_LOGGER, ns_log_sink:get_loglevel(Module, Code),
                 {Module, Code}, Fmt, Args)).

-define(rebalance_debug(Format, Args),
        ale:debug(?REBALANCE_LOGGER, Format, Args)).
-define(rebalance_debug(Msg), ale:debug(?REBALANCE_LOGGER, Msg)).

-define(rebalance_info(Format, Args),
        ale:info(?REBALANCE_LOGGER, Format, Args)).
-define(rebalance_info(Msg), ale:info(?REBALANCE_LOGGER, Msg)).

-define(rebalance_warning(Format, Args),
        ale:warn(?REBALANCE_LOGGER, Format, Args)).
-define(rebalance_warning(Msg), ale:warn(?REBALANCE_LOGGER, Msg)).

-define(rebalance_error(Format, Args),
        ale:error(?REBALANCE_LOGGER, Format, Args)).
-define(rebalance_error(Msg), ale:error(?REBALANCE_LOGGER, Msg)).

-define(views_debug(Format, Args), ale:debug(?VIEWS_LOGGER, Format, Args)).
-define(views_debug(Msg), ale:debug(?VIEWS_LOGGER, Msg)).

-define(views_info(Format, Args), ale:info(?VIEWS_LOGGER, Format, Args)).
-define(views_info(Msg), ale:info(?VIEWS_LOGGER, Msg)).

-define(views_warning(Format, Args), ale:warn(?VIEWS_LOGGER, Format, Args)).
-define(views_warning(Msg), ale:warn(?VIEWS_LOGGER, Msg)).

-define(views_error(Format, Args), ale:error(?VIEWS_LOGGER, Format, Args)).
-define(views_error(Msg), ale:error(?VIEWS_LOGGER, Msg)).

-define(xdcr_debug(Format, Args), ale:debug(?XDCR_LOGGER, Format, Args)).
-define(xdcr_debug(Msg), ale:debug(?XDCR_LOGGER, Msg)).

-define(xdcr_info(Format, Args), ale:info(?XDCR_LOGGER, Format, Args)).
-define(xdcr_info(Msg), ale:info(?XDCR_LOGGER, Msg)).

-define(xdcr_warning(Format, Args), ale:warn(?XDCR_LOGGER, Format, Args)).
-define(xdcr_warning(Msg), ale:warn(?XDCR_LOGGER, Msg)).

-define(xdcr_error(Format, Args), ale:error(?XDCR_LOGGER, Format, Args)).
-define(xdcr_error(Msg), ale:error(?XDCR_LOGGER, Msg)).

-define(metakv_debug(Format, Args), ale:debug(?METAKV_LOGGER, Format, Args)).
-define(metakv_debug(Msg), ale:debug(?METAKV_LOGGER, Msg)).

-define(tls_key_log(Msg), ale:debug(?TLS_KEY_LOGGER, Msg)).

-define(get_timeout(Op, Default), ns_config:get_timeout({?MODULE, Op}, Default)).
-define(get_param(Param, Default),
        ns_config:search_node_with_default({?MODULE, Param}, Default)).

-define(REBALANCE_OBSERVER_TASK_DEFAULT_TIMEOUT,
        ?get_timeout(observer_task, 10000)).

-define(i2l(V), integer_to_list(V)).

-define(UI_AUTH_EXPIRATION_SECONDS, 600).

%% XDCR_CHECKPOINT_STORE is the name of the simple-store where
%% metakv stores XDCR checkpoints.
-define(XDCR_CHECKPOINT_STORE, xdcr_ckpt_data).

%% Pattern used to identify XDCR checkpoints.
-define(XDCR_CHECKPOINT_PATTERN, list_to_binary("/ckpt/")).

%% Metakv tag for values storing sensitive information
%% If this tag is changed to something else, then do not forget
%% to change its value in ns_server/scripts/dump-guts as well.
-define(METAKV_SENSITIVE, metakv_sensitive).

-define(MIN_FREE_RAM, misc:get_env_default(quota_min_free_ram, 1024)).
-define(MIN_FREE_RAM_PERCENT, 80).

-define(DEFAULT_EPHEMERAL_PURGE_INTERVAL_DAYS, 1).

%% Default quota is 5GiB but the unit is MiB.
-define(QUERY_TMP_SPACE_DEF_SIZE, 5120).

%% Index storage mode values.
-define(INDEX_STORAGE_MODE_MEMORY_OPTIMIZED, <<"memory_optimized">>).
-define(INDEX_STORAGE_MODE_FORESTDB, <<"forestdb">>).
-define(INDEX_STORAGE_MODE_PLASMA, <<"plasma">>).
-define(DEFAULT_MAX_ROLLBACK_PTS_PLASMA, 2).
-define(DEFAULT_MAX_ROLLBACK_PTS_FORESTDB, 5).

%% common memcached settings are ints which is usually 32-bits wide
-define(MC_MAXINT, 16#7FFFFFFF).

%% Many memcached bucket parameters use size_t which will almost certainly be a
%% 64 bit unsigned integer. We should prevent larger values than this being
%% passed to memcached as it will likely throw an error.
-define(MAX_64BIT_UNSIGNED_INT, 16#FFFFFFFFFFFFFFFF).

-define(VERSION_65, [6, 5]).
-define(VERSION_66, [6, 6]).
-define(VERSION_70, [7, 0]).
-define(VERSION_71, [7, 1]).
-define(VERSION_72, [7, 2]).
-define(VERSION_ELIXIR, [7, 5]).

%% This require coordination with the UI to update the version.
-define(LATEST_UI_COMPAT_VERSION, ?VERSION_70).

%% Points to latest release
-define(LATEST_VERSION_NUM, ?VERSION_ELIXIR).
-define(MASTER_ADVERTISED_VERSION, [7, 5, 0]).

-define(MIN_OF_MAX_MOVES_PER_NODE, 1).
-define(MAX_OF_MAX_MOVES_PER_NODE, 64).
-define(DEFAULT_MAX_MOVES_PER_NODE, 4).

-define(flush(Pattern),
        misc:letrec([0],
                    fun (Rec, I) ->
                            receive
                                Pattern ->
                                    Rec(Rec, I+1)
                            after
                                0 ->
                                    I
                            end
                    end)).

-define(must_flush(Pattern), ?must_flush(Pattern, 1, 15000)).
-define(must_flush(Pattern, N, Timeout),
        misc:letrec(
          [0],
          fun (_Rec, I)
                when I =:= N ->
                  ok;
              (Rec, I) ->
                  receive
                      Pattern ->
                          Rec(Rec, I + 1)
                  after
                      Timeout ->
                          throw({error, {no_messages, Timeout, ??Pattern}})
                  end
          end)).

%% Maximum number of non-self-issued intermediate certificates that can follow
%% the peer certificate in a valid certification path. So, if depth is 0 the
%% PEER must be signed by the trusted ROOT-CA directly; if 1 the path can be
%% PEER, CA, ROOT-CA; if 2 the path can be PEER, CA, CA, ROOT-CA, and so on.
-define(ALLOWED_CERT_CHAIN_LENGTH, 10).

-define(INTERNAL_CERT_USER, "@internal").
-define(INTERNAL_CERT_EMAIL_DOMAIN, "internal.couchbase.com").

-define(CPU_COUNT_VAR, "COUCHBASE_CPU_COUNT").
%% List of available tls versions:
%% You should be able to simply update these macros to include or remove tls
%% versions that we support or no longer support and a number of different
%% validation functions should "just work".
-define(TLS_VERSIONS, #{'tlsv1.3'=> 3, 'tlsv1.2' => 2,
                        'tlsv1.1' => 1, tlsv1 => 0}).

%% Known Elixir profiles
-define(SERVERLESS_PROFILE, serverless).
-define(SERVERLESS_PROFILE_STR, "serverless").

%% Default profile macros/constants
-define(DEFAULT_PROFILE_STR, "default").
-define(DEFAULT_PROFILE_BIN, <<?DEFAULT_PROFILE_STR>>).
-define(DEFAULT_PROFILE_DATA, [{name, ?DEFAULT_PROFILE_STR}]).

-define(SYSTEM_SCOPE_NAME, "_system").

-define(DEFAULT_PWHASH, ?ARGON2ID_HASH).
-define(ARGON2ID_HASH, <<"argon2id">>).
-define(PBKDF2_HASH, <<"pbkdf2-hmac-sha512">>).
-define(SHA1_HASH, <<"SHA-1">>).

-define(DEFAULT_ARG2ID_TIME, 3).
-define(DEFAULT_ARG2ID_MEM, 8388608). %% in bytes
-define(DEFAULT_PBKDF2_ITER, 10000).
-define(DEFAULT_SCRAM_ITER, 15000).

-define(HASHES_KEY,           <<"hashes">>).
-define(SALT_KEY,             <<"salt">>).
-define(HASH_ALG_KEY,         <<"algorithm">>).
-define(ARGON_TIME_KEY,       <<"time">>).
-define(ARGON_MEM_KEY,        <<"memory">>).
-define(ARGON_THREADS_KEY,    <<"parallelism">>).
-define(PBKDF2_ITER_KEY,      <<"iterations">>).
-define(SCRAM_STORED_KEY_KEY, <<"stored_key">>).
-define(SCRAM_SERVER_KEY_KEY, <<"server_key">>).
-define(SCRAM_SALT_KEY,       <<"salt">>).
-define(SCRAM_ITERATIONS_KEY, <<"iterations">>).

-define(ARGON_MEM_MIN, 8_192).
-define(ARGON_MEM_MAX, 4_398_046_510_080).
-define(ARGON_TIME_MIN, 1).
-define(ARGON_TIME_MAX, 4_294_967_295).

-define(PBKDF2_ITER_MIN, 1).
-define(PBKDF2_ITER_MAX, 10_000_000).

%% Pre-elixir keys (do not change these values):
-define(OLD_HASH_KEY,             <<"h">>).
-define(OLD_SCRAM_SALT_KEY,       <<"s">>).
-define(OLD_SCRAM_HASH_KEY,       <<"h">>).
-define(OLD_SCRAM_ITERATIONS_KEY, <<"i">>).

-define(COOKIE_LEN, 32).
-define(COOKIE_HEX_LEN, (?COOKIE_LEN * 2)).
%% Hide/Unhide macros to make it easier to hide secrets from stack-traces and
%% error reports. It is generally good practice to rename the variable(s) in
%% between hide/unhide points so that it's obvious that the value has been
%% wrapped and cannot be used directly.
-define(HIDE(__V), fun () -> __V end).
-define(UNHIDE(__V), __V()).

-define(COUCHDB_ENABLED(__TRUE, __FALSE),
        case config_profile:get_bool({couchdb, disabled}) of
            true ->
                __FALSE;
            false ->
                __TRUE
        end).

-define(INT_CREDS_ROTATION_INT_KEY, int_creds_rotation_interval).
-define(INT_CREDS_ROTATION_INT_DEFAULT, 1800000).
-define(INT_CREDS_PROTECTION_SLEEP_KEY, int_creds_protection_sleep).
-define(INT_CREDS_PROTECTION_SLEEP_DEFAULT, 30000).

-endif.
