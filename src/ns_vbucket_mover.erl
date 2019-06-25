%% @author Couchbase <info@couchbase.com>
%% @copyright 2010-2019 Couchbase, Inc.
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
-module(ns_vbucket_mover).

-behavior(gen_server).

-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MAX_MOVES_PER_NODE,
        ns_config:read_key_fast(rebalance_moves_per_node, 4)).
-define(MOVES_BEFORE_COMPACTION,
        ns_config:read_key_fast(rebalance_moves_before_compaction, 64)).
-define(MAX_INFLIGHT_MOVES_PER_NODE,
        ns_config:read_key_fast(rebalance_inflight_moves_per_node, 64)).

-define(DCP_STATS_LOGGING_INTERVAL,
        ?get_param(dcp_stats_logging_interval, 10 * 60 * 1000)).

%% API
-export([start_link/5]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-export([inhibit_view_compaction/3]).
-export([note_move_done/2, note_backfill_done/2]).

-type progress_callback() :: fun((dict:dict()) -> any()).

-record(state, {bucket :: bucket_name(),
                disco_events_subscription :: pid(),
                map :: array:array(),
                moves_scheduler_state,
                progress_callback :: progress_callback(),
                all_nodes_set :: set:set()}).

%%
%% API
%%

%% @doc Start the mover.
-spec start_link(bucket_name(), [node()],
                 vbucket_map(), vbucket_map(), progress_callback()) ->
                        {ok, pid()} | {error, any()}.
start_link(Bucket, Nodes, OldMap, NewMap, ProgressCallback) ->
    gen_server:start_link(?MODULE,
                          {Bucket, Nodes, OldMap, NewMap, ProgressCallback},
                          []).

note_move_done(Pid, Worker) ->
    Pid ! {move_done, Worker}.

note_backfill_done(Pid, Worker) ->
    Pid ! {backfill_done, Worker}.

%%
%% gen_server callbacks
%%

code_change(_OldVsn, _Extra, State) ->
    {ok, State}.

assert_dict_mapping(Dict, E1, E2) ->
    case dict:find(E1, Dict) of
        error ->
            dict:store(E1, E2, Dict);
        {ok, E2} -> % note: E2 is bound
            Dict;
        {ok, _SomethingElse} ->
            erlang:throw(not_swap)
    end.

is_swap_rebalance(OldMap, NewMap) ->
    MapTriples = lists:zip3(lists:seq(0, length(OldMap) - 1),
                            OldMap,
                            NewMap),
    OldNodes = lists:usort(lists:append(OldMap)) -- [undefined],
    NewNodes = lists:usort(lists:append(NewMap)) -- [undefined],
    AddedNodes = ordsets:subtract(NewNodes, OldNodes),
    RemovedNodes = ordsets:subtract(OldNodes, NewNodes),

    try
        length(OldNodes) =/= length(NewNodes) andalso erlang:throw(not_swap),
        lists:foldl(
          fun ({_VB, OldChain, NewChain}, Dict0) ->
                  length(OldChain) =/= length(NewChain) andalso throw(not_swap),
                  Changed = [Pair || {From, To} = Pair <- lists:zip(OldChain, NewChain),
                                     From =/= To,
                                     From =/= undefined,
                                     To =/= undefined],
                  lists:foldl(
                    fun ({From, To}, Dict) ->
                            RemovedNodes =:= [] orelse ordsets:is_element(From, RemovedNodes) orelse erlang:throw(not_swap),
                            AddedNodes =:= [] orelse ordsets:is_element(To, AddedNodes) orelse erlang:throw(not_swap),
                            Dict2 = assert_dict_mapping(Dict, From, To),
                            assert_dict_mapping(Dict2, To, From)
                    end, Dict0, Changed)
          end, dict:new(), MapTriples),
        true
    catch throw:not_swap ->
            false
    end.

init({Bucket, Nodes, OldMap, NewMap, ProgressCallback}) ->
    case is_swap_rebalance(OldMap, NewMap) of
        true ->
            ale:info(?USER_LOGGER, "Bucket ~p rebalance appears to be swap rebalance", [Bucket]);
        false ->
            ale:info(?USER_LOGGER, "Bucket ~p rebalance does not seem to be swap rebalance", [Bucket])
    end,
    self() ! spawn_initial,
    process_flag(trap_exit, true),
    Self = self(),
    Subscription = ns_pubsub:subscribe_link(ns_node_disco_events,
                                            fun ({ns_node_disco_events, _, _} = Event) ->
                                                    Self ! Event;
                                                (_) ->
                                                    ok
                                            end),

    timer2:send_interval(?DCP_STATS_LOGGING_INTERVAL, log_dcp_stats),

    {ok, _} = janitor_agent:prepare_nodes_for_rebalance(Bucket, Nodes, self()),

    ets:new(compaction_inhibitions, [named_table, private, set]),
    ets:new(workers, [named_table, private, set]),

    Quirks = rebalance_quirks:get_quirks(Nodes),
    SchedulerState = vbucket_move_scheduler:prepare(
                       OldMap, NewMap, Quirks,
                       ?MAX_MOVES_PER_NODE, ?MOVES_BEFORE_COMPACTION,
                       ?MAX_INFLIGHT_MOVES_PER_NODE,
                       fun (Msg, Args) -> ?log_debug(Msg, Args) end),

    ns_rebalance_observer:submit_master_event(
      {planned_moves, Bucket, vbucket_move_scheduler:get_moves(SchedulerState)}),

    {ok, #state{bucket = Bucket,
                disco_events_subscription = Subscription,
                map = map_to_array(OldMap),
                moves_scheduler_state = SchedulerState,
                progress_callback = ProgressCallback,
                all_nodes_set = sets:from_list(Nodes)}}.


handle_call(_, _From, _State) ->
    exit(not_supported).


handle_cast(unhandled, unhandled) ->
    exit(unhandled).


handle_info(log_dcp_stats, State) ->
    rpc:eval_everywhere(diag_handler, log_all_dcp_stats, []),
    misc:flush(log_dcp_stats),
    {noreply, State};
handle_info(spawn_initial, State) ->
    report_progress(State),
    spawn_workers(State);
handle_info({inhibited_view_compaction, N, MRef}, State) ->
    true = ets:insert_new(compaction_inhibitions, {N, MRef}),
    {noreply, State};
handle_info({compaction_done, N}, #state{moves_scheduler_state = SubState} = State) ->
    A = {compact, N},
    ?log_debug("noted compaction done: ~p", [A]),
    SubState2 = vbucket_move_scheduler:note_compaction_done(SubState, A),
    spawn_workers(State#state{moves_scheduler_state = SubState2});
handle_info({move_done, Worker}, State) ->
    on_move_done(Worker, State);
handle_info({backfill_done, Worker}, State) ->
    on_backfill_done(Worker, State);
handle_info({ns_node_disco_events, OldNodes, NewNodes} = Event,
            #state{all_nodes_set = AllNodesSet} = State) ->
    WentDownNodes = sets:from_list(ordsets:subtract(OldNodes, NewNodes)),

    case sets:is_disjoint(AllNodesSet, WentDownNodes) of
        true ->
            {noreply, State};
        false ->
            {stop, {important_nodes_went_down, Event}, State}
    end;
handle_info({'EXIT', Pid, _} = Msg,
            #state{disco_events_subscription = Pid} = State) ->
    ?rebalance_error("Got exit from node disco events subscription"),
    {stop, {ns_node_disco_events_exited, Msg}, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    {ok, Action} = take_worker(Pid),
    case Reason =:= normal of
        true ->
            {noreply, State};
        false ->
            ?rebalance_error("Worker ~p (for action ~p) exited with reason ~p",
                             [Pid, Action, Reason]),
            {stop, Reason, State}
    end;
handle_info(Info, State) ->
    ?rebalance_warning("Unhandled message ~p", [Info]),
    {noreply, State}.


terminate(Reason, _State) ->
    case get_all_workers() of
        [] ->
            ok;
        Workers ->
            ?log_debug("ns_vbucket_mover terminating "
                       "when some workers are still running:~n~p", [Workers]),
            Pids = [Pid || {Pid, _} <- Workers],
            misc:terminate_and_wait(Pids, Reason)
    end.

%%
%% Internal functions
%%

%% @private
%% @doc Convert a map array back to a map list.
-spec array_to_map(array:array()) -> vbucket_map().
array_to_map(Array) ->
    array:to_list(Array).

%% @private
%% @doc Convert a map, which is normally a list, into an array so that
%% we can randomly access the replication chains.
-spec map_to_array(vbucket_map()) -> array:array().
map_to_array(Map) ->
    array:fix(array:from_list(Map)).


%% @private
%% @doc Report progress using the supplied progress callback.
-spec report_progress(#state{}) -> any().
report_progress(#state{moves_scheduler_state = SubState,
                       progress_callback = Callback}) ->
    Progress = vbucket_move_scheduler:extract_progress(SubState),
    Callback(Progress).

on_backfill_done(Worker, #state{moves_scheduler_state = SubState} = State) ->
    {ok, Move} = find_worker(Worker),
    NextState = State#state{moves_scheduler_state = vbucket_move_scheduler:note_backfill_done(SubState, Move)},
    ?log_debug("noted backfill done: ~p", [Move]),
    {noreply, _} = spawn_workers(NextState).

on_move_done(Worker, #state{bucket = Bucket,
                            map = Map,
                            moves_scheduler_state = SubState} = State) ->
    {ok, Move} = find_worker(Worker),
    {move, {VBucket, _, NewChain, _}} = Move,

    %% Pull the new chain from the target map
    %% Update the current map
    Map1 = array:set(VBucket, NewChain, Map),
    ns_bucket:set_map(Bucket, array_to_map(Map1)),
    RepSyncRV = (catch ns_config_rep:ensure_config_seen_by_nodes()),
    case RepSyncRV of
        ok -> ok;
        _ ->
            ?log_error("Config replication sync failed: ~p", [RepSyncRV])
    end,

    NextState = State#state{moves_scheduler_state = vbucket_move_scheduler:note_move_completed(SubState, Move),
                            map = Map1},

    report_progress(NextState),

    master_activity_events:note_move_done(Bucket, VBucket),

    spawn_workers(NextState).

spawn_compaction_uninhibitor(Bucket, Node, MRef) ->
    Parent = self(),
    erlang:spawn_link(
      fun () ->
              master_activity_events:note_compaction_uninhibit_started(Bucket, Node),
              case uninhibit_view_compaction(Bucket, Parent, Node, MRef) of
                  ok ->
                      master_activity_events:note_compaction_uninhibit_done(Bucket, Node),
                      ok;
                  nack ->
                      Msg = io_lib:format(
                              "failed to initiate compaction for "
                              "bucket ~p on node ~p",
                              [Bucket, Node]),
                      master_activity_events:note_rebalance_stage_event(
                        kv, Msg),
                      erlang:exit({failed_to_initiate_compaction, Bucket, Node, MRef})
              end,
              Parent ! {compaction_done, Node}
      end).

-spec uninhibit_view_compaction(bucket_name(), pid(), node(), reference()) -> ok | nack.
uninhibit_view_compaction(Bucket, Rebalancer, Node, MRef) ->
    janitor_agent:uninhibit_view_compaction(Bucket, Rebalancer, Node, MRef).

-spec inhibit_view_compaction(bucket_name(), pid(), [node()]) -> ok.
inhibit_view_compaction(Bucket, Rebalancer, Nodes) ->
    misc:parallel_map(
      fun (N) ->
              RV = janitor_agent:inhibit_view_compaction(Bucket, Rebalancer, N),
              case RV of
                  {ok, MRef} ->
                      master_activity_events:note_compaction_inhibited(Bucket,
                                                                       N),
                      Rebalancer ! {inhibited_view_compaction, N, MRef};
                  _ ->
                      ?log_debug("Got nack for inhibited_view_compaction. "
                                 "Thats normal: ~p", [{N, RV}])
              end
      end, Nodes, infinity),

    ok.

%% @doc Spawn workers up to the per-node maximum.
-spec spawn_workers(#state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
spawn_workers(#state{bucket = Bucket,
                     moves_scheduler_state = SubState,
                     all_nodes_set = AllNodesSet} = State) ->
    {Actions, NewSubState} = vbucket_move_scheduler:choose_action(SubState),
    ?log_debug("Got actions: ~p", [Actions]),
    lists:foreach(
      fun (Action) ->
              case spawn_worker(Action, State) of
                  done ->
                      ok;
                  {ok, Worker} ->
                      store_worker(Worker, Action)
              end
      end, Actions),

    NextState = State#state{moves_scheduler_state = NewSubState},
    Done = Actions =:= [] andalso begin
                                      true = (NewSubState =:= SubState),
                                      vbucket_move_scheduler:is_done(NewSubState)
                                  end,
    case Done of
        true ->
            janitor_agent:finish_rebalance(Bucket, sets:to_list(AllNodesSet), self()),
            {stop, normal, NextState};
        _ ->
            {noreply, NextState}
    end.

spawn_worker({move, {VBucket, OldChain, NewChain, Quirks}},
             #state{bucket = Bucket}) ->
    Pid = ns_single_vbucket_mover:spawn_mover(Bucket, VBucket,
                                              OldChain, NewChain, Quirks),
    {ok, Pid};
spawn_worker({compact, Node}, #state{bucket = Bucket}) ->
    case ets:take(compaction_inhibitions, Node) of
        [] ->
            self() ! {compaction_done, Node},
            done;
        [{Node, MRef}] ->
            Pid = spawn_compaction_uninhibitor(Bucket, Node, MRef),
            {ok, Pid}
    end.

store_worker(Pid, Action) ->
    true = ets:insert_new(workers, {Pid, Action}).

find_worker(Pid) ->
    case ets:lookup(workers, Pid) of
        [{_, Action}] ->
            {ok, Action};
        [] ->
            not_found
    end.

take_worker(Pid) ->
    R = find_worker(Pid),
    ets:delete(workers, Pid),
    R.

get_all_workers() ->
    ets:tab2list(workers).

-ifdef(TEST).
is_swap_rebalance_test() ->
    ?assertEqual(true,  is_swap_rebalance([], [])),
    ?assertEqual(true,  is_swap_rebalance([[1]], [[2]])),
    ?assertEqual(true,  is_swap_rebalance([[1]], [[1]])),
    ?assertEqual(true,  is_swap_rebalance([[1], [1]], [[2], [2]])),
    ?assertEqual(true,  is_swap_rebalance([[1,2], [2,3]], [[1,4], [4,3]])),
    ?assertEqual(false, is_swap_rebalance([[1,2], [2,3]], [[4,1], [4,3]])),
    ?assertEqual(true,  is_swap_rebalance([[1,2,3], [2,3,4], [3,4,1]],
                                          [[1,5,3], [5,3,4], [3,4,1]])),
    ?assertEqual(false, is_swap_rebalance([[1,2,3], [2,3,4], [3,4,1]],
                                          [[1,5,3], [4,3,5], [3,4,1]])),
    ?assertEqual(true,  is_swap_rebalance([[1,2,undefined], [2,3,undefined]],
                                          [[1,5,undefined], [5,3,undefined]])),
    ?assertEqual(false, is_swap_rebalance([[1,2,undefined], [2,3,undefined]],
                                          [[1,5,undefined], [3,5,undefined]])),
    ?assertEqual(false, is_swap_rebalance([[1,undefined], [1,undefined]],
                                          [[1,2], [1,2]])),
    ?assertEqual(false, is_swap_rebalance([[1,2], [1,2]],
                                          [[1,undefined], [1,undefined]])),
    ?assertEqual(false, is_swap_rebalance([[1,2,3], [2,3,1], [3,1,2]],
                                          [[1,5,undefined],[5,1,undefined],
                                           [1,5,undefined]])),
    ok.
-endif.
