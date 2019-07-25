%% @author Couchbase, Inc <info@couchbase.com>
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

-module(ns_rebalance_observer).

-behavior(gen_server).

-include("ns_common.hrl").
-include("cut.hrl").

-export([start_link/4,
         get_detailed_progress/0,
         get_aggregated_progress/1,
         get_rebalance_info/0,
         record_rebalance_report/1,
         update_progress/2,
         submit_master_event/1]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-define(SERVER, {via, leader_registry, ?MODULE}).
-define(DOCS_LEFT_REFRESH_INTERVAL, 5000).

-record(stat_info, {start_time = false,
                    end_time = false}).

-record(replica_building_stats, {node :: node(),
                                 docs_total :: non_neg_integer(),
                                 docs_left :: non_neg_integer()}).

-record(vbucket_info, {before_chain :: [node()],
                       after_chain :: [node()],
                       stats :: [#replica_building_stats{}],
                       move = #stat_info{},
                       backfill = #stat_info{},
                       takeover = #stat_info{},
                       persistence = #stat_info{}}).

-record(total_stat_info, {total_time = 0,
                          completed_count = 0}).

-record(vbucket_level_info, {move = #total_stat_info{},
                             backfill = #total_stat_info{},
                             takeover = #total_stat_info{},
                             persistence = #total_stat_info{},
                             vbucket_info = dict:new()}).

-record(compaction_info, {per_node = [] :: [{node(), #total_stat_info{}}],
                          in_progress = [] :: [{node(), #stat_info{}}]}).

-record(bucket_level_info, {bucket_name,
                            storage_mode,
                            compaction_info = #compaction_info{},
                            vbucket_level_info = #vbucket_level_info{}}).

-record(state, {bucket :: bucket_name() | undefined,
                buckets_count :: pos_integer(),
                bucket_number :: non_neg_integer(),
                stage_info :: rebalance_stage_info:stage_info(),
                nodes_info :: [{atom(), [node()]}],
                type :: atom(),
                rebalance_id :: binary(),
                bucket_info :: dict:dict()}).

start_link(Stages, NodesInfo, Type, Id) ->
    gen_server:start_link(?SERVER, ?MODULE, {Stages, NodesInfo, Type, Id}, []).

is_timeout(exit, timeout) ->
    true;
is_timeout(exit, {timeout, _}) ->
    true;
is_timeout(_, _) ->
    false.

generic_get_call(Call) ->
    generic_get_call(Call, 10000).
generic_get_call(Call, Timeout) ->
    try
        gen_server:call(?SERVER, Call, Timeout)
    catch
        Type:Reason ->
            case is_timeout(Type, Reason) of
                true ->
                    ?log_info("Request ~p timed out after ~p secs",
                              [Call, Timeout/1000]),
                    {error, timeout};
                false ->
                    ?log_error("Unexpected exception ~p", [{Type, Reason}]),
                    not_running
            end
    end.

get_detailed_progress() ->
    generic_get_call(get_detailed_progress).

get_aggregated_progress(Timeout) ->
    generic_get_call(get_aggregated_progress, Timeout).

get_rebalance_info() ->
    generic_get_call({get_rebalance_info, []}).

record_rebalance_report(Args) ->
    generic_get_call({record_rebalance_report, Args}).

update_progress(Stage, StageProgress) ->
    gen_server:cast(?SERVER, {update_progress, Stage, StageProgress}).

get_registered_local_name() ->
    ?MODULE.

submit_master_event(Event) ->
    gen_server:cast(get_registered_local_name(), {note, Event}).

get_stage_nodes(Services, NodesInfo) ->
    ActiveNodes = proplists:get_value(active_nodes, NodesInfo, []),
    lists:filtermap(
      fun (Service) ->
              case ns_cluster_membership:service_nodes(ActiveNodes, Service) of
                  [] ->
                      false;
                  Nodes ->
                      {true, {Service, Nodes}}
              end
      end, lists:usort(Services)).

init({Services, NodesInfo, Type, Id}) ->
    Self = self(),
    StageInfo = rebalance_stage_info:init(get_stage_nodes(Services, NodesInfo)),
    Buckets = ns_bucket:get_buckets(),
    BucketsCount = length(Buckets),
    BucketLevelInfo = dict:from_list(
                        [{BN,
                          #bucket_level_info{
                             bucket_name = BN,
                             storage_mode = ns_bucket:storage_mode(Config)}}
                         || {BN, Config} <- Buckets]),
    proc_lib:spawn_link(erlang, apply, [fun docs_left_updater_init/1, [Self]]),
    erlang:register(get_registered_local_name(), self()),

    {ok, #state{bucket = undefined,
                buckets_count = BucketsCount,
                bucket_number = 0,
                stage_info = StageInfo,
                nodes_info = NodesInfo,
                type = Type,
                rebalance_id = Id,
                bucket_info = BucketLevelInfo}}.

handle_call(get, _From, State) ->
    {reply, State, State};
handle_call(get_detailed_progress, _From, State) ->
    {reply, do_get_detailed_progress(State), State};
handle_call(get_aggregated_progress, _From,
            #state{stage_info = StageInfo} = State) ->
    {reply, {ok, dict:to_list(rebalance_stage_info:get_progress(StageInfo))},
     State};
handle_call({get_rebalance_info, Options}, _From,
            #state{stage_info = StageInfo,
                   nodes_info = NodesInfo,
                   rebalance_id = Id} = State) ->
    StageDetails = get_all_stage_rebalance_details(State, Options),
    RebalanceInfo = [{stageInfo, rebalance_stage_info:get_stage_info(
                                   StageInfo, StageDetails)},
                     {rebalanceId, Id},
                     {nodesInfo, {NodesInfo}},
                     {masterNode, atom_to_binary(node(), latin1)}],
    {reply, {ok, RebalanceInfo}, State};
handle_call({record_rebalance_report, ExitInfo}, From,
            #state{nodes_info = NodesInfo} = State) ->
    {_, {ok, RebalanceInfo}, NewState} = handle_call(
                                           {get_rebalance_info,
                                            [{add_vbucket_info, true}]},
                                           From,
                                           State),
    Report = {RebalanceInfo ++ ExitInfo},
    KeepNodes = proplists:get_value(keep_nodes, NodesInfo, [node()]),
    RV = case ns_rebalance_report_manager:record_rebalance_report(
                ejson:encode(Report), KeepNodes) of
             ok ->
                 ok;
             Err ->
                 ?log_info("Unable to record report ~p, Error ~p",
                           [Report, Err]),
                 Err
         end,
    {reply, RV, NewState};
handle_call(Req, From, State) ->
    ?log_error("Got unknown request: ~p from ~p", [Req, From]),
    {reply, unknown_request, State}.

handle_cast({note, Event}, State) ->
    {noreply, handle_master_event(Event, State)};

handle_cast({update_stats, BucketName, VBucket, NodeToDocsLeft}, State) ->
    ?log_debug("Got update_stats: ~p, ~p", [VBucket, NodeToDocsLeft]),
    {noreply, update_move(
                State, BucketName, VBucket,
                fun (Move) ->
                        NewStats =
                            [case lists:keyfind(Stat#replica_building_stats.node, 1, NodeToDocsLeft) of
                                 {_, NewLeft} ->
                                     #replica_building_stats{docs_total = Total,
                                                             docs_left = Left} = Stat,

                                     case NewLeft >= Left of
                                         true ->
                                             %% our initial estimates are
                                             %% imprecise, so we can end up in
                                             %% a situation where new
                                             %% docs_left is greater than
                                             %% docs_total;
                                             %%
                                             %% another possibility is that
                                             %% there're new mutations coming;
                                             %% in such case if we didn't
                                             %% adjust docs_total it would
                                             %% seem to the user that number
                                             %% of transfered items went down
                                             %% which is probably not desireable;
                                             %%
                                             %% obviously, this adjustment may
                                             %% lose some mutations (meaning
                                             %% that final doc_total wouldn't
                                             %% be precise) but user
                                             %% experience-wise it seems to be
                                             %% better.
                                             Increase = NewLeft - Left,
                                             Stat#replica_building_stats{docs_left = NewLeft,
                                                                         docs_total = Total + Increase};
                                         false ->
                                             Stat#replica_building_stats{docs_left = NewLeft}
                                     end;
                                 false ->
                                     Stat
                             end || Stat <- Move#vbucket_info.stats],
                        Move#vbucket_info{stats = NewStats}
                end)};

handle_cast({update_progress, Stage, StageProgress},
            #state{stage_info = Old} = State) ->
    NewStageInfo = rebalance_stage_info:update_progress(
                     Stage, StageProgress, Old),
    {noreply, State#state{stage_info = NewStageInfo}};

handle_cast(Req, _State) ->
    ?log_error("Got unknown cast: ~p", [Req]),
    erlang:error({unknown_cast, Req}).

initiate_bucket_rebalance(BucketName, _, OldState) when OldState#state.bucket =:= BucketName ->
    OldState;
initiate_bucket_rebalance(BucketName, {Moves, UndefinedMoves}, OldState) ->
    BuildDestinations0 = [{MasterNode, VB}
                          || {VB, [MasterNode|_], _ChainAfter, _} <- Moves],
    BuildDestinations1 = [{N, VB} || {VB, [MasterNode|_], ChainAfter, _} <- Moves,
                                     N <- ChainAfter, N =/= undefined, N =/= MasterNode],

    BuildDestinations =
        %% the following groups vbuckets to per node. [{a, 1}, {a, 2}, {b, 3}] => [{a, [1,2]}, {b, [3]}]
        keygroup_sorted(lists:merge(lists:sort(BuildDestinations0),
                                    lists:sort(BuildDestinations1))),

    SomeEstimates0 = misc:parallel_map(
                       fun ({Node, VBs}) ->
                               {ok, DcpEstimates} =
                                   janitor_agent:get_mass_dcp_docs_estimate(BucketName, Node, VBs),

                               [{{Node, VB}, {VBEstimate, VBChkItems}} ||
                                   {VB, {VBEstimate, VBChkItems, _}} <-
                                       lists:zip(VBs, DcpEstimates)]
                       end, BuildDestinations, infinity),


    SomeEstimates = lists:append(SomeEstimates0),

    ?log_debug("Initial estimates:~n~p", [SomeEstimates]),

    BuiltMoves =
        [begin
             {_, {MasterEstimate, MasterChkItems}} = lists:keyfind({MasterNode, VB}, 1, SomeEstimates),
             RBStats =
                 [begin
                      {_, {ReplicaEstimate, _}} = lists:keyfind({Replica, VB}, 1, SomeEstimates),
                      Estimate = case ReplicaEstimate =< MasterEstimate of
                                     true ->
                                         %% in this case we assume no backfill
                                         %% is required; but the number of
                                         %% items to be transferred can't be
                                         %% less than the number of items in
                                         %% open checkpoint
                                         max(MasterChkItems,
                                             MasterEstimate - ReplicaEstimate);
                                     _ ->
                                         MasterEstimate
                                 end,
                      #replica_building_stats{node = Replica,
                                              docs_total = Estimate,
                                              docs_left = Estimate}
                  end || Replica <- ChainAfter,
                         Replica =/= undefined,
                         Replica =/= MasterNode],
             {VB, #vbucket_info{before_chain = ChainBefore,
                                after_chain = ChainAfter,
                                stats = RBStats}}
         end || {VB, [MasterNode|_] = ChainBefore, ChainAfter, _} <- Moves],

    BuiltUndefinedMoves = [{VB, #vbucket_info{before_chain = ChainBefore,
                                              after_chain = ChainAfter,
                                              stats = []}}
                           || {VB, ChainBefore, ChainAfter, _} <- UndefinedMoves],

    AllMoves = BuiltMoves ++ BuiltUndefinedMoves,
    ?log_debug("Moves:~n~p", [AllMoves]),
    TmpState = update_all_vb_info(OldState, BucketName, dict:from_list(AllMoves)),
    TmpState#state{bucket = BucketName}.

handle_master_event({rebalance_stage_started, Stage, Nodes}, State) ->
    update_stage(Stage, {started, Nodes}, State);

handle_master_event({rebalance_stage_completed, Stage}, State) ->
    update_stage(Stage, completed, State);

handle_master_event({rebalance_stage_event, Stage, Text}, State) ->
    update_stage(Stage, {notable_event, Text}, State);

handle_master_event({bucket_rebalance_started, _BucketName, _Pid},
                    #state{bucket_number = Number} = State) ->
    State#state{bucket_number = Number + 1};

handle_master_event({planned_moves, BucketName, MovesTuple}, State) ->
    initiate_bucket_rebalance(BucketName, MovesTuple, State);

handle_master_event({vbucket_move_start, _Pid, BucketName,
                     _Node, VBucketId, _, _}, State) ->
    ?log_debug("Noted vbucket move start (vbucket ~p)", [VBucketId]),
    update_info(vbucket_move_start, State, {os:timestamp(), BucketName,
                                            VBucketId});

handle_master_event({vbucket_move_done, BucketName, VBucket}, State) ->
    State1 = update_move(
               State, BucketName, VBucket,
               fun (#vbucket_info{stats=Stats} = Move) ->
                       Stats1 = [S#replica_building_stats{docs_left=0} ||
                                    S <- Stats],
                       Move#vbucket_info{stats=Stats1}
               end),
    ?log_debug("Noted vbucket move end (vbucket ~p)", [VBucket]),
    update_info(vbucket_move_done, State1,
                {os:timestamp(), BucketName, VBucket});

handle_master_event({Event, BucketName, Node}, State)
  when Event =:= compaction_uninhibit_started;
       Event =:= compaction_uninhibit_done ->
    update_info(Event, State, {os:timestamp(), BucketName, Node});

handle_master_event({Event, BucketName, VBucket, _, _}, State)
  when Event =:= takeover_started;
       Event =:= takeover_ended;
       Event =:= seqno_waiting_started;
       Event =:= seqno_waiting_ended ->
    update_info(Event, State, {os:timestamp(), BucketName, VBucket});

handle_master_event({Event, BucketName, VBucket}, State)
  when Event =:= backfill_phase_started;
       Event =:= backfill_phase_ended ->
    update_info(Event, State, {os:timestamp(), BucketName, VBucket});

handle_master_event(_, State) ->
    State.

update_stage(Stage, Info, #state{stage_info = Old} = State) ->
    State#state{stage_info =
                    rebalance_stage_info:update_stage_info(
                      Stage, Info, os:timestamp(), Old)}.

update_move(State, BucketName, VBucket, Fun) ->
    update_all_vb_info(State, BucketName,
                       dict:update(VBucket, Fun,
                                   get_all_vb_info(State, BucketName))).

handle_info(Msg, State) ->
    ?log_error("Got unexpected message: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

docs_left_updater_init(Parent) ->
    {ok, _} = timer2:send_interval(?DOCS_LEFT_REFRESH_INTERVAL, refresh),
    docs_left_updater_loop(Parent).

docs_left_updater_loop(Parent) ->
    State = gen_server:call(Parent, get, infinity),
    BucketName = State#state.bucket,
    Moves = dict:to_list(get_all_vb_info(State, BucketName)),
    case BucketName of
        undefined ->
            ok;
        _ ->
            ?log_debug("Starting docs_left_updater_loop:~p~n~p",
                       [BucketName, Moves])
    end,
    [update_docs_left_for_move(Parent, BucketName, VB, VBInfo)
     || {VB, VBInfo} <- Moves,
        hd(VBInfo#vbucket_info.before_chain) =/= undefined,
        VBInfo#vbucket_info.move#stat_info.start_time =/= false,
        VBInfo#vbucket_info.move#stat_info.end_time =:= false],
    receive
        refresh ->
            _Lost = misc:flush(refresh),
            docs_left_updater_loop(Parent)
    end.

get_docs_estimate(BucketName, VBucket, #vbucket_info{before_chain = [MasterNode|_],
                                                     stats = RStats}) ->
    ReplicaNodes = [S#replica_building_stats.node || S <- RStats],
    janitor_agent:get_dcp_docs_estimate(BucketName, MasterNode, VBucket, ReplicaNodes).

update_docs_left_for_move(Parent, BucketName, VBucket,
                          #vbucket_info{stats = RStats} = MoveState) ->
    try get_docs_estimate(BucketName, VBucket, MoveState) of
        NewLefts ->
            Stuff =
                lists:flatmap(
                  fun ({OkE, Stat}) ->
                          {ok, {E, _, Status}} = OkE,

                          %% we expect vbucket to still be replicated; if it
                          %% is not the case, we will get bad estimate
                          case Status =:= <<"backfilling">> orelse
                              Status =:= <<"backfill completed">> of
                              true ->
                                  [{Stat#replica_building_stats.node, E}];
                              false ->
                                  []
                          end
                  end, lists:zip(NewLefts, RStats)),

            case Stuff of
                [] ->
                    ok;
                _ ->
                    gen_server:cast(Parent,
                                    {update_stats, BucketName, VBucket, Stuff})
            end
    catch
        error:{janitor_agent_servant_died, _} ->
            ?log_debug("Apparently move of ~p is already done", [VBucket]),
            ok;
        T:E ->
            %% Ignore exceptions from get_docs_estimate, we expect rebalance to
            %% fail on continued exception.
            ?log_debug("Exception in get_docs_estimate ~p", [{T, E}]),
            ok
    end.

keygroup_sorted(Items) ->
    lists:foldr(
      fun ({K, V}, Acc) ->
              case Acc of
                  [{K, AccVs} | Rest] ->
                      [{K, [V | AccVs]} | Rest];
                  _ ->
                      [{K, [V]} | Acc]
              end
      end, [], Items).


do_get_detailed_progress(#state{bucket = undefined}) ->
    not_running;
do_get_detailed_progress(#state{bucket = Bucket,
                                buckets_count = BucketsCount,
                                bucket_number = BucketNumber} = State) ->
    AllMoves = get_all_vb_info(State, Bucket),
    {CurrentMoves, PendingMoves} =
        dict:fold(
          fun (_, #vbucket_info{move = MoveStat} = VBInfo, {CM, PM}) ->
                  case {MoveStat#stat_info.start_time,
                        MoveStat#stat_info.end_time} of
                      {false, _} ->
                          {CM, [VBInfo | PM]};
                      {_, false} ->
                          {[VBInfo | CM], PM};
                      {_, _} ->
                          {CM, PM}
                  end
          end, {[], []}, AllMoves),

    {OutMovesStats, InMovesStats} = moves_stats(AllMoves),

    Inc = fun (undefined, Dict) ->
                  Dict;
              (Node, Dict) ->
                  dict:update(Node,
                              fun (C) ->
                                      C + 1
                              end, 1, Dict)
          end,

    {MovesInActive, MovesOutActive, MovesInReplica, MovesOutReplica} =
        lists:foldl(
          fun (#vbucket_info{before_chain=[OldMaster|OldReplicas],
                             after_chain=[NewMaster|NewReplicas]},
               {AccInA, AccOutA, AccInR, AccOutR}) ->
                  {AccInA1, AccOutA1} =
                      case OldMaster =:= NewMaster of
                          true ->
                              {AccInA, AccOutA};
                          false ->
                              {Inc(NewMaster, AccInA), Inc(OldMaster, AccOutA)}
                      end,

                  AccInR1 =
                      lists:foldl(
                        fun (N, Acc) ->
                                Inc(N, Acc)
                        end, AccInR, NewReplicas -- OldReplicas),

                  AccOutR1 =
                      lists:foldl(
                        fun (N, Acc) ->
                                Inc(N, Acc)
                        end, AccOutR, OldReplicas -- NewReplicas),

                  {AccInA1, AccOutA1, AccInR1, AccOutR1}
          end, {dict:new(), dict:new(), dict:new(), dict:new()},
          CurrentMoves ++ PendingMoves),

    NodesProgress =
        lists:foldl(
          fun (N, Acc) ->
                  {InTotal, InLeft} = misc:dict_get(N, InMovesStats, {0, 0}),
                  {OutTotal, OutLeft} = misc:dict_get(N, OutMovesStats, {0, 0}),

                  InA = misc:dict_get(N, MovesInActive, 0),
                  OutA = misc:dict_get(N, MovesOutActive, 0),
                  InR = misc:dict_get(N, MovesInReplica, 0),
                  OutR = misc:dict_get(N, MovesOutReplica, 0),

                  Ingoing = [{docsTotal, InTotal},
                             {docsTransferred, InTotal - InLeft},
                             {activeVBucketsLeft, InA},
                             {replicaVBucketsLeft, InR}],

                  Outgoing = [{docsTotal, OutTotal},
                              {docsTransferred, OutTotal - OutLeft},
                              {activeVBucketsLeft, OutA},
                              {replicaVBucketsLeft, OutR}],

                  Info = {N, Ingoing, Outgoing},
                  [Info | Acc]
          end, [], ns_node_disco:nodes_wanted()),

    GlobalDetails = [{bucket, list_to_binary(Bucket)},
                     {bucketNumber, BucketNumber},
                     {bucketsCount, BucketsCount}],
    {ok, GlobalDetails, NodesProgress}.


moves_stats(Moves) ->
    dict:fold(
      fun (_, #vbucket_info{stats=Stats,
                            before_chain=[OldMaster|_]}, Acc) ->
              true = (OldMaster =/= undefined orelse Stats =:= []),

              lists:foldl(
                fun (#replica_building_stats{node=DstNode,
                                             docs_total=Total,
                                             docs_left=Left},
                     {AccOut, AccIn}) ->
                        true = (Left =< Total),

                        AccOut1 = dict:update(OldMaster,
                                              fun ({AccTotal, AccLeft}) ->
                                                      {AccTotal + Total, AccLeft + Left}
                                              end, {Total, Left}, AccOut),
                        AccIn1 = dict:update(DstNode,
                                             fun ({AccTotal, AccLeft}) ->
                                                     {AccTotal + Total, AccLeft + Left}
                                             end, {Total, Left}, AccIn),

                        {AccOut1, AccIn1}
                end, Acc, Stats)
      end, {dict:new(), dict:new()}, Moves).

ignore_event_for_bucket(Event,
                        #bucket_level_info{storage_mode = StorageMode}) ->
    (StorageMode =:= undefined orelse StorageMode =:= ephemeral) andalso
        (Event =:= compaction_uninhibit_started orelse
         Event =:= compaction_uninhibit_done orelse
         Event =:= seqno_waiting_started orelse
         Event =:= seqno_waiting_ended).

update_info(Event,
            #state{bucket_info = OldBucketLevelInfo} = State,
            {_TS, BucketName, _VB} = UpdateArgs) ->
    NewBucketLevelInfo =
        dict:update(
          BucketName,
          fun (BLI0) ->
                  case ignore_event_for_bucket(Event, BLI0) of
                      false ->
                          BLI1 = update_bucket_level_info(Event, BLI0,
                                                          UpdateArgs),
                          update_vbucket_level_info(Event, BLI1, UpdateArgs);
                      true ->
                          BLI0
                  end
          end, OldBucketLevelInfo),
    State#state{bucket_info = NewBucketLevelInfo}.

update_bucket_level_info(compaction_uninhibit_started,
                         BucketLevelInfo,
                         {TS, _Bucket, Node}) ->
    Compaction = BucketLevelInfo#bucket_level_info.compaction_info,
    InProgress = Compaction#compaction_info.in_progress,
    case lists:keyfind(Node, 1, InProgress) of
        false ->
            NewInprogress = [{Node, #stat_info{start_time = TS}} | InProgress],
            NewCompaction = Compaction#compaction_info{
                              in_progress = NewInprogress},
            BucketLevelInfo#bucket_level_info{compaction_info = NewCompaction};
        _ ->
            BucketLevelInfo
    end;
update_bucket_level_info(compaction_uninhibit_done,
                         BucketLevelInfo,
                         {TS, _Bucket, Node}) ->
    Compaction = BucketLevelInfo#bucket_level_info.compaction_info,
    InProgress = Compaction#compaction_info.in_progress,
    case lists:keytake(Node, 1, InProgress) of
        false ->
            BucketLevelInfo;
        {value, {Node, CompactionStat}, NewInprogress} ->
            BucketLevelInfo#bucket_level_info{
              compaction_info = update_on_compaction_end(
                                  Compaction, Node,
                                  CompactionStat#stat_info{end_time = TS},
                                  NewInprogress)}
    end;
update_bucket_level_info(_, BLI, _) ->
    BLI.

update_on_compaction_end(#compaction_info{per_node = OldPerNode},
                         Node,
                         NewCompactionStat,
                         NewInprogress) ->
    NewPerNode = case lists:keytake(Node, 1, OldPerNode) of
                     {value, {Node, TotalStat}, PerNode} ->
                         NewTotalStat = update_total_stat(TotalStat,
                                                          NewCompactionStat),
                         [{Node, NewTotalStat} | PerNode];
                    false ->
                         NewTotalStat = update_total_stat(#total_stat_info{},
                                                          NewCompactionStat),
                         [{Node, NewTotalStat} | OldPerNode]
                 end,
    #compaction_info{per_node = NewPerNode,
                     in_progress = NewInprogress}.

get_all_vb_info(_, undefined) ->
    dict:new();
get_all_vb_info(#state{bucket_info = BucketInfo}, BucketName) ->
    {ok, BucketLevelInfo} = dict:find(BucketName, BucketInfo),
    get_all_vb_info(BucketLevelInfo).

get_all_vb_info(BucketLevelInfo) ->
    BucketLevelInfo#bucket_level_info.vbucket_level_info#vbucket_level_info.vbucket_info.

update_all_vb_info(#state{bucket_info = OldBucketLevelInfo} = State, BucketName,
                   NewAllVBInfo) ->
    NewBucketLevelInfo = dict:update(BucketName,
                                     ?cut(update_all_vb_info(_, NewAllVBInfo)),
                                     OldBucketLevelInfo),
    State#state{bucket_info = NewBucketLevelInfo}.

update_all_vb_info(#bucket_level_info{
                      vbucket_level_info = VBLevelInfo} = BucketLevelInfo,
                   AllVBInfo) ->
    NewVBLevelInfo = VBLevelInfo#vbucket_level_info{vbucket_info = AllVBInfo},
    BucketLevelInfo#bucket_level_info{vbucket_level_info = NewVBLevelInfo}.

update_vbucket_level_info(Event, BucketLevelInfo,
                          {_TS, _BucketName, VB} = UpdateArgs) ->
    AllVBInfo = get_all_vb_info(BucketLevelInfo),
    case dict:find(VB, AllVBInfo) of
        {ok, VBInfo} ->
            NewVBInfo = update_vbucket_info(Event, VBInfo, UpdateArgs),
            BLI = update_vbucket_level_info_inner(Event, BucketLevelInfo, NewVBInfo),
            update_all_vb_info(BLI, dict:store(VB, NewVBInfo, AllVBInfo));
        _ ->
            BucketLevelInfo
    end.

find_event_action(Event) ->
    %% {Event, TotalElement, StatElement, stat_op}
    EventAction = [
                   {vbucket_move_start, undefined,
                    #vbucket_info.move, start_time},
                   {vbucket_move_done, #vbucket_level_info.move,
                    #vbucket_info.move, end_time},

                   {backfill_phase_started, undefined,
                    #vbucket_info.backfill, start_time},
                   {backfill_phase_ended, #vbucket_level_info.backfill,
                    #vbucket_info.backfill, end_time},

                   {takeover_started, undefined,
                    #vbucket_info.takeover, start_time},
                   {takeover_ended, #vbucket_level_info.takeover,
                    #vbucket_info.takeover, end_time},

                   {seqno_waiting_started, undefined,
                    #vbucket_info.persistence, start_time},
                   {seqno_waiting_ended, #vbucket_level_info.persistence,
                    #vbucket_info.persistence, end_time}
                  ],
    lists:keyfind(Event, 1, EventAction).

update_stat(start_time, _, TS) ->
    #stat_info{start_time = TS};
update_stat(end_time, Stat, TS) ->
    Stat#stat_info{end_time = TS}.

update_vbucket_info(Event, VBInfo, {TS, _Bucket, _VB}) ->
    case find_event_action(Event) of
        false ->
            VBInfo;
        {Event, _TotalElement, StatElement, StatOp} ->
            misc:update_field(StatElement, VBInfo,
                              ?cut(update_stat(StatOp, _, TS)))
    end.

update_total_stat(TotalStat, #stat_info{end_time = false}) ->
    TotalStat;
update_total_stat(#total_stat_info{total_time = TT, completed_count = C},
                  #stat_info{start_time = ST, end_time = ET}) ->
    NewTime = rebalance_stage_info:diff_timestamp(ET, ST),
    #total_stat_info{total_time = TT + NewTime,
                     completed_count = C + 1}.

update_vbucket_level_info_inner(
  Event,
  #bucket_level_info{vbucket_level_info = VBLevelInfo} = BucketLevelInfo,
  NewVBInfo) ->
    case find_event_action(Event) of
        false ->
            BucketLevelInfo;
        {_, undefined, _, _} ->
            BucketLevelInfo;
        {Event, TotalElement, StatElement, _StatOp} ->
            Stat = erlang:element(StatElement, NewVBInfo),
            TotalInfo = erlang:element(TotalElement, VBLevelInfo),
            NewTotalInfo = update_total_stat(TotalInfo, Stat),
            NewVBLevelInfo = erlang:setelement(TotalElement, VBLevelInfo,
                                               NewTotalInfo),
            BucketLevelInfo#bucket_level_info{
              vbucket_level_info = NewVBLevelInfo}
    end.

construct_bucket_level_info_json(
  #bucket_level_info{bucket_name = BucketName,
                     compaction_info = CompactionInfo,
                     vbucket_level_info = VBLevelInfo}, Options) ->
    case construct_compaction_info_json(CompactionInfo) ++
         construct_vbucket_level_info_json(VBLevelInfo, Options) of
        [] -> [];
        BLI -> [{BucketName, {BLI}}]
    end.

construct_compaction_info_json(#compaction_info{per_node = PerNode,
                                                in_progress = InProgress}) ->
    InProgressElem = {inProgress,
                      {[{Node, construct_stat_info_json(StatInfo)} ||
                        {Node, StatInfo} <- InProgress]}},
    PerNodeElem = {perNode,
                   {[{Node, construct_total_stat_info_json(TotalStatInfo)} ||
                   {Node, TotalStatInfo} <- PerNode]}},
    case {PerNode, InProgress} of
        {[], []} -> [];
        {[], _} -> [{compactionInfo, {[InProgressElem]}}];
        {_, []} -> [{compactionInfo, {[PerNodeElem]}}];
        _ -> [{compactionInfo, {[InProgressElem, PerNodeElem]}}]
    end.

construct_stat_info_json(#stat_info{start_time = false}) ->
    {[{startTime, rebalance_stage_info:binarify_timestamp(false)}]};
construct_stat_info_json(#stat_info{start_time = ST,
                                    end_time = ET}) ->
    {[{startTime, rebalance_stage_info:binarify_timestamp(ST)},
      {completedTime, rebalance_stage_info:binarify_timestamp(ET)},
      {timeTaken, rebalance_stage_info:diff_timestamp(ET, ST)}]}.

average(_, 0) ->
    0;
average(Total, Count) ->
    Total/Count.

construct_total_stat_info_json(TotalStatInfo) ->
    construct_total_stat_info_json(TotalStatInfo, undefined).

construct_total_stat_info_json(#total_stat_info{total_time = TT,
                                                completed_count = CC},
                               TotalCount) ->
    CountJson = case TotalCount of
                    undefined ->
                        [];
                    _ ->
                        [{totalCount, TotalCount},
                         {remainingCount, TotalCount - CC}]
                end,
    {[{averageTime, average(TT, CC)}] ++ CountJson}.

construct_replica_building_stats_json(#replica_building_stats{node = Node,
                                                              docs_total = DT,
                                                              docs_left = DL}) ->
    {Node, {[{node, Node},
             {docsTotal, DT},
             {docsLeft, DL}]}}.

construct_vbucket_info_json(Id, #vbucket_info{before_chain = BC,
                                              after_chain = AC,
                                              stats = RBS,
                                              move = Move,
                                              backfill = Backfill,
                                              takeover = Takeover,
                                              persistence = Persistence}) ->
    StatsJson = case RBS of
                    [] ->
                        [];
                    _ ->
                        [{stats, {[construct_replica_building_stats_json(X)
                                   || X <- RBS]}}]
                end,
    {[{id, Id},
      {beforeChain, BC},
      {afterChain, AC},
      {move, construct_stat_info_json(Move)},
      {backfill, construct_stat_info_json(Backfill)},
      {takeover, construct_stat_info_json(Takeover)},
      {persistence, construct_stat_info_json(Persistence)}] ++ StatsJson}.

construct_vbucket_level_info_json(VBLevelInfo, Options) ->
    case dict:is_empty(VBLevelInfo#vbucket_level_info.vbucket_info) of
        true ->
            [];
        false ->
            [{vbucketLevelInfo,
              construct_vbucket_level_info_json_inner(VBLevelInfo, Options)}]
    end.

construct_vbucket_level_info_json_inner(
  #vbucket_level_info{move = Move,
                      backfill = Backfill,
                      takeover = Takeover,
                      persistence = Persistence,
                      vbucket_info = AllVBInfo}, Options) ->
    VBI = case proplists:get_bool(add_vbucket_info, Options) of
              true ->
                  [{vbucketInfo,
                    dict:fold(fun (VB, Info, Acc) ->
                                      [construct_vbucket_info_json(VB, Info) | Acc]
                              end, [], AllVBInfo)}];
              _ ->
                  []
          end,
    {[{move, construct_total_stat_info_json(Move, dict:size(AllVBInfo))},
      {backfill, construct_total_stat_info_json(Backfill)},
      {takeover, construct_total_stat_info_json(Takeover)},
      {persistence, construct_total_stat_info_json(Persistence)}]
     ++ VBI}.

get_all_stage_rebalance_details(#state{bucket_info = BucketLevelInfo},
                                Options) ->
    RV = dict:fold(
           fun (_Key, BLI, Acc) ->
                   construct_bucket_level_info_json(BLI, Options) ++ Acc
           end, [], BucketLevelInfo),
    case RV of
        [] -> [];
        _ -> [{kv, {RV}}]
    end.
