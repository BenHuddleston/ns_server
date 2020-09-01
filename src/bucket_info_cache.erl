%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-2018 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc This service maintains public ETS table that's caching
%% json-inified bucket infos. See vbucket_map_mirror module for
%% explanation how this works.
-module(bucket_info_cache).
-include("ns_common.hrl").
-include("cut.hrl").

-export([start_link/0,
         terse_bucket_info/1,
         terse_bucket_info_with_local_addr/2]).

-export([build_node_services/0,
         build_pools_uri/1,
         build_pools_uri/2,
         build_short_bucket_info/2,
         build_name_and_locator/2,
         build_vbucket_map/2,
         build_ddocs/2]).

%% for diagnostics
-export([submit_full_reset/0]).

%% NOTE: we're doing global replace of this string. So it must not
%% need any JSON escaping and it must not otherwise occur in terse
%% bucket info
-define(LOCALHOST_MARKER_STRING, "$HOST").

start_link() ->
    work_queue:start_link(bucket_info_cache, fun cache_init/0).

cache_init() ->
    {ok, _} = gen_event:start_link({local, bucket_info_cache_invalidations}),
    ets:new(bucket_info_cache, [set, named_table]),
    ets:new(bucket_info_cache_buckets, [ordered_set, named_table]),
    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events, fun cleaner_loop/2, Self),
    {value, [{configs, NewBuckets}]} = ns_config:search(buckets),
    submit_new_buckets(Self, NewBuckets),
    submit_full_reset().

cleaner_loop({buckets, [{configs, NewBuckets}]}, Parent) ->
    submit_new_buckets(Parent, NewBuckets),
    Parent;
cleaner_loop({{_, _, alternate_addresses}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, capi_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, ssl_capi_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, ssl_rest_port}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{_, _, rest}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({rest, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, memcached}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, membership}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({cluster_compat_version, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({developer_preview_enabled, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{node, _, services}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop({{service_map, _}, _Value}, State) ->
    submit_full_reset(),
    State;
cleaner_loop(_, Cleaner) ->
    Cleaner.

submit_new_buckets(Pid, Buckets0) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              Buckets = lists:sort(Buckets0),
              BucketNames = compute_buckets_to_invalidate(Buckets),
              [begin
                   ets:delete(bucket_info_cache, Name),
                   ets:delete(bucket_info_cache_buckets, Name)
               end || Name <- BucketNames],
              [gen_event:notify(bucket_info_cache_invalidations, Name) ||
                  Name <- BucketNames],
              ok
      end).

compute_buckets_to_invalidate(Buckets) ->
    CachedBuckets = ets:tab2list(bucket_info_cache_buckets),
    Inv = ordsets:subtract(CachedBuckets, Buckets),
    [BucketName || {BucketName, _} <- Inv].

submit_full_reset() ->
    work_queue:submit_work(
      bucket_info_cache,
      fun () ->
              ets:delete_all_objects(bucket_info_cache),
              ets:delete_all_objects(bucket_info_cache_buckets),
              gen_event:notify(bucket_info_cache_invalidations, '*')
      end).

maybe_build_ext_hostname(Node) ->
    H = misc:extract_node_address(Node),
    case misc:is_localhost(H) of
        true  -> [];
        false -> [{hostname, list_to_binary(H)}]
    end.

alternate_addresses_json(Node, Config, WantedPorts) ->
    menelaus_util:strip_json_struct(
      menelaus_web_node:alternate_addresses_json(Node, Config, WantedPorts)).

build_nodes_ext([] = _Nodes, _Config, NodesExtAcc) ->
    lists:reverse(NodesExtAcc);
build_nodes_ext([Node | RestNodes], Config, NodesExtAcc) ->
    Services =
        [rest | ns_cluster_membership:node_active_services(Config, Node)],
    NI1 = maybe_build_ext_hostname(Node),
    NI2 = case Node =:= node() of
              true ->
                  [{'thisNode', true} | NI1];
              _ ->
                  NI1
          end,
    WantedPorts = service_ports:services_port_keys(Services),

    NI3 = NI2 ++ alternate_addresses_json(Node, Config, WantedPorts),
    NodeInfo = {[{services, {service_ports:get_ports_for_services(
                               Node, Config, Services)}} | NI3]},
    build_nodes_ext(RestNodes, Config, [NodeInfo | NodesExtAcc]).

do_compute_bucket_info(Bucket, Config) ->
    case ns_bucket:get_bucket(Bucket, Config) of
        {ok, BucketConfig} ->
            compute_bucket_info_with_config(Bucket, Config, BucketConfig);
        not_present ->
            not_present
    end.

node_bucket_info(Node, Config, Bucket, BucketUUID, BucketConfig) ->
    HostName = menelaus_web_node:build_node_hostname(Config, Node,
                                                     ?LOCALHOST_MARKER_STRING),
    Ports = {[{direct, service_ports:get_port(memcached_port, Config, Node)}]},
    WantedPorts = [rest_port, memcached_port],

    Info0 = [{hostname, list_to_binary(HostName)},
             {ports, Ports}] ++
        alternate_addresses_json(Node, Config, WantedPorts),
    Info = case ns_bucket:bucket_type(BucketConfig) of
               membase ->
                   Url = capi_utils:capi_bucket_url_bin(
                           Node, Bucket, BucketUUID, ?LOCALHOST_MARKER_STRING),
                   [{couchApiBase, Url} | Info0];
               _ ->
                   Info0
           end,
    {Info}.

build_short_bucket_info(Id, BucketConfig) ->
    BucketUUID = ns_bucket:bucket_uuid(BucketConfig),
    [build_name_and_locator(Id, BucketConfig),
     {uuid, BucketUUID},
     {uri, build_pools_uri(["buckets", Id], BucketUUID)},
     {streamingUri, build_pools_uri(["bucketsStreaming", Id], BucketUUID)},
     build_bucket_capabilities(BucketConfig),
     build_collections_manifest_id(BucketConfig)].

build_name_and_locator(Id, BucketConfig) ->
    [{name, list_to_binary(Id)},
     {nodeLocator, ns_bucket:node_locator(BucketConfig)}].

build_vbucket_map(LocalAddr, BucketConfig) ->
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            [];
        membase ->
            do_build_vbucket_map(LocalAddr, BucketConfig, ns_config:latest())
    end.

equal_len_chains([]) ->
    [];
equal_len_chains(Map) ->
    MaxChainLen = length(misc:min_by(?cut(length(_1) > length(_2)), Map)),
    [misc:align_list(Chain, MaxChainLen, undefined) || Chain <- Map].

do_build_vbucket_map(LocalAddr, BucketConfig, Config) ->
    NumReplicas = ns_bucket:num_replicas(BucketConfig),
    EMap = equal_len_chains(proplists:get_value(map, BucketConfig, [])),
    BucketNodes = ns_bucket:get_servers(BucketConfig),
    ENodes = lists:delete(undefined, lists:usort(lists:append([BucketNodes |
                                                                EMap]))),
    Servers = lists:map(
                fun (ENode) ->
                        Port = service_ports:get_port(memcached_port, Config,
                                                      ENode),
                        H = misc:extract_node_address(ENode),
                        Host = case misc:is_localhost(H) of
                                   true  -> LocalAddr;
                                   false -> H
                               end,
                        list_to_binary(misc:join_host_port(Host, Port))
                end, ENodes),
    {_, NodesToPositions0}
        = lists:foldl(fun (N, {Pos,Dict}) ->
                              {Pos+1, dict:store(N, Pos, Dict)}
                      end, {0, dict:new()}, ENodes),
    NodesToPositions = dict:store(undefined, -1, NodesToPositions0),
    Map = [[dict:fetch(N, NodesToPositions) || N <- Chain] || Chain <- EMap],
    FastForwardMapList =
        case proplists:get_value(fastForwardMap, BucketConfig) of
            undefined -> [];
            FFM ->
                [{vBucketMapForward,
                  [[dict:fetch(N, NodesToPositions) || N <- Chain]
                   || Chain <- FFM]}]
        end,
    {vBucketServerMap,
     {[{hashAlgorithm, <<"CRC">>},
       {numReplicas, NumReplicas},
       {serverList, Servers},
       {vBucketMap, Map} |
       FastForwardMapList]}}.

build_ddocs(Id, BucketConfig) ->
    [{ddocs, {[{uri, build_pools_uri(["buckets", Id, "ddocs"])}]}} ||
        ns_bucket:can_have_views(BucketConfig)].

build_collections_manifest_id(BucketConfig) ->
    case collections:uid(BucketConfig) of
        undefined ->
            [];
        Uid ->
            {collectionsManifestUid, Uid}
    end.

build_pools_uri(Tail) ->
    build_pools_uri(Tail, undefined).

build_pools_uri(Tail, UUID) ->
    menelaus_util:bin_concat_path(
      ["pools", "default"] ++ Tail,
      [{"bucket_uuid", UUID} || UUID =/= undefined]).

build_bucket_capabilities(BucketConfig) ->
    Caps =
        case ns_bucket:bucket_type(BucketConfig) of
            membase ->
                Conditional =
                    [{collections, collections:enabled(BucketConfig)},
                     {durableWrite, cluster_compat_mode:is_cluster_65()},
                     {tombstonedUserXAttrs,
                      cluster_compat_mode:is_cluster_66()},
                     {couchapi, ns_bucket:can_have_views(BucketConfig)}],

                [C || {C, true} <- Conditional] ++
                    [dcp, cbhello, touch, cccp, xdcrCheckpointing, nodesExt,
                     xattr];
            memcached ->
                [cbhello, nodesExt]
        end,

    [{bucketCapabilitiesVer, ''},
     {bucketCapabilities, Caps}].

compute_bucket_info_with_config(Id, Config, BucketConfig) ->
    %% we do sorting to make nodes list match order of servers inside
    %% vBucketServerMap
    Servers = lists:sort(ns_bucket:get_servers(BucketConfig)),
    BucketUUID = ns_bucket:bucket_uuid(BucketConfig),

    AllServers = Servers ++
        ordsets:subtract(ns_cluster_membership:active_nodes(Config), Servers),

    %% We're computing rev using config's global rev which allows us
    %% to track changes to node services and set of active nodes.
    Rev = ns_config:compute_global_rev(Config),

    Json =
        {lists:flatten(
           [{rev, Rev},
            build_short_bucket_info(Id, BucketConfig),
            build_ddocs(Id, BucketConfig),
            build_vbucket_map(?LOCALHOST_MARKER_STRING, BucketConfig),
            {nodes,
             [node_bucket_info(Node, Config, Id, BucketUUID, BucketConfig)
                 || Node <- Servers]},
            {nodesExt, build_nodes_ext(AllServers, Config, [])},
            build_cluster_capabilities(Config)])},
    {ok, Rev, ejson:encode(Json), BucketConfig}.

compute_bucket_info(Bucket) ->
    Config = ns_config:get(),
    try do_compute_bucket_info(Bucket, Config)
    catch T:E:S ->
            {T, E, S}
    end.


call_compute_bucket_info(BucketName) ->
    work_queue:submit_sync_work(
      bucket_info_cache,
      fun () ->
              case ets:lookup(bucket_info_cache, BucketName) of
                  [] ->
                      case compute_bucket_info(BucketName) of
                          {ok, Rev, V, BucketConfig} ->
                              ets:insert(bucket_info_cache,
                                         {BucketName, Rev, V}),
                              ets:insert(bucket_info_cache_buckets,
                                         {BucketName, BucketConfig}),
                              {ok, Rev, V};
                          Other ->
                              %% note: we might consider caching
                              %% exceptions but they're supposedly
                              %% rare anyways
                              Other
                      end;
                  [{_, Rev, V}] ->
                      {ok, Rev, V}
              end
      end).

terse_bucket_info(BucketName) ->
    case ets:lookup(bucket_info_cache, BucketName) of
        [] ->
            call_compute_bucket_info(BucketName);
        [{_, Rev, V}] ->
            {ok, Rev, V}
    end.

build_node_services() ->
    case ets:lookup(bucket_info_cache, 'node_services') of
        [] ->
            case call_build_node_services() of
                {ok, Rev, V} -> {Rev, V};
                {T, E, Stack} ->
                    erlang:raise(T, E, Stack)
            end;
        [{_, Rev, V}] ->
            {Rev, V}
    end.

call_build_node_services() ->
    work_queue:submit_sync_work(
      bucket_info_cache,
      fun () ->
              case ets:lookup(bucket_info_cache, 'node_services') of
                  [] ->
                      try do_build_node_services() of
                          {Rev, V} ->
                              ets:insert(bucket_info_cache,
                                         {'node_services', Rev, V}),
                              {ok, Rev, V}
                      catch T:E:S ->
                              {T, E, S}
                      end;
                  [{_, Rev, V}] ->
                      {ok, Rev, V}
              end
      end).

build_cluster_capabilities(Config) ->
    case cluster_compat_mode:get_cluster_capabilities(Config) of
        [] ->
            [];
        Caps ->
            [{clusterCapabilitiesVer, [1, 0]},
             {clusterCapabilities, {Caps}}]
    end.

do_build_node_services() ->
    Config = ns_config:get(),
    NEIs = build_nodes_ext(ns_cluster_membership:active_nodes(Config),
                           Config, []),
    Caps = build_cluster_capabilities(Config),
    Rev = ns_config:compute_global_rev(Config),
    J = {[{rev, Rev},
          {nodesExt, NEIs}] ++ Caps},
    {Rev, ejson:encode(J)}.

terse_bucket_info_with_local_addr(BucketName, LocalAddr) ->
    case terse_bucket_info(BucketName) of
        {ok, _, Bin} ->
            {ok, binary:replace(Bin, list_to_binary(?LOCALHOST_MARKER_STRING),
                                list_to_binary(LocalAddr), [global])};
        Other ->
            Other
    end.
