%% @author Couchbase <info@couchbase.com>
%% @copyright 2010-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(ns_orchestrator).

-behaviour(gen_statem).

-include("ns_common.hrl").
-include("cut.hrl").
-include("bucket_hibernation.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Constants and definitions

-record(idle_state, {}).
-record(janitor_state, {cleanup_id :: undefined | pid()}).

-record(rebalancing_state, {rebalancer,
                            rebalance_observer,
                            keep_nodes,
                            eject_nodes,
                            failed_nodes,
                            delta_recov_bkts,
                            retry_check,
                            to_failover,
                            stop_timer,
                            type,
                            rebalance_id,
                            abort_reason,
                            reply_to}).

-record(bucket_hibernation_state,
        {hibernation_manager :: pid(),
         bucket :: bucket_name(),
         op  :: pause_bucket | resume_bucket,
         stop_tref = undefined :: undefined | reference(),
         stop_reason = undefined :: term()}).

-record(recovery_state, {pid :: pid()}).


%% API
-export([create_bucket/3,
         update_bucket/4,
         delete_bucket/1,
         flush_bucket/1,
         start_pause_bucket/1,
         stop_pause_bucket/1,
         start_resume_bucket/2,
         stop_resume_bucket/1,
         failover/2,
         start_failover/2,
         try_autofailover/2,
         needs_rebalance/0,
         start_link/0,
         start_rebalance/5,
         retry_rebalance/4,
         stop_rebalance/0,
         start_recovery/1,
         stop_recovery/2,
         commit_vbucket/3,
         recovery_status/0,
         recovery_map/2,
         is_recovery_running/0,
         ensure_janitor_run/1,
         rebalance_type2text/1,
         start_graceful_failover/1]).

-define(SERVER, {via, leader_registry, ?MODULE}).

-define(DELETE_BUCKET_TIMEOUT,  ?get_timeout(delete_bucket, 30000)).
-define(DELETE_MAGMA_BUCKET_TIMEOUT,  ?get_timeout(delete_bucket, 300000)).
-define(FLUSH_BUCKET_TIMEOUT,   ?get_timeout(flush_bucket, 60000)).
-define(CREATE_BUCKET_TIMEOUT,  ?get_timeout(create_bucket, 5000)).
-define(JANITOR_RUN_TIMEOUT,    ?get_timeout(ensure_janitor_run, 30000)).
-define(JANITOR_INTERVAL,       ?get_param(janitor_interval, 5000)).
-define(STOP_REBALANCE_TIMEOUT, ?get_timeout(stop_rebalance, 10000)).
-define(STOP_PAUSE_BUCKET_TIMEOUT,
        ?get_timeout(stop_pause_bucket, 10 * 1000)). %% 10 secs.
-define(STOP_RESUME_BUCKET_TIMEOUT,
        ?get_timeout(stop_pause_bucket, 10 * 1000)). %% 10 secs.

%% gen_statem callbacks
-export([code_change/4,
         init/1,
         callback_mode/0,
         handle_event/4,
         terminate/3]).

%% States
-export([idle/2, idle/3,
         janitor_running/2, janitor_running/3,
         rebalancing/2, rebalancing/3,
         recovery/2, recovery/3,
         bucket_hibernation/3]).

%%
%% API
%%

start_link() ->
    misc:start_singleton(gen_statem, ?MODULE, [], []).

wait_for_orchestrator() ->
    misc:wait_for_global_name(?MODULE).

call(Msg) ->
    wait_for_orchestrator(),
    gen_statem:call(?SERVER, Msg).

call(Msg, Timeout) ->
    wait_for_orchestrator(),
    gen_statem:call(?SERVER, Msg, Timeout).

-spec create_bucket(memcached|membase, nonempty_string(), list()) ->
                           ok | {error, {already_exists, nonempty_string()}} |
                           {error, {still_exists, nonempty_string()}} |
                           {error, {port_conflict, integer()}} |
                           {error, {need_more_space, list()}} |
                           {error, {incorrect_parameters, nonempty_string()}} |
                           rebalance_running | in_recovery |
                           in_bucket_hibernation.
create_bucket(BucketType, BucketName, NewConfig) ->
    call({create_bucket, BucketType, BucketName, NewConfig}, infinity).

-spec update_bucket(memcached|membase, undefined|couchstore|magma|ephemeral,
                    nonempty_string(), list()) ->
                           ok | {exit, {not_found, nonempty_string()}, []} |
                           {error, {need_more_space, list()}} |
                           rebalance_running | in_recovery |
                           in_bucket_hibernation.
update_bucket(BucketType, StorageMode, BucketName, UpdatedProps) ->
    call({update_bucket, BucketType, StorageMode, BucketName, UpdatedProps},
         infinity).

%% Deletes bucket. Makes sure that once it returns it's already dead.
%% In implementation we make sure config deletion is propagated to
%% child nodes. And that ns_memcached for bucket being deleted
%% dies. But we don't wait more than ?DELETE_BUCKET_TIMEOUT.
%%
%% Return values are ok if it went fine at least on local node
%% (failure to stop ns_memcached on any nodes is merely logged);
%% rebalance_running if delete bucket request came while rebalancing;
%% and {exit, ...} if bucket does not really exists
-spec delete_bucket(bucket_name()) ->
                           ok | rebalance_running | in_recovery |
                           in_bucket_hibernation |
                           {shutdown_failed, [node()]} |
                           {exit, {not_found, bucket_name()}, _}.
delete_bucket(BucketName) ->
    call({delete_bucket, BucketName}, infinity).

-spec flush_bucket(bucket_name()) ->
                          ok |
                          rebalance_running |
                          in_recovery |
                          in_bucket_hibernation |
                          bucket_not_found |
                          flush_disabled |
                          {prepare_flush_failed, _, _} |
                          {initial_config_sync_failed, _} |
                          {flush_config_sync_failed, _} |
                          {flush_wait_failed, _, _} |
                          {old_style_flush_failed, _, _}.
flush_bucket(BucketName) ->
    call({flush_bucket, BucketName}, infinity).

-spec start_pause_bucket(Args :: #bucket_hibernation_op_args{}) ->
    ok |
    bucket_not_found |
    not_supported |
    rebalance_running |
    in_recovery |
    in_bucket_hibernation |
    bucket_type_not_supported |
    no_width_parameter |
    requires_rebalance |
    full_servers_unavailable |
    failed_service_nodes |
    map_servers_mismatch.
start_pause_bucket(Args) ->
    call({{bucket_hibernation_op, {start, pause_bucket}},
          {Args, []}}).

-spec stop_pause_bucket(bucket_name()) ->
    ok |
    in_recovery |
    rebalance_running |
    {error, bucket_not_found} |
    {error, not_running_pause_bucket} |
    {errors, {bucket_not_found, not_running_pause_bucket}}.
stop_pause_bucket(Bucket) ->
    call({{bucket_hibernation_op, {stop, pause_bucket}}, [Bucket]}).

-spec start_resume_bucket(#bucket_hibernation_op_args{}, list()) ->
    ok |
    {need_more_space, term()} |
    bucket_exists |
    rebalance_running |
    in_recovery |
    in_bucket_hibernation.
start_resume_bucket(Args, Metadata) ->
    call({{bucket_hibernation_op, {start, resume_bucket}},
          {Args, [Metadata]}}).

-spec stop_resume_bucket(bucket_name()) ->
    ok |
    rebalance_running |
    in_recovery |
    {error, bucket_not_found} |
    {error, not_running_resume_bucket} |
    {errors, {bucket_not_found, not_running_resume_bucket}}.
stop_resume_bucket(Bucket) ->
    call({{bucket_hibernation_op, {stop, resume_bucket}}, [Bucket]}).

-spec failover([node()], boolean()) ->
                      ok |
                      rebalance_running |
                      in_recovery |
                      last_node |
                      {last_node_for_bucket, list()} |
                      unknown_node |
                      orchestration_unsafe |
                      config_sync_failed |
                      quorum_lost |
                      stopped_by_user |
                      {incompatible_with_previous, [atom()]} |
                      %% the following is needed just to trick the dialyzer;
                      %% otherwise it wouldn't let the callers cover what it
                      %% believes to be an impossible return value if all
                      %% other options are also covered
                      any().
failover(Nodes, AllowUnsafe) ->
    call({failover, Nodes, AllowUnsafe}, infinity).

-spec start_failover([node()], boolean()) ->
                            ok |
                            rebalance_running |
                            in_recovery |
                            last_node |
                            {last_node_for_bucket, list()} |
                            unknown_node |
                            {incompatible_with_previous, [atom()]} |
                            %% the following is needed just to trick the dialyzer;
                            %% otherwise it wouldn't let the callers cover what it
                            %% believes to be an impossible return value if all
                            %% other options are also covered
                            any().
start_failover(Nodes, AllowUnsafe) ->
    call({start_failover, Nodes, AllowUnsafe}).

-spec try_autofailover(list(), map()) ->
                              {ok, list()} |
                              {operation_running, list()}|
                              retry_aborting_rebalance |
                              in_recovery |
                              orchestration_unsafe |
                              config_sync_failed |
                              quorum_lost |
                              stopped_by_user |
                              {autofailover_unsafe, [bucket_name()]} |
                              {nodes_down, [node()], [bucket_name()]} |
                              {cannot_preserve_durability_majority,
                               [bucket_name()]}.
try_autofailover(Nodes, Options) ->
    case call({try_autofailover, Nodes, Options}, infinity) of
        ok ->
            {ok, []};
        Other ->
            Other
    end.

-spec needs_rebalance() -> boolean().
needs_rebalance() ->
    NodesWanted = ns_node_disco:nodes_wanted(),
    ServicesNeedRebalance =
        lists:any(fun (S) ->
                          service_needs_rebalance(S, NodesWanted)
                  end, ns_cluster_membership:cluster_supported_services()),
    ServicesNeedRebalance orelse buckets_need_rebalance(NodesWanted).

service_needs_rebalance(Service, NodesWanted) ->
    ServiceNodes = ns_cluster_membership:service_nodes(NodesWanted, Service),
    ActiveServiceNodes = ns_cluster_membership:service_active_nodes(Service),
    lists:sort(ServiceNodes) =/= lists:sort(ActiveServiceNodes) orelse
        topology_aware_service_needs_rebalance(Service, ActiveServiceNodes).

topology_aware_service_needs_rebalance(Service, ServiceNodes) ->
    case lists:member(Service,
                      ns_cluster_membership:topology_aware_services()) of
        true ->
            %% TODO: consider caching this
            Statuses = ns_doctor:get_nodes(),
            lists:any(
              fun (Node) ->
                      NodeStatus = misc:dict_get(Node, Statuses, []),
                      ServiceStatus =
                          proplists:get_value({service_status, Service},
                                              NodeStatus, []),
                      proplists:get_value(needs_rebalance, ServiceStatus, false)
              end, ServiceNodes);
        false ->
            false
    end.

-spec buckets_need_rebalance([node(), ...]) -> boolean().
buckets_need_rebalance(NodesWanted) ->
    KvNodes = ns_cluster_membership:service_nodes(NodesWanted, kv),
    lists:any(fun ({Bucket, BucketConfig}) ->
                      ns_rebalancer:bucket_needs_rebalance(
                        Bucket, BucketConfig, KvNodes)
              end,
              ns_bucket:get_buckets()).

-spec request_janitor_run(janitor_item()) -> ok.
request_janitor_run(Item) ->
    gen_statem:cast(?SERVER, {request_janitor_run, Item}).

-spec ensure_janitor_run(janitor_item()) ->
                                ok |
                                in_recovery |
                                in_bucket_hibernation |
                                rebalance_running |
                                janitor_failed |
                                bucket_deleted.
ensure_janitor_run(Item) ->
    wait_for_orchestrator(),
    misc:poll_for_condition(
      fun () ->
              case gen_statem:call(?SERVER, {ensure_janitor_run, Item},
                                   infinity) of
                  warming_up ->
                      false;
                  interrupted ->
                      false;
                  Ret ->
                      Ret
              end
      end, ?JANITOR_RUN_TIMEOUT, 1000).

-spec start_rebalance([node()], [node()], all | [bucket_name()],
                      [list()], all | [atom()]) ->
                             {ok, binary()} | ok | in_progress |
                             already_balanced | nodes_mismatch |
                             no_active_nodes_left | in_recovery |
                             in_bucket_hibernation |
                             delta_recovery_not_possible | no_kv_nodes_left |
                             {need_more_space, list()} |
                             {must_rebalance_services, list()} |
                             {unhosted_services, list()}.
start_rebalance(KnownNodes, EjectNodes, DeltaRecoveryBuckets,
                DefragmentZones, Services) ->
    call({maybe_start_rebalance,
          #{known_nodes => KnownNodes,
            eject_nodes => EjectNodes,
            delta_recovery_buckets => DeltaRecoveryBuckets,
            defragment_zones => DefragmentZones,
            services => Services}}).

retry_rebalance(rebalance, Params, Id, Chk) ->
    call({maybe_start_rebalance,
          maps:merge(maps:from_list(Params),
                     #{id => Id, chk => Chk, services => all})});

retry_rebalance(graceful_failover, Params, Id, Chk) ->
    call({maybe_retry_graceful_failover,
          proplists:get_value(nodes, Params), Id, Chk}).

-spec start_graceful_failover([node()]) ->
                                     ok | in_progress | in_recovery |
                                     non_kv_node | not_graceful | unknown_node |
                                     last_node |
                                     {last_node_for_bucket, list()} |
                                     {config_sync_failed, any()} |
                                     %% the following is needed just to trick
                                     %% the dialyzer; otherwise it wouldn't
                                     %% let the callers cover what it believes
                                     %% to be an impossible return value if
                                     %% all other options are also covered
                                     any().
start_graceful_failover(Nodes) ->
    call({start_graceful_failover, Nodes}).

-spec stop_rebalance() -> ok | not_rebalancing.
stop_rebalance() ->
    call(stop_rebalance).

-spec start_recovery(bucket_name()) ->
                            {ok, UUID, RecoveryMap} |
                            unsupported |
                            rebalance_running |
                            in_bucket_hibernation |
                            not_present |
                            not_needed |
                            {error, {failed_nodes, [node()]}} |
                            {error, {janitor_error, any()}}
                                when UUID :: binary(),
                                     RecoveryMap :: dict:dict().
start_recovery(Bucket) ->
    call({start_recovery, Bucket}).

-spec recovery_status() -> not_in_recovery | {ok, Status}
                               when Status :: [{bucket, bucket_name()} |
                                               {uuid, binary()} |
                                               {recovery_map, RecoveryMap}],
                                    RecoveryMap :: dict:dict().
recovery_status() ->
    case is_recovery_running() of
        false ->
            not_in_recovery;
        _ ->
            call(recovery_status)
    end.

-spec recovery_map(bucket_name(), UUID) -> bad_recovery | {ok, RecoveryMap}
                                               when RecoveryMap :: dict:dict(),
                                                    UUID :: binary().
recovery_map(Bucket, UUID) ->
    call({recovery_map, Bucket, UUID}).

-spec commit_vbucket(bucket_name(), UUID, vbucket_id()) ->
                            ok | recovery_completed |
                            vbucket_not_found | bad_recovery |
                            {error, {failed_nodes, [node()]}}
                                when UUID :: binary().
commit_vbucket(Bucket, UUID, VBucket) ->
    call({commit_vbucket, Bucket, UUID, VBucket}).

-spec stop_recovery(bucket_name(), UUID) -> ok | bad_recovery |
                                            in_bucket_hibernation
                                              when UUID :: binary().
stop_recovery(Bucket, UUID) ->
    call({stop_recovery, Bucket, UUID}).

-spec is_recovery_running() -> boolean().
is_recovery_running() ->
    recovery_server:is_recovery_running().

%%
%% gen_statem callbacks
%%

callback_mode() ->
    handle_event_function.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

init([]) ->
    process_flag(trap_exit, true),

    {ok, idle, #idle_state{}, {{timeout, janitor}, 0, run_janitor}}.

%% called remotely from pre-Elixir nodes
handle_event({call, From},
             {maybe_start_rebalance, KnownNodes, EjectedNodes,
              DeltaRecoveryBuckets}, _StateName, _State) ->
    {keep_state_and_data,
     [{next_event, {call, From},
       {maybe_start_rebalance,
        #{known_nodes => KnownNodes,
          eject_nodes => EjectedNodes,
          delta_recovery_buckets => DeltaRecoveryBuckets,
          services => all}}}]};

handle_event({call, From}, {maybe_start_rebalance,
                            Params = #{known_nodes := KnownNodes,
                                       eject_nodes := EjectedNodes,
                                       services := Services}},
             _StateName, _State) ->
    NewParams =
        case maps:is_key(id, Params) of
            false ->
                auto_rebalance:cancel_any_pending_retry_async(
                  "manual rebalance"),
                Params#{id => couch_uuids:random()};
            true ->
                Params
        end,

    Snapshot = chronicle_compat:get_snapshot(
                 [ns_bucket:fetch_snapshot(all, _, [uuid, props]),
                  ns_cluster_membership:fetch_snapshot(_),
                  chronicle_master:fetch_snapshot(_)],
                 #{read_consistency => quorum}),

    try
        case {EjectedNodes -- KnownNodes,
              lists:sort(ns_cluster_membership:nodes_wanted(Snapshot)),
              lists:sort(KnownNodes)} of
            {[], X, X} ->
                ok;
            _ ->
                throw(nodes_mismatch)
        end,
        MaybeKeepNodes = KnownNodes -- EjectedNodes,
        FailedNodes = get_failed_nodes(Snapshot, KnownNodes),
        KeepNodes = MaybeKeepNodes -- FailedNodes,
        DeltaNodes = get_delta_recovery_nodes(Snapshot, KeepNodes),

        KeepNodes =/= [] orelse throw(no_active_nodes_left),
        case rebalance_allowed(Snapshot) of
            ok -> ok;
            {error, Msg} ->
                set_rebalance_status(rebalance, {none, Msg}, undefined),
                throw(ok)
        end,
        NewChk = case retry_ok(Snapshot, FailedNodes, NewParams) of
                     false ->
                         throw(retry_check_failed);
                     Other ->
                         Other
                 end,
        EjectedLiveNodes = EjectedNodes -- FailedNodes,

        validate_services(Services, EjectedLiveNodes, DeltaNodes, Snapshot),

        NewParams1 = NewParams#{keep_nodes => KeepNodes,
                                eject_nodes => EjectedLiveNodes,
                                failed_nodes => FailedNodes,
                                delta_nodes => DeltaNodes,
                                chk => NewChk},
        {keep_state_and_data,
         [{next_event, {call, From}, {start_rebalance, NewParams1}}]}
    catch
        throw:Error -> {keep_state_and_data, [{reply, From, Error}]}
    end;

handle_event({call, From}, {maybe_retry_graceful_failover, Nodes, Id, Chk},
             _StateName, _State) ->
    case graceful_failover_retry_ok(Chk) of
        false ->
            {keep_state_and_data, [{reply, From, retry_check_failed}]};
        Chk ->
            StartEvent = {start_graceful_failover, Nodes, Id, Chk},
            {keep_state_and_data, [{next_event, {call, From}, StartEvent}]}
    end;

handle_event({call, From}, recovery_status, StateName, State) ->
    case StateName of
        recovery ->
            ?MODULE:recovery(recovery_status, From, State);
        _ ->
            {keep_state_and_data, [{reply, From, not_in_recovery}]}
    end;

handle_event({call, From}, Msg, StateName, State)
  when element(1, Msg) =:= recovery_map;
       element(1, Msg) =:= commit_vbucket;
       element(1, Msg) =:= stop_recovery ->
    case StateName of
        recovery ->
            ?MODULE:recovery(Msg, From, State);
        _ ->
            {keep_state_and_data, [{reply, From, bad_recovery}]}
    end;

handle_event(info, Event, StateName, StateData)->
    handle_info(Event, StateName, StateData);
handle_event(cast, Event, StateName, StateData) ->
    ?MODULE:StateName(Event, StateData);
handle_event({call, From}, Event, StateName, StateData) ->
    ?MODULE:StateName(Event, From, StateData);

handle_event({timeout, janitor}, run_janitor, idle, _State) ->
    {ok, ID} = ns_janitor_server:start_cleanup(
                 fun(Pid, UnsafeNodes, CleanupID) ->
                         Pid ! {cleanup_done, UnsafeNodes, CleanupID},
                         ok
                 end),
    {next_state, janitor_running, #janitor_state{cleanup_id = ID},
     {{timeout, janitor}, ?JANITOR_INTERVAL, run_janitor}};

handle_event({timeout, janitor}, run_janitor, StateName, _StateData) ->
    ?log_info("Skipping janitor in state ~p", [StateName]),
    {keep_state_and_data,
     {{timeout, janitor}, ?JANITOR_INTERVAL, run_janitor}}.

handle_info({'EXIT', Pid, Reason}, rebalancing,
            #rebalancing_state{rebalancer = Pid} = State) ->
    handle_rebalance_completion(Reason, State);

handle_info({'EXIT', ObserverPid, Reason}, rebalancing,
            #rebalancing_state{rebalance_observer = ObserverPid} = State) ->
    {keep_state, stop_rebalance(State, {rebalance_observer_terminated, Reason})};

handle_info({'EXIT', Pid, Reason}, recovery, #recovery_state{pid = Pid}) ->
    ale:error(?USER_LOGGER,
              "Recovery process ~p terminated unexpectedly: ~p", [Pid, Reason]),
    {next_state, idle, #idle_state{}};

handle_info({cleanup_done, UnsafeNodes, ID}, janitor_running,
            #janitor_state{cleanup_id = CleanupID}) ->
    %% If we get here we don't expect the IDs to be different.
    ID = CleanupID,

    %% If any 'unsafe nodes' were found then trigger an auto_reprovision
    %% operation via the orchestrator.
    MaybeNewTimeout = case UnsafeNodes =/= [] of
                          true ->
                              %% The unsafe nodes only affect the ephemeral
                              %% buckets.
                              Buckets = ns_bucket:get_bucket_names_of_type(
                                          {membase, ephemeral}),
                              RV = auto_reprovision:reprovision_buckets(
                                     Buckets, UnsafeNodes),
                              ?log_info("auto_reprovision status = ~p "
                                        "(Buckets = ~p, UnsafeNodes = ~p)",
                                        [RV, Buckets, UnsafeNodes]),

                              %% Trigger the janitor cleanup immediately as
                              %% the buckets need to be brought online.
                              [{{timeout, janitor}, 0, run_janitor}];
                          false ->
                              []
                      end,
    {next_state, idle, #idle_state{}, MaybeNewTimeout};

handle_info({timeout, _TRef, stop_timeout} = Msg, rebalancing, StateData) ->
    ?MODULE:rebalancing(Msg, StateData);

handle_info(Msg, bucket_hibernation, StateData) ->
    handle_info_in_bucket_hibernation(Msg, StateData);

handle_info(Msg, StateName, StateData) ->
    ?log_warning("Got unexpected message ~p in state ~p with data ~p",
                 [Msg, StateName, StateData]),
    keep_state_and_data.

terminate(_Reason, _StateName, _StateData) ->
    ok.

%%
%% States
%%

%% Asynchronous idle events
idle({request_janitor_run, Item}, State) ->
    do_request_janitor_run(Item, idle, State);
idle(_Event, _State) ->
    %% This will catch stray progress messages
    keep_state_and_data.

janitor_running({request_janitor_run, Item}, State) ->
    do_request_janitor_run(Item, janitor_running, State);
janitor_running(_Event, _State) ->
    keep_state_and_data.

%% Synchronous idle events
idle({create_bucket, BucketType, BucketName, BucketConfig}, From, _State) ->
    case validate_create_bucket(BucketName, BucketConfig) of
        {ok, NewBucketConfig} ->
            {ok, UUID, ActualBucketConfig} =
                ns_bucket:create_bucket(BucketType, BucketName,
                                        NewBucketConfig),
            ConfigJSON = ns_bucket:build_bucket_props_json(
                           ns_bucket:extract_bucket_props(ActualBucketConfig)),
            master_activity_events:note_bucket_creation(BucketName, BucketType,
                                                        ConfigJSON),
            event_log:add_log(
              bucket_created,
              [{bucket, list_to_binary(BucketName)},
               {bucket_uuid, UUID},
               {bucket_type, ns_bucket:display_type(ActualBucketConfig)},
               {bucket_props, {ConfigJSON}}]),
            request_janitor_run({bucket, BucketName}),
            {keep_state_and_data, [{reply, From, ok}]};
        {error, _} = Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
idle({flush_bucket, BucketName}, From, _State) ->
    RV = perform_bucket_flushing(BucketName),
    case RV of
        ok -> ok;
        _ ->
            ale:info(?USER_LOGGER, "Flushing ~p failed with error: ~n~p",
                     [BucketName, RV])
    end,
    {keep_state_and_data, [{reply, From, RV}]};
idle({delete_bucket, BucketName}, From, _State) ->
    Reply = handle_delete_bucket(BucketName),

    {keep_state_and_data, [{reply, From, Reply}]};

%% In the mixed mode, depending upon the node from which the update bucket
%% request is being sent, the length of the message could vary. In order to
%% be backward compatible we need to field both types of messages.
idle({update_bucket, memcached, BucketName, UpdatedProps}, From, _State) ->
    {keep_state_and_data,
     [{next_event, {call, From},
       {update_bucket, memcached, undefined, BucketName, UpdatedProps}}]};
idle({update_bucket, membase, BucketName, UpdatedProps}, From, _State) ->
    {keep_state_and_data,
     [{next_event, {call, From},
       {update_bucket, membase, couchstore, BucketName, UpdatedProps}}]};
idle({update_bucket,
      BucketType, StorageMode, BucketName, UpdatedProps}, From, _State) ->
    Reply =
        case bucket_placer:place_bucket(BucketName, UpdatedProps) of
            {ok, NewUpdatedProps} ->
                case ns_bucket:update_bucket_props(
                       BucketType, StorageMode, BucketName, NewUpdatedProps) of
                    ok ->
                        %% request janitor run to fix map if the replica # has
                        %% changed
                        request_janitor_run({bucket, BucketName});
                    _ ->
                        ok
                end;
            {error, BadZones} ->
                {error, {need_more_space, BadZones}}
        end,
    {keep_state_and_data, [{reply, From, Reply}]};
idle({failover, Node}, From, _State) ->
    %% calls from pre-5.5 nodes
    {keep_state_and_data,
     [{next_event, {call, From}, {failover, [Node], false}}]};
idle({failover, Nodes, AllowUnsafe}, From, _State) ->
    handle_start_failover(Nodes, AllowUnsafe, From, true, hard_failover, #{});
idle({start_failover, Nodes, AllowUnsafe}, From, _State) ->
    handle_start_failover(Nodes, AllowUnsafe, From, false, hard_failover, #{});
idle({try_autofailover, Nodes, #{down_nodes := DownNodes} = Options}, From,
     _State) ->
    case auto_failover:validate_kv(Nodes, DownNodes) of
        {unsafe, UnsafeBuckets} ->
            {keep_state_and_data,
             [{reply, From, {autofailover_unsafe, UnsafeBuckets}}]};
        {nodes_down, NodesNeeded, Buckets} ->
            {keep_state_and_data,
             [{reply, From, {nodes_down, NodesNeeded, Buckets}}]};
        {cannot_preserve_durability_majority, Buckets} ->
            {keep_state_and_data,
             [{reply, From, {cannot_preserve_durability_majority, Buckets}}]};
        ok ->
            handle_start_failover(Nodes, false, From, true, auto_failover,
                                  Options)
    end;
idle({start_graceful_failover, Nodes}, From, _State) ->
    auto_rebalance:cancel_any_pending_retry_async("graceful failover"),
    {keep_state_and_data,
     [{next_event, {call, From},
       {start_graceful_failover, Nodes, couch_uuids:random(),
        get_graceful_fo_chk()}}]};
idle({start_graceful_failover, Nodes, Id, RetryChk}, From, _State) ->
    ActiveNodes = ns_cluster_membership:active_nodes(),
    NodesInfo = [{active_nodes, ActiveNodes},
                 {failover_nodes, Nodes},
                 {master_node, node()}],
    Services = [kv],
    Type = graceful_failover,
    {ok, ObserverPid} = ns_rebalance_observer:start_link(
                          Services, NodesInfo, Type, Id),

    case ns_rebalancer:start_link_graceful_failover(Nodes) of
        {ok, Pid} ->
            ale:info(?USER_LOGGER,
                     "Starting graceful failover of nodes ~p. "
                     "Operation Id = ~s", [Nodes, Id]),
            Type = graceful_failover,
            event_log:add_log(graceful_failover_initiated,
                              [{nodes_info, {NodesInfo}},
                               {operation_id, Id}]),
            ns_cluster:counter_inc(Type, start),
            set_rebalance_status(Type, running, Pid),

            {next_state, rebalancing,
             #rebalancing_state{rebalancer = Pid,
                                rebalance_observer = ObserverPid,
                                eject_nodes = [],
                                keep_nodes = [],
                                failed_nodes = [],
                                delta_recov_bkts = [],
                                retry_check = RetryChk,
                                to_failover = Nodes,
                                abort_reason = undefined,
                                type = Type,
                                rebalance_id = Id},
             [{reply, From, ok}]};
        {error, RV} ->
            misc:unlink_terminate_and_wait(ObserverPid, kill),
            {keep_state_and_data, [{reply, From, RV}]}
    end;
%% NOTE: this is not remotely called but is used by maybe_start_rebalance
idle({start_rebalance, Params = #{keep_nodes := KeepNodes,
                                  eject_nodes := EjectNodes,
                                  failed_nodes := FailedNodes,
                                  delta_nodes := DeltaNodes,
                                  delta_recovery_buckets :=
                                      DeltaRecoveryBuckets,
                                  services := Services,
                                  id := RebalanceId}}, From, _State) ->

    NodesInfo = [{active_nodes, KeepNodes ++ EjectNodes},
                 {keep_nodes, KeepNodes},
                 {eject_nodes, EjectNodes},
                 {delta_nodes, DeltaNodes},
                 {failed_nodes, FailedNodes}],
    Type = rebalance,

    {ServicesToObserve, ServicesMsg} =
        case Services of
            all ->
                {ns_cluster_membership:cluster_supported_services(), []};
            Services ->
                {Services,
                 lists:flatten(io_lib:format(" Services = ~p;", [Services]))}
        end,
    {ok, ObserverPid} = ns_rebalance_observer:start_link(
                          ServicesToObserve, NodesInfo, Type, RebalanceId),
    DeltaRecoveryMsg =
        case DeltaNodes of
            [] ->
                "no delta recovery nodes";
            _ ->
                lists:flatten(
                  io_lib:format(
                    "Delta recovery nodes = ~p, Delta recovery buckets = ~p;",
                    [DeltaNodes, DeltaRecoveryBuckets]))
        end,

    Msg = lists:flatten(
            io_lib:format(
              "Starting rebalance, KeepNodes = ~p, EjectNodes = ~p, "
              "Failed over and being ejected nodes = ~p; ~s;~s "
              "Operation Id = ~s",
              [KeepNodes, EjectNodes, FailedNodes, DeltaRecoveryMsg,
               ServicesMsg, RebalanceId])),

    ?log_info(Msg),
    case ns_rebalancer:start_link_rebalance(Params) of
        {ok, Pid} ->
            ale:info(?USER_LOGGER, Msg),
            event_log:add_log(rebalance_initiated,
                              [{operation_id, RebalanceId},
                               {nodes_info, {NodesInfo}}]),
            ns_cluster:counter_inc(Type, start),
            set_rebalance_status(Type, running, Pid),
            ReturnValue =
                case cluster_compat_mode:is_cluster_elixir() of
                    true ->
                        {ok, RebalanceId};
                    false ->
                        ok
                end,

            {next_state, rebalancing,
             #rebalancing_state{rebalancer = Pid,
                                rebalance_observer = ObserverPid,
                                keep_nodes = KeepNodes,
                                eject_nodes = EjectNodes,
                                failed_nodes = FailedNodes,
                                delta_recov_bkts = DeltaRecoveryBuckets,
                                retry_check = maps:get(chk, Params, undefined),
                                to_failover = [],
                                abort_reason = undefined,
                                type = Type,
                                rebalance_id = RebalanceId},
             [{reply, From, ReturnValue}]};
        {error, Error} ->
            ?log_info("Rebalance ~p was not started due to error: ~p",
                      [RebalanceId, Error]),
            misc:unlink_terminate_and_wait(ObserverPid, kill),
            {keep_state_and_data, [{reply, From, Error}]}
    end;
idle({move_vbuckets, Bucket, Moves}, From, _State) ->
    Id = couch_uuids:random(),
    KeepNodes = ns_node_disco:nodes_wanted(),
    Type = move_vbuckets,
    NodesInfo = [{active_nodes, ns_cluster_membership:active_nodes()},
                 {keep_nodes, KeepNodes}],
    Services = [kv],
    {ok, ObserverPid} = ns_rebalance_observer:start_link(
                          Services, NodesInfo, Type, Id),
    Pid = spawn_link(
            fun () ->
                    ns_rebalancer:move_vbuckets(Bucket, Moves)
            end),

    ?log_debug("Moving vBuckets in bucket ~p. Moves ~p. "
               "Operation Id = ~s", [Bucket, Moves, Id]),
    ns_cluster:counter_inc(Type, start),
    set_rebalance_status(Type, running, Pid),

    {next_state, rebalancing,
     #rebalancing_state{rebalancer = Pid,
                        rebalance_observer = ObserverPid,
                        keep_nodes = ns_node_disco:nodes_wanted(),
                        eject_nodes = [],
                        failed_nodes = [],
                        delta_recov_bkts = [],
                        retry_check = undefined,
                        to_failover = [],
                        abort_reason = undefined,
                        type = Type,
                        rebalance_id = Id},
     [{reply, From, ok}]};
idle(stop_rebalance, From, _State) ->
    rebalance:reset_status(
      fun () ->
              ale:info(?USER_LOGGER,
                       "Resetting rebalance status since rebalance stop "
                       "was requested but rebalance isn't orchestrated on "
                       "our node"),
              none
      end),
    {keep_state_and_data, [{reply, From, not_rebalancing}]};
idle({start_recovery, Bucket}, {FromPid, _} = From, _State) ->
    case recovery_server:start_recovery(Bucket, FromPid) of
        {ok, Pid, UUID, Map} ->
            {next_state, recovery, #recovery_state{pid = Pid},
             [{reply, From, {ok, UUID, Map}}]};
        Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
idle({ensure_janitor_run, Item}, From, State) ->
    do_request_janitor_run(
      Item,
      fun (Reason) ->
              gen_statem:reply(From, Reason)
      end, idle, State);

%% Start Pause/Resume bucket operations.
idle({{bucket_hibernation_op, {start, Op}},
      {#bucket_hibernation_op_args{bucket = Bucket} = Args,
       ExtraArgs}}, From, _State) ->
    Result =
        case Op of
            pause_bucket ->
                hibernation_utils:check_allow_pause_op(Bucket);
            resume_bucket ->
                [Metadata] = ExtraArgs,
                hibernation_utils:check_allow_resume_op(Bucket, Metadata)
        end,

    case Result of
        {ok, RunOpExtraArgs} ->
            run_hibernation_op(
              Op, Args, ExtraArgs ++ RunOpExtraArgs, From);
        {error, Error} ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
idle({{bucket_hibernation_op, {stop, Op}}, [_Bucket]}, From, _State) ->
    {keep_state_and_data, {reply, From, not_running(Op)}}.

%% Synchronous janitor_running events
janitor_running({ensure_janitor_run, Item}, From, State) ->
    do_request_janitor_run(
      Item,
      fun (Reason) ->
              gen_statem:reply(From, Reason)
      end, janitor_running, State);

janitor_running(Msg, From, #janitor_state{cleanup_id = ID})
  when ID =/= undefined ->
    %% When handling some call while janitor is running we kill janitor
    %% and then handle original call in idle state
    ok = ns_janitor_server:terminate_cleanup(ID),

    %% Eat up the cleanup_done message that gets sent by ns_janitor_server when
    %% the cleanup process ends.
    receive
        {cleanup_done, _, _} ->
            ok
    end,
    {next_state, idle, #idle_state{}, [{next_event, {call, From}, Msg}]}.

%% Asynchronous rebalancing events
rebalancing({timeout, _Tref, stop_timeout},
            #rebalancing_state{rebalancer = Pid} = State) ->
    ?log_debug("Stop rebalance timeout, brutal kill pid = ~p", [Pid]),
    exit(Pid, kill),
    Reason =
        receive
            {'EXIT', Pid, killed} ->
                %% still treat this as user-stopped rebalance
                {shutdown, stop};
            {'EXIT', Pid, R} ->
                R
        end,
    handle_rebalance_completion(Reason, State);
rebalancing({request_janitor_run, _Item} = Msg, _State) ->
    ?log_debug("Message ~p ignored", [Msg]),
    keep_state_and_data.

%% Synchronous rebalancing events
rebalancing({try_autofailover, Nodes, Options}, From,
            #rebalancing_state{type = Type} = State) ->
    case menelaus_web_auto_failover:config_check_can_abort_rebalance() andalso
         Type =/= failover of
        false ->
            TypeStr = binary_to_list(rebalance_type2text(Type)),
            {keep_state_and_data,
             [{reply, From, {operation_running, TypeStr}}]};
        true ->
            case stop_rebalance(State,
                                {try_autofailover, From, Nodes, Options}) of
                State ->
                    %% Unlikely event, that a user has stopped rebalance and
                    %% before rebalance has terminated we get an autofailover
                    %% request.
                    {keep_state_and_data,
                     [{reply, From, retry_aborting_rebalance}]};
                NewState ->
                    {keep_state, NewState}
            end
    end;
rebalancing({start_rebalance, _Params}, From, _State) ->
    ale:info(?USER_LOGGER,
             "Not rebalancing because rebalance is already in progress.~n"),
    {keep_state_and_data, [{reply, From, in_progress}]};
rebalancing({start_graceful_failover, _}, From, _State) ->
    {keep_state_and_data, [{reply, From, in_progress}]};
rebalancing({start_graceful_failover, _, _, _}, From, _State) ->
    {keep_state_and_data, [{reply, From, in_progress}]};
rebalancing({start_failover, _, _}, From, _State) ->
    {keep_state_and_data, [{reply, From, in_progress}]};
rebalancing(stop_rebalance, From,
            #rebalancing_state{rebalancer = Pid} = State) ->
    ?log_debug("Sending stop to rebalancer: ~p", [Pid]),
    {keep_state, stop_rebalance(State, user_stop), [{reply, From, ok}]};
rebalancing(Event, From, _State) ->
    ?log_warning("Got event ~p while rebalancing.", [Event]),
    {keep_state_and_data, [{reply, From, rebalance_running}]}.

%% Asynchronous recovery events
recovery(Event, _State) ->
    ?log_warning("Got unexpected event: ~p", [Event]),
    keep_state_and_data.

%% Synchronous recovery events
recovery({start_recovery, _Bucket}, From, _State) ->
    {keep_state_and_data, [{reply, From, recovery_running}]};
recovery({commit_vbucket, Bucket, UUID, VBucket}, From, State) ->
    Result = call_recovery_server(State,
                                  commit_vbucket, [Bucket, UUID, VBucket]),
    case Result of
        recovery_completed ->
            {next_state, idle, #idle_state{}, [{reply, From, Result}]};
        _ ->
            {keep_state_and_data, [{reply, From, Result}]}
    end;
recovery({stop_recovery, Bucket, UUID}, From, State) ->
    case call_recovery_server(State, stop_recovery, [Bucket, UUID]) of
        ok ->
            {next_state, idle, #idle_state{}, [{reply, From, ok}]};
        Error ->
            {keep_state_and_data, [{reply, From, Error}]}
    end;
recovery(recovery_status, From, State) ->
    {keep_state_and_data,
     [{reply, From, call_recovery_server(State, recovery_status)}]};
recovery({recovery_map, Bucket, RecoveryUUID}, From, State) ->
    {keep_state_and_data,
     [{reply, From,
       call_recovery_server(State, recovery_map, [Bucket, RecoveryUUID])}]};

recovery(stop_rebalance, From, _State) ->
    {keep_state_and_data, [{reply, From, not_rebalancing}]};
recovery(_Event, From, _State) ->
    {keep_state_and_data, [{reply, From, in_recovery}]}.

bucket_hibernation({try_autofailover, Nodes, Options}, From, State) ->
    {keep_state, stop_bucket_hibernation_op(
                   State, {try_autofailover, From, Nodes, Options})};

bucket_hibernation({{bucket_hibernation_op, {stop, Op}} = Msg, [Bucket]}, From,
                   #bucket_hibernation_state{
                      op = Op,
                      bucket = Bucket} = State) ->
    {keep_state, stop_bucket_hibernation_op(State, Msg),
     [{reply, From, ok}]};

%% Handle the cases when {stop, Op} doesn't match the current running Op, i.e:
%% 1. {stop, pause_bucket} while resume_bucket is running.
%% 2. {stop, resume_bucket} while pause_bucket is running.
%% 3. {stop, pause_bucket}/{stop, resume_bucket} for a bucket that isn't
%%    currently being paused/resumed.

bucket_hibernation({{bucket_hibernation_op, {stop, Op}}, [Bucket]}, From,
                   #bucket_hibernation_state{bucket = HibernatingBucket,
                                             op = RunningOp}) ->
    Reply =
        if
            Op =:= RunningOp ->
                bucket_not_found;
            Bucket =:= HibernatingBucket ->
                not_running(Op);
            true ->
                {errors, {bucket_not_found,
                          not_running(Op)}}
        end,

    {keep_state, [{reply, From, Reply}]};

%% Handle other msgs that come while ns_orchestrator is in the
%% bucket_hibernation_state.

bucket_hibernation(stop_rebalance, From, _State) ->
    {keep_state_and_data, [{reply, From, not_rebalancing}]};
bucket_hibernation(_Msg, From, _State) ->
    {keep_state_and_data, [{reply, From, in_bucket_hibernation}]}.

%%
%% Internal functions
%%
stop_rebalance(#rebalancing_state{rebalancer = Pid,
                                  abort_reason = undefined} = State, Reason) ->
    exit(Pid, {shutdown, stop}),
    TRef = erlang:start_timer(?STOP_REBALANCE_TIMEOUT, self(), stop_timeout),
    State#rebalancing_state{stop_timer = TRef, abort_reason = Reason};
stop_rebalance(State, _Reason) ->
    %% Do nothing someone has already tried to stop rebalance.
    State.

do_request_janitor_run(Item, FsmState, State) ->
    do_request_janitor_run(Item, fun(_Reason) -> ok end,
                           FsmState, State).

do_request_janitor_run(Item, Fun, FsmState, State) ->
    RV = ns_janitor_server:request_janitor_run({Item, [Fun]}),
    MaybeNewTimeout = case FsmState =:= idle andalso RV =:= added of
                          true ->
                              [{{timeout, janitor}, 0, run_janitor}];
                          false ->
                              []
                      end,
    {next_state, FsmState, State, MaybeNewTimeout}.

wait_for_nodes_loop([]) ->
    ok;
wait_for_nodes_loop(Nodes) ->
    receive
        {done, Node} ->
            wait_for_nodes_loop(Nodes -- [Node]);
        timeout ->
            {timeout, Nodes}
    end.

wait_for_nodes_check_pred(Status, Pred) ->
    Active = proplists:get_value(active_buckets, Status),
    case Active of
        undefined ->
            false;
        _ ->
            Pred(Active)
    end.

%% Wait till active buckets satisfy certain predicate on all nodes. After
%% `Timeout' milliseconds, we give up and return the list of leftover nodes.
-spec wait_for_nodes([node()],
                     fun(([string()]) -> boolean()),
                     timeout()) -> ok | {timeout, [node()]}.
wait_for_nodes(Nodes, Pred, Timeout) ->
    misc:executing_on_new_process(
      fun () ->
              Self = self(),

              ns_pubsub:subscribe_link(
                buckets_events,
                fun ({significant_buckets_change, Node}) ->
                        Status = ns_doctor:get_node(Node),

                        case wait_for_nodes_check_pred(Status, Pred) of
                            false ->
                                ok;
                            true ->
                                Self ! {done, Node}
                        end;
                    (_) ->
                        ok
                end),

              Statuses = ns_doctor:get_nodes(),
              InitiallyFilteredNodes =
                  lists:filter(
                    fun (N) ->
                            Status = ns_doctor:get_node(N, Statuses),
                            not wait_for_nodes_check_pred(Status, Pred)
                    end, Nodes),

              erlang:send_after(Timeout, Self, timeout),
              wait_for_nodes_loop(InitiallyFilteredNodes)
      end).

run_hibernation_op(Op,
                   #bucket_hibernation_op_args{
                      bucket = Bucket,
                      remote_path = RemotePath,
                      blob_storage_region = BlobStorageRegion,
                      rate_limit = RateLimit} = Args,
                   ExtraArgs, From) ->
    log_initiated_hibernation_event(Bucket, Op),

    Manager = hibernation_manager:run_op(Op, Args, ExtraArgs),

    ale:info(?USER_LOGGER, "Starting hibernation operation (~p) for bucket: "
             "~p, RemotePath - ~p, BlobStorageRegion - ~p, "
             "RateLimit - ~.2f MiB/s.",
             [Op, Bucket, RemotePath, BlobStorageRegion, RateLimit / ?MIB]),

    hibernation_utils:set_hibernation_status(Bucket, {Op, running}),
    {next_state, bucket_hibernation,
     #bucket_hibernation_state{hibernation_manager = Manager,
                               bucket = Bucket,
                               op = Op},
     [{reply, From, ok}]}.

perform_bucket_flushing(BucketName) ->
    case ns_bucket:get_bucket(BucketName) of
        not_present ->
            bucket_not_found;
        {ok, BucketConfig} ->
            case proplists:get_value(flush_enabled, BucketConfig, false) of
                true ->
                    RV = perform_bucket_flushing_with_config(BucketName,
                                                             BucketConfig),
                    case RV of
                        ok ->
                            UUID = ns_bucket:uuid(BucketName, direct),
                            event_log:add_log(
                              bucket_flushed,
                              [{bucket, list_to_binary(BucketName)},
                               {bucket_uuid, UUID}]),
                            ok;

                        _ ->
                            RV
                    end;
                false ->
                    flush_disabled
            end
    end.


perform_bucket_flushing_with_config(BucketName, BucketConfig) ->
    ale:info(?MENELAUS_LOGGER, "Flushing bucket ~p from node ~p",
             [BucketName, erlang:node()]),
    case ns_bucket:bucket_type(BucketConfig) =:= memcached of
        true ->
            do_flush_old_style(BucketName, BucketConfig);
        _ ->
            RV = do_flush_bucket(BucketName, BucketConfig),
            case RV of
                ok ->
                    ?log_info("Requesting janitor run to actually "
                              "revive bucket ~p after flush", [BucketName]),
                    JanitorRV = ns_janitor:cleanup(
                                  BucketName, [{query_states_timeout, 1000}]),
                    case JanitorRV of
                        ok -> ok;
                        _ ->
                            ?log_error("Flusher's janitor run failed: ~p",
                                       [JanitorRV])
                    end,
                    RV;
                _ ->
                    RV
            end
    end.

do_flush_bucket(BucketName, BucketConfig) ->
    Nodes = ns_bucket:get_servers(BucketConfig),
    case ns_config_rep:ensure_config_seen_by_nodes(Nodes) of
        ok ->
            case janitor_agent:mass_prepare_flush(BucketName, Nodes) of
                {_, [], []} ->
                    continue_flush_bucket(BucketName, BucketConfig, Nodes);
                {_, BadResults, BadNodes} ->
                    %% NOTE: I'd like to undo prepared flush on good
                    %% nodes, but given we've lost information whether
                    %% janitor ever marked them as warmed up I
                    %% cannot. We'll do it after some partial
                    %% janitoring support is achieved. And for now
                    %% we'll rely on janitor cleaning things up.
                    {error, {prepare_flush_failed, BadNodes, BadResults}}
            end;
        {error, SyncFailedNodes} ->
            {error, {initial_config_sync_failed, SyncFailedNodes}}
    end.

continue_flush_bucket(BucketName, BucketConfig, Nodes) ->
    OldFlushCount = proplists:get_value(flushseq, BucketConfig, 0),
    NewConfig = lists:keystore(flushseq, 1, BucketConfig,
                               {flushseq, OldFlushCount + 1}),
    ns_bucket:set_bucket_config(BucketName, NewConfig),
    case ns_config_rep:ensure_config_seen_by_nodes(Nodes) of
        ok ->
            finalize_flush_bucket(BucketName, Nodes);
        {error, SyncFailedNodes} ->
            {error, {flush_config_sync_failed, SyncFailedNodes}}
    end.

finalize_flush_bucket(BucketName, Nodes) ->
    {_GoodNodes, FailedCalls, FailedNodes} =
        janitor_agent:complete_flush(BucketName, Nodes, ?FLUSH_BUCKET_TIMEOUT),
    case FailedCalls =:= [] andalso FailedNodes =:= [] of
        true ->
            ok;
        _ ->
            {error, {flush_wait_failed, FailedNodes, FailedCalls}}
    end.

do_flush_old_style(BucketName, BucketConfig) ->
    Nodes = ns_bucket:get_servers(BucketConfig),
    {Results, BadNodes} =
        rpc:multicall(Nodes, ns_memcached, flush, [BucketName],
                      ?MULTICALL_DEFAULT_TIMEOUT),
    case BadNodes =:= [] andalso lists:all(fun(A) -> A =:= ok end, Results) of
        true ->
            ok;
        false ->
            {old_style_flush_failed, Results, BadNodes}
    end.

set_rebalance_status(move_vbuckets, Status, Pid) ->
    set_rebalance_status(rebalance, Status, Pid);
set_rebalance_status(service_upgrade, Status, Pid) ->
    set_rebalance_status(rebalance, Status, Pid);
set_rebalance_status(Type, Status, Pid) ->
    rebalance:set_status(Type, Status, Pid).

cancel_stop_timer(TRef) ->
    do_cancel_stop_timer(TRef).

do_cancel_stop_timer(undefined) ->
    ok;
do_cancel_stop_timer(TRef) when is_reference(TRef) ->
    _ = erlang:cancel_timer(TRef),
    receive {timeout, TRef, _} -> 0
    after 0 -> ok
    end.

maybe_try_autofailover_in_idle_state(
  {try_autofailover, From, Nodes, Options}) ->
    {next_state, idle, #idle_state{},
     [{next_event, {call, From}, {try_autofailover, Nodes, Options}}]};
maybe_try_autofailover_in_idle_state(_) ->
    {next_state, idle, #idle_state{}}.

terminate_observer(#rebalancing_state{rebalance_observer = undefined}) ->
    ok;
terminate_observer(#rebalancing_state{rebalance_observer = ObserverPid}) ->
    misc:unlink_terminate_and_wait(ObserverPid, kill).

handle_rebalance_completion({shutdown, {ok, _}} = ExitReason, State) ->
    handle_rebalance_completion(normal, ExitReason, State);
handle_rebalance_completion(ExitReason, State) ->
    handle_rebalance_completion(ExitReason, ExitReason, State).

handle_rebalance_completion(ExitReason, ToReply, State) ->
    cancel_stop_timer(State#rebalancing_state.stop_timer),
    maybe_reset_autofailover_count(ExitReason, State),
    maybe_reset_reprovision_count(ExitReason, State),
    {ResultType, Msg} = log_rebalance_completion(ExitReason, State),
    maybe_retry_rebalance(ExitReason, State),
    update_rebalance_counters(ExitReason, State),
    ns_rebalance_observer:record_rebalance_report(
      {ResultType, list_to_binary(Msg)}),
    update_rebalance_status(ExitReason, State),
    rpc:eval_everywhere(diag_handler, log_all_dcp_stats, []),
    terminate_observer(State),
    maybe_reply_to(ToReply, State),
    maybe_request_janitor_run(ExitReason, State),

    R = compat_mode_manager:consider_switching_compat_mode(),
    case maybe_start_service_upgrader(ExitReason, R, State) of
        {started, NewState} ->
            {next_state, rebalancing, NewState};
        not_needed ->
            maybe_eject_myself(ExitReason, State),
            %% Use the reason for aborting rebalance here, and not the reason
            %% for exit, we should base our next state and following activities
            %% based on the reason for aborting rebalance.
            maybe_try_autofailover_in_idle_state(
              State#rebalancing_state.abort_reason)
    end.

maybe_request_janitor_run({failover_failed, Bucket, _},
                          #rebalancing_state{type = failover}) ->
    ?log_debug("Requesting janitor run for bucket ~p after unsuccessful "
               "failover", [Bucket]),
    request_janitor_run({bucket, Bucket});
maybe_request_janitor_run(_, _) ->
    ok.

maybe_retry_rebalance(ExitReason,
                      #rebalancing_state{type = Type,
                                         rebalance_id = ID} = State) ->
    case retry_rebalance(ExitReason, State) of
        true ->
            ok;
        false ->
            %% Cancel retry if there is one pending from previous failure.
            By = binary_to_list(rebalance_type2text(Type)) ++ " completion",
            auto_rebalance:cancel_pending_retry_async(ID, By)
    end.

retry_rebalance(normal, _State) ->
    false;
retry_rebalance({shutdown, stop}, _State) ->
    false;
retry_rebalance(_, #rebalancing_state{type = rebalance,
                                      keep_nodes = KNs,
                                      eject_nodes = ENs,
                                      failed_nodes = FNs,
                                      delta_recov_bkts = DRBkts,
                                      retry_check = Chk,
                                      rebalance_id = Id}) ->
    case lists:member(node(), FNs) of
        true ->
            ?log_debug("Orchestrator is one of the failed nodes "
                       "and may be ejected. "
                       "Failed rebalance with Id = ~s will not be retried.",
                       [Id]),
            false;
        false ->
            %% Restore the KnownNodes & EjectedNodes to the way they were
            %% at the start of this rebalance.
            EjectedNodes0 = FNs ++ ENs,
            KnownNodes0 = EjectedNodes0 ++ KNs,

            %% Rebalance may have ejected some nodes before failing.
            EjectedByReb = KnownNodes0 -- ns_node_disco:nodes_wanted(),

            %% KnownNodes0 was equal to ns_node_disco:nodes_wanted()
            %% at the start of this rebalance. So, EjectedByReb
            %% will be the nodes that have been ejected by this rebalance.
            %% These will be the nodes in either the failed nodes or eject
            %% nodes list.
            %% As an extra sanity check verify that there are no
            %% additional nodes in EjectedByReb.
            case EjectedByReb -- EjectedNodes0 of
                [] ->
                    KnownNodes = KnownNodes0 -- EjectedByReb,
                    EjectedNodes = EjectedNodes0 -- EjectedByReb,

                    NewChk = update_retry_check(EjectedByReb, Chk),
                    Params = [{known_nodes,  KnownNodes},
                              {eject_nodes, EjectedNodes},
                              {delta_recovery_buckets, DRBkts}],

                    auto_rebalance:retry_rebalance(rebalance, Params, Id,
                                                   NewChk);

                Extras ->
                    ale:info(?USER_LOGGER,
                             "~p nodes have been removed from the "
                             "nodes_wanted() list. This is not expected. "
                             "Rebalance with Id ~s will not be retried.",
                             [Extras, Id]),
                    false
            end
    end;

retry_rebalance(_, #rebalancing_state{type = graceful_failover,
                                      to_failover = Nodes,
                                      retry_check = Chk,
                                      rebalance_id = Id}) ->
    auto_rebalance:retry_rebalance(graceful_failover, [{nodes, Nodes}],
                                   Id, Chk);

retry_rebalance(_, _) ->
    false.

%% Fail the retry if there are newly failed over nodes,
%% server group configuration has changed or buckets have been added
%% or deleted or their replica count changed.
retry_ok(Snapshot, FailedNodes, #{chk := RetryChk}) ->
    retry_ok(RetryChk, get_retry_check(Snapshot, FailedNodes));
retry_ok(Snapshot, FailedNodes, _) ->
    get_retry_check(Snapshot, FailedNodes).

retry_ok(Chk, Chk) ->
    Chk;
retry_ok(RetryChk, NewChk) ->
    ?log_debug("Retry check failed. (RetryChk -- NewChk): ~p~n"
               "(NewChk -- RetryChk): ~p",
               [RetryChk -- NewChk, NewChk -- RetryChk]),
    false.

get_retry_check(Snapshot, FailedNodes) ->
    SGs = ns_cluster_membership:server_groups(Snapshot),
    [{failed_nodes, lists:sort(FailedNodes)},
     {server_groups, groups_chk(SGs, fun (Nodes) -> Nodes end)},
     {buckets, buckets_chk(Snapshot)}].

buckets_chk(Snapshot) ->
    Bkts = lists:map(fun({B, BC}) ->
                             {B, proplists:get_value(num_replicas, BC),
                              ns_bucket:uuid(B, Snapshot)}
                     end, ns_bucket:get_buckets(Snapshot)),
    erlang:phash2(lists:sort(Bkts)).

groups_chk(SGs, UpdateFn) ->
    lists:map(
      fun (SG) ->
              Nodes = lists:sort(proplists:get_value(nodes, SG, [])),
              lists:keyreplace(nodes, 1, SG, {nodes, UpdateFn(Nodes)})
      end, SGs).

update_retry_check([], Chk0) ->
    Chk0;
update_retry_check(EjectedByReb, Chk0) ->
    ENs = lists:sort(EjectedByReb),
    FNs = proplists:get_value(failed_nodes, Chk0) -- ENs,
    Chk1 = lists:keyreplace(failed_nodes, 1, Chk0, {failed_nodes, FNs}),

    %% User may have changed server group configuration during rebalance.
    %% In that case, we want to fail the retry.
    %% So, we save the server group configuration at the start of rebalance
    %% However, we need to account for nodes ejected by rebalance itself.
    SGs0 = proplists:get_value(server_groups, Chk1),
    UpdateFn = fun (Nodes) -> Nodes -- ENs end,
    lists:keyreplace(server_groups, 1, Chk1,
                     {server_groups, groups_chk(SGs0, UpdateFn)}).

get_failed_nodes(Snapshot, KnownNodes) ->
    [N || N <- KnownNodes,
          ns_cluster_membership:get_cluster_membership(N, Snapshot)
              =:= inactiveFailed].

graceful_failover_retry_ok(Chk) ->
    retry_ok(Chk, get_graceful_fo_chk()).

get_graceful_fo_chk() ->
    Cfg = ns_config:get(),
    Snapshot = chronicle_compat:get_snapshot(
                 [ns_bucket:fetch_snapshot(all, _, [uuid, props]),
                  ns_cluster_membership:fetch_snapshot(_)],
                 #{ns_config => Cfg}),
    KnownNodes0 = ns_cluster_membership:nodes_wanted(Snapshot),
    UUIDDict = ns_config:get_node_uuid_map(Cfg),
    KnownNodes = ns_cluster_membership:attach_node_uuids(KnownNodes0, UUIDDict),
    FailedNodes = get_failed_nodes(Snapshot, KnownNodes0),
    [{known_nodes, KnownNodes}] ++ get_retry_check(Snapshot, FailedNodes).

maybe_eject_myself(Reason, State) ->
    case need_eject_myself(Reason, State) of
        true ->
            eject_myself(State);
        false ->
            ok
    end.

need_eject_myself(normal, #rebalancing_state{eject_nodes = EjectNodes,
                                             failed_nodes = FailedNodes}) ->
    lists:member(node(), EjectNodes) orelse lists:member(node(), FailedNodes);
need_eject_myself(_Reason, #rebalancing_state{failed_nodes = FailedNodes}) ->
    lists:member(node(), FailedNodes).

eject_myself(#rebalancing_state{keep_nodes = KeepNodes}) ->
    ok = ns_config_rep:ensure_config_seen_by_nodes(KeepNodes),
    ns_rebalancer:eject_nodes([node()]).

maybe_reset_autofailover_count(normal, #rebalancing_state{type = rebalance}) ->
    auto_failover:reset_count_async();
maybe_reset_autofailover_count(_, _) ->
    ok.

maybe_reset_reprovision_count(normal, #rebalancing_state{type = rebalance}) ->
    auto_reprovision:reset_count();
maybe_reset_reprovision_count(_, _) ->
    ok.

log_rebalance_completion(
  ExitReason, #rebalancing_state{type = Type, abort_reason = AbortReason,
                                 rebalance_id = RebalanceId}) ->
    {ResultType, Severity, Fmt, Args} = get_log_msg(ExitReason,
                                                    Type,
                                                    AbortReason),
    ale:log(?USER_LOGGER, Severity, Fmt ++ "~nRebalance Operation Id = ~s",
            Args ++ [RebalanceId]),
    {ResultType, lists:flatten(io_lib:format(Fmt, Args))}.

% ResultType() is used to add an event log with the appropriate event-id
% via rebalance_observer.
-spec get_log_msg(any(), any(), any()) -> {ResultType :: success | failure |
                                           interrupted,
                                           LogLevel :: info | error,
                                           Fmt :: io:format(),
                                           Args :: [term()]}.

get_log_msg(normal, Type, _) ->
    {success, info, "~s completed successfully.",
     [rebalance_type2text(Type)]};
get_log_msg({shutdown, stop}, Type, AbortReason) ->
    get_log_msg(AbortReason, Type);
get_log_msg(Error, Type, undefined) ->
    {failure, error, "~s exited with reason ~p.",
     [rebalance_type2text(Type), Error]};
get_log_msg(_Error, Type, AbortReason) ->
    get_log_msg(AbortReason, Type).

get_log_msg({try_autofailover, _, Nodes, _}, Type) ->
    {interrupted, info, "~s interrupted due to auto-failover of nodes ~p.",
     [rebalance_type2text(Type), Nodes]};
get_log_msg({rebalance_observer_terminated, Reason}, Type) ->
    {failure, error, "~s interrupted as observer exited with reason ~p.",
     [rebalance_type2text(Type), Reason]};
get_log_msg(user_stop, Type) ->
    {interrupted, info, "~s stopped by user.",
     [rebalance_type2text(Type)]}.

rebalance_type2text(rebalance) ->
    <<"Rebalance">>;
rebalance_type2text(move_vbuckets) ->
    rebalance_type2text(rebalance);
rebalance_type2text(failover) ->
    <<"Failover">>;
rebalance_type2text(graceful_failover) ->
    <<"Graceful failover">>;
rebalance_type2text(service_upgrade) ->
    <<"Service upgrade">>.

update_rebalance_counters(Reason, #rebalancing_state{type = Type}) ->
    Counter =
        case Reason of
            normal ->
                success;
            {shutdown, stop} ->
                stop;
            _Error ->
                fail
        end,

    ns_cluster:counter_inc(Type, Counter).

update_rebalance_status(Reason, #rebalancing_state{type = Type}) ->
    set_rebalance_status(Type, reason2status(Reason, Type), undefined).

reason2status(normal, _Type) ->
    none;
reason2status({shutdown, stop}, _Type) ->
    none;
reason2status(_Error, Type) ->
    Msg = io_lib:format(
            "~s failed. See logs for detailed reason. "
            "You can try again.",
            [rebalance_type2text(Type)]),
    {none, iolist_to_binary(Msg)}.

maybe_start_service_upgrader(normal, unchanged, _State) ->
    not_needed;
maybe_start_service_upgrader(normal, {changed, OldVersion, NewVersion},
                             #rebalancing_state{keep_nodes = KeepNodes,
                                                rebalance_id = Id} = State) ->
    Old = ns_cluster_membership:topology_aware_services_for_version(OldVersion),
    New = ns_cluster_membership:topology_aware_services_for_version(NewVersion),

    Services = [S || S <- New -- Old,
                     ns_cluster_membership:service_nodes(KeepNodes, S) =/= []],
    case Services of
        [] ->
            not_needed;
        _ ->
            ale:info(?USER_LOGGER,
                     "Starting upgrade for the following services: ~p",
                     [Services]),
            Type = service_upgrade,
            NodesInfo = [{active_nodes, KeepNodes},
                         {keep_nodes, KeepNodes}],
            {ok, ObserverPid} = ns_rebalance_observer:start_link(
                                  Services, NodesInfo, Type, Id),
            Pid = start_service_upgrader(KeepNodes, Services),

            set_rebalance_status(Type, running, Pid),
            ns_cluster:counter_inc(Type, start),
            NewState = State#rebalancing_state{type = Type,
                                               rebalance_observer = ObserverPid,
                                               rebalancer = Pid},

            {started, NewState}
    end;
maybe_start_service_upgrader(_Reason, _SwitchCompatResult, _State) ->
    %% rebalance failed, so we'll just let the user start rebalance again
    not_needed.

start_service_upgrader(KeepNodes, Services) ->
    proc_lib:spawn_link(
      fun () ->
              ok = leader_activities:run_activity(
                     service_upgrader, majority,
                     fun () ->
                             service_upgrader_body(Services, KeepNodes)
                     end)
      end).

service_upgrader_body(Services, KeepNodes) ->
    ok = service_janitor:cleanup(),

    %% since we are not actually ejecting anything here, we can ignore the
    %% return value
    EjectNodes = [],
    _ = ns_rebalancer:rebalance_topology_aware_services(
          Services, KeepNodes, EjectNodes),
    ok.

call_recovery_server(State, Call) ->
    call_recovery_server(State, Call, []).

call_recovery_server(#recovery_state{pid = Pid}, Call, Args) ->
    erlang:apply(recovery_server, Call, [Pid | Args]).

get_delta_recovery_nodes(Snapshot, Nodes) ->
    [N || N <- Nodes,
          ns_cluster_membership:get_cluster_membership(N, Snapshot)
              =:= inactiveAdded
              andalso ns_cluster_membership:get_recovery_type(Snapshot, N)
              =:= delta].

rebalance_allowed(Snapshot) ->
    case chronicle_compat:enabled() of
        true ->
            check_for_unfinished_failover(Snapshot);
        false ->
            ok
    end.

validate_services(all, _, _, _) ->
    ok;
validate_services(_, _, DeltaNodes, _) when DeltaNodes =/= [] ->
    throw({must_rebalance_services, all});
validate_services(Services, NodesToEject, [], Snapshot) ->
    case Services -- ns_cluster_membership:hosted_services(Snapshot) of
        [] ->
            ok;
        ExtraServices ->
            throw({unhosted_services, ExtraServices})
    end,
    case get_uninitialized_services(Services, Snapshot) ++
        get_unejected_services(Services, NodesToEject, Snapshot) of
        [] ->
            ok;
        NeededServices ->
            throw({must_rebalance_services, lists:usort(NeededServices)})
    end.

get_uninitialized_services(Services, Snapshot) ->
    ns_cluster_membership:nodes_services(
      Snapshot, ns_cluster_membership:inactive_added_nodes(Snapshot)) --
        Services.

get_unejected_services(Services, NodesToEject, Snapshot) ->
    ns_cluster_membership:nodes_services(Snapshot, NodesToEject) -- Services.

check_for_unfinished_failover(Snapshot) ->
    case chronicle_master:get_prev_failover_nodes(Snapshot) of
        [] ->
            ok;
        Nodes ->
            {error, io_lib:format("Unfinished failover of nodes ~p was found.",
                                  [Nodes])}
    end.

handle_start_failover(Nodes, AllowUnsafe, From, Wait, FailoverType, Options) ->
    auto_rebalance:cancel_any_pending_retry_async("failover"),

    ActiveNodes = ns_cluster_membership:active_nodes(),
    NodesInfo = [{active_nodes, ActiveNodes},
                 {failover_nodes, Nodes},
                 {master_node, node()}],
    Id = couch_uuids:random(),
    {ok, ObserverPid} =
        ns_rebalance_observer:start_link([], NodesInfo, FailoverType, Id),
    case failover:start(Nodes,
                        maps:merge(#{allow_unsafe => AllowUnsafe,
                                     auto => FailoverType =:= auto_failover},
                                   Options)) of
        {ok, Pid} ->
            ale:info(?USER_LOGGER, "Starting failover of nodes ~p AllowUnsafe = ~p "
                     "Operation Id = ~s", [Nodes, AllowUnsafe, Id]),

            Event = list_to_atom(atom_to_list(FailoverType) ++ "_initiated"),

            FailoverReasons = maps:get(failover_reasons, Options, []),
            JSONFun = fun (V) when is_list(V) ->
                              list_to_binary(V);
                          (V) ->
                              V
                      end,
            FOReasonsJSON = case FailoverReasons of
                                 [] ->
                                     [];
                                 _ ->
                                     [{failover_reason,
                                       {[{Node, JSONFun(Reason)} ||
                                         {Node, Reason} <- FailoverReasons]}}]
                             end,
            event_log:add_log(Event, [{operation_id, Id},
                                      {nodes_info, {NodesInfo}},
                                      {allow_unsafe, AllowUnsafe}] ++
                                      FOReasonsJSON),

            Type = failover,
            ns_cluster:counter_inc(Type, start),
            set_rebalance_status(Type, running, Pid),
            NewState = #rebalancing_state{rebalancer = Pid,
                                          rebalance_observer = ObserverPid,
                                          eject_nodes = [],
                                          keep_nodes = [],
                                          failed_nodes = [],
                                          delta_recov_bkts = [],
                                          retry_check = undefined,
                                          to_failover = Nodes,
                                          abort_reason = undefined,
                                          type = Type,
                                          rebalance_id = Id},
            case Wait of
                false ->
                    {next_state, rebalancing, NewState, [{reply, From, ok}]};
                true ->
                    {next_state, rebalancing,
                     NewState#rebalancing_state{reply_to = From}}
            end;
        Error ->
            misc:unlink_terminate_and_wait(ObserverPid, kill),
            {keep_state_and_data, [{reply, From, Error}]}
    end.

maybe_reply_to(_, #rebalancing_state{reply_to = undefined}) ->
    ok;
maybe_reply_to(normal, State) ->
    maybe_reply_to(ok, State);
maybe_reply_to({shutdown, {ok, []}}, State) ->
    maybe_reply_to(ok, State);
maybe_reply_to({shutdown, {ok, UnsafeNodes}}, State) ->
    maybe_reply_to({ok, UnsafeNodes}, State);
maybe_reply_to({shutdown, stop}, State) ->
    maybe_reply_to(stopped_by_user, State);
maybe_reply_to(Reason, #rebalancing_state{reply_to = ReplyTo}) ->
    gen_statem:reply(ReplyTo, Reason).

%% Handler for messages that come to the gen_statem in bucket_hibernation
%% state.
handle_info_in_bucket_hibernation(
  {timeout, TRef, {Op, stop}},
  #bucket_hibernation_state{
     hibernation_manager = Manager,
     stop_tref = TRef,
     stop_reason = StopReason,
     bucket = Bucket,
     op = Op}) ->
    %% The hibernation_manager couldn't be gracefully killed - brutally kill it
    %% at the end of the graceful kill timeout.
    misc:unlink_terminate_and_wait(Manager, kill),
    handle_hibernation_manager_shutdown(StopReason, Bucket, Op),
    maybe_try_autofailover_in_idle_state(StopReason);

handle_info_in_bucket_hibernation(
  {'EXIT', Manager, Reason},
  #bucket_hibernation_state{
     hibernation_manager = Manager,
     bucket = Bucket,
     op = Op,
     stop_tref = TRef,
     stop_reason = StopReason}) ->
    cancel_stop_timer(TRef),
    handle_hibernation_manager_exit(Reason, Bucket, Op),
    maybe_try_autofailover_in_idle_state(StopReason);

handle_info_in_bucket_hibernation(Msg, State) ->
    ?log_debug("Message ~p ignored in State: ", [Msg, State]),
    keep_state_and_data.

-spec handle_hibernation_manager_exit(Reason, Bucket, Op) -> ok
    when Reason :: normal | shutdown | {shutdown, stop} |
                   bucket_delete_failed | any(),
         Bucket :: bucket_name(),
         Op :: pause_bucket | resume_bucket.

handle_hibernation_manager_exit(normal, Bucket, pause_bucket) ->

    %% At the end of successfully pausing a bucket, mark the bucket
    %% for deletion. TODO - do we have to do this as a
    %% transaction in chronicle??
    case handle_delete_bucket(Bucket) of
        ok ->
            ale:debug(?USER_LOGGER, "pause_bucket done for Bucket ~p.",
                      [Bucket]),
            log_hibernation_event(Bucket, pause_bucket_completed),
            hibernation_utils:update_hibernation_status(completed);
        Reason ->
            handle_hibernation_manager_exit({bucket_delete_failed, Reason},
                                            Bucket, pause_bucket)
    end;

handle_hibernation_manager_exit(normal, Bucket, resume_bucket) ->
    ale:debug(?USER_LOGGER, "resume_bucket done for Bucket ~p.", [Bucket]),
    log_hibernation_event(Bucket, resume_bucket_completed),
    hibernation_utils:update_hibernation_status(completed);

handle_hibernation_manager_exit(shutdown , Bucket, Op) ->
    handle_hibernation_manager_shutdown(shutdown, Bucket, Op);
handle_hibernation_manager_exit({shutdown, _} = Reason, Bucket, Op) ->
    handle_hibernation_manager_shutdown(Reason, Bucket, Op);
handle_hibernation_manager_exit(Reason, Bucket, Op) ->
    ale:error(?USER_LOGGER, "~p for Bucket ~p failed. Reason: ~p",
              [Op, Bucket, Reason]),
    log_failed_hibernation_event(Bucket, Op),
    hibernation_utils:update_hibernation_status(failed).

handle_hibernation_manager_shutdown(Reason, Bucket, Op) ->
    ale:debug(?USER_LOGGER, "~p for Bucket ~p stopped. Reason: ~p.",
              [Op, Bucket, Reason]),
    log_stopped_hibernation_event(Bucket, Op),
    hibernation_utils:update_hibernation_status(stopped).

log_hibernation_event(Bucket, EventId) ->
    event_log:add_log(EventId, [{bucket, list_to_binary(Bucket)}]).

log_initiated_hibernation_event(Bucket, pause_bucket) ->
    log_hibernation_event(Bucket, pause_bucket_initiated);
log_initiated_hibernation_event(Bucket, resume_bucket) ->
    log_hibernation_event(Bucket, resume_bucket_initiated).

log_failed_hibernation_event(Bucket, pause_bucket) ->
    log_hibernation_event(Bucket, pause_bucket_failed);
log_failed_hibernation_event(Bucket, resume_bucket) ->
    log_hibernation_event(Bucket, resume_bucket_failed).

log_stopped_hibernation_event(Bucket, pause_bucket) ->
    log_hibernation_event(Bucket, pause_bucket_stopped);
log_stopped_hibernation_event(Bucket, resume_bucket) ->
    log_hibernation_event(Bucket, resume_bucket_stopped).

-spec not_running(Op :: pause_bucket | resume_bucket) -> atom().
not_running(Op) ->
    list_to_atom("not_running_" ++ atom_to_list(Op)).

get_hibernation_op_stop_timeout(pause_bucket) ->
    ?STOP_PAUSE_BUCKET_TIMEOUT;
get_hibernation_op_stop_timeout(resume_bucket) ->
    ?STOP_RESUME_BUCKET_TIMEOUT.

stop_bucket_hibernation_op(#bucket_hibernation_state{
                             hibernation_manager = Manager,
                             op = Op,
                             stop_tref = undefined} = State, Reason) ->
    exit(Manager, {shutdown, stop}),
    TRef = erlang:start_timer(
             get_hibernation_op_stop_timeout(Op), self(), {stop, Op}),
    State#bucket_hibernation_state{stop_tref = TRef,
                                   stop_reason = Reason};
%% stop_tref is not 'undefined' and therefore a previously initated stop is
%% current running; do a simple pass-through and update the stop_reason
%% if necessary.
stop_bucket_hibernation_op(State, Reason) ->
    %% If we receive a try_autofailover while we are stopping a bucket
    %% hibernation op - we simply update the stop_reason with the
    %% try_autofailover one, to process the autofailover message after the
    %% bucket_hibernation op has been stopped.
    case Reason of
        {try_autofailover, _, _, _} ->
            State#bucket_hibernation_state{stop_reason = Reason};
        _ ->
            State
    end.

handle_delete_bucket(BucketName) ->
    menelaus_users:cleanup_bucket_roles(BucketName),
    case ns_bucket:delete_bucket(BucketName) of
        {ok, BucketConfig} ->
            master_activity_events:note_bucket_deletion(BucketName),
            BucketUUID = proplists:get_value(uuid, BucketConfig),
            event_log:add_log(bucket_deleted, [{bucket,
                                                list_to_binary(BucketName)},
                                               {bucket_uuid, BucketUUID}]),
            ns_janitor_server:delete_bucket_request(BucketName),

            Nodes = ns_bucket:get_servers(BucketConfig),
            Pred = fun (Active) ->
                           not lists:member(BucketName, Active)
                   end,
            Timeout = case ns_bucket:kv_backend_type(BucketConfig) of
                          magma ->
                              ?DELETE_MAGMA_BUCKET_TIMEOUT;
                          _ ->
                              ?DELETE_BUCKET_TIMEOUT
                      end,
            LeftoverNodes =
            case wait_for_nodes(Nodes, Pred, Timeout) of
                ok ->
                    [];
                {timeout, LeftoverNodes0} ->
                    ?log_warning("Nodes ~p failed to delete bucket ~p "
                                 "within expected time (~p msecs).",
                                 [LeftoverNodes0, BucketName, Timeout]),
                    LeftoverNodes0
            end,

            case LeftoverNodes of
                [] ->
                    ok;
                _ ->
                    {shutdown_failed, LeftoverNodes}
            end;
        Other ->
            Other
    end.

validate_create_bucket(BucketName, BucketConfig) ->
    try
        not ns_bucket:name_conflict(BucketName) orelse
            throw({already_exists, BucketName}),

        {Results, FailedNodes} =
            rpc:multicall(ns_node_disco:nodes_wanted(), ns_memcached,
                          active_buckets, [], ?CREATE_BUCKET_TIMEOUT),
        case FailedNodes of
            [] -> ok;
            _ ->
                ?log_warning(
                   "Best-effort check for presense of bucket failed to be made "
                   "on following nodes: ~p", [FailedNodes])
        end,

        not ns_bucket:name_conflict(
              BucketName, lists:usort(lists:append(Results))) orelse
            throw({still_exists, BucketName}),

        case ns_bucket:get_width(BucketConfig) of
            undefined ->
                bucket_placer:allow_regular_buckets() orelse
                    throw({incorrect_parameters,
                           "Cannot create regular bucket because placed buckets"
                           " are present in the cluster"});
            _ ->
                bucket_placer:can_place_bucket() orelse
                    throw({incorrect_parameters,
                           "Cannot place bucket because regular buckets"
                           " are present in the cluster"})
        end,

        PlacedBucketConfig =
            case bucket_placer:place_bucket(BucketName, BucketConfig) of
                {ok, NewConfig} ->
                    NewConfig;
                {error, BadZones} ->
                    throw({need_more_space, BadZones})
            end,
        {ok, PlacedBucketConfig}
    catch
        throw:Error ->
            {error, Error}
    end.

-ifdef(TEST).

get_uninitialized_services_test() ->
    Snapshot =
        #{nodes_wanted => {[n1, n2], rev},
          {node, n1 ,services} => {[index, kv], rev},
          {node, n2 ,services} => {[index, kv, n1ql], rev},
          {node, n1, membership} => {active, rev},
          {node, n2, membership} => {inactiveAdded, rev}},
    ?assertEqual([index, n1ql], get_uninitialized_services([kv], Snapshot)).

get_unejected_services_test() ->
    Snapshot =
        #{{node, n1 ,services} => {[index, kv], rev},
          {node, n2 ,services} => {[index, kv, n1ql], rev}},
    ?assertEqual([index, n1ql],
                 lists:sort(get_unejected_services([kv], [n2], Snapshot))),
    ?assertEqual([], get_unejected_services([kv], [], Snapshot)),
    ?assertEqual([kv], get_unejected_services(
                         [index, n1ql], [n1, n2], Snapshot)).

-endif.
