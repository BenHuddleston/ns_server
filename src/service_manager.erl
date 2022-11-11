%% @author Couchbase <info@couchbase.com>
%% @copyright 2016-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(service_manager).

-include("cut.hrl").
-include("ns_common.hrl").

-export([with_trap_exit_spawn_monitor_rebalance/6,
         with_trap_exit_spawn_monitor_failover/3,
         with_trap_exit_spawn_monitor_pause_bucket/6,
         with_trap_exit_spawn_monitor_resume_bucket/7]).

-record(rebalance_args, {keep_nodes = [] :: [node()],
                         eject_nodes = [] :: [node()],
                         delta_nodes = [] :: [node()]}).

-record(pause_bucket_args, {bucket :: bucket_name(),
                            remote_path :: string()}).

-record(resume_bucket_args, {bucket :: bucket_name(),
                             remote_path :: string(),
                             dry_run :: boolean()}).

-record(state, { parent :: pid(),
                 service_manager :: pid(),
                 service :: service(),
                 all_nodes :: [node()],
                 op_type :: failover | rebalance | pause_bucket | resume_bucket,
                 op_body :: function(),
                 op_args :: #rebalance_args{} | #pause_bucket_args{} |
                            #resume_bucket_args{},
                 progress_callback :: fun ((dict:dict()) -> any())}).

with_trap_exit_spawn_monitor_rebalance(
  Service, KeepNodes, EjectNodes, DeltaNodes, ProgressCallback, Opts) ->
    with_trap_exit_spawn_monitor(Service, rebalance, KeepNodes ++ EjectNodes,
                                 fun rebalance_op/5,
                                 #rebalance_args{
                                    keep_nodes = KeepNodes,
                                    eject_nodes = EjectNodes,
                                    delta_nodes = DeltaNodes},
                                 ProgressCallback, Opts).

with_trap_exit_spawn_monitor_failover(Service, KeepNodes, Opts) ->
    with_trap_exit_spawn_monitor(Service, failover, KeepNodes,
                                 fun rebalance_op/5,
                                 #rebalance_args{keep_nodes = KeepNodes},
                                 fun (_) -> ok end, Opts).

with_trap_exit_spawn_monitor_pause_bucket(
  Service, Bucket, RemotePath, Nodes, ProgressCallback, Opts) ->
    with_trap_exit_spawn_monitor(Service, pause_bucket, Nodes,
                                 fun pause_bucket_op/5,
                                 #pause_bucket_args{
                                    bucket = Bucket,
                                    remote_path = RemotePath},
                                 ProgressCallback, Opts).

with_trap_exit_spawn_monitor_resume_bucket(
  Service, Bucket, RemotePath, DryRun, Nodes, ProgressCallback, Opts) ->
    with_trap_exit_spawn_monitor(Service, resume_bucket, Nodes,
                                 fun resume_bucket_op/5,
                                 #resume_bucket_args{
                                    bucket = Bucket,
                                    remote_path = RemotePath,
                                    dry_run = DryRun},
                                 ProgressCallback, Opts).

with_trap_exit_spawn_monitor(
  Service, Op, AllNodes, OpBody, OpArgs, ProgressCallback, Opts) ->
    Parent = self(),

    Timeout = maps:get(timeout, Opts, infinity),

    misc:with_trap_exit(
      fun () ->
              {Pid, MRef} =
                  misc:spawn_monitor(
                    fun () ->
                            run_op(
                              #state{parent = Parent,
                                     service_manager = self(),
                                     service = Service,
                                     op_type = Op,
                                     all_nodes = AllNodes,
                                     op_body = OpBody,
                                     op_args = OpArgs,
                                     progress_callback = ProgressCallback})
                    end),

              receive
                  {'EXIT', _Pid, Reason} = Exit ->
                      ?log_debug("Got an exit signal while running op: ~p "
                                 "for service: ~p. Exit message: ~p",
                                 [Op, Service, Exit]),
                      misc:terminate_and_wait(Pid, Reason),
                      exit(Reason);
                  {'DOWN', MRef, _, _, Reason} ->
                      case Reason of
                          normal ->
                              ok;
                          _ ->
                              FailedAtom =
                                  list_to_atom("service_" ++
                                               atom_to_list(Op) ++ "_failed"),
                              exit({FailedAtom, Service, Reason})
                      end
              after
                  Timeout ->
                      misc:terminate_and_wait(Pid, shutdown),
                      TimeoutAtom = list_to_atom("service_" ++
                                                 atom_to_list(Op) ++
                                                 "_timeout"),
                      {error, {TimeoutAtom, Service}}
              end
      end).

run_op(#state{parent = Parent} = State) ->
    erlang:register(name(State), self()),
    erlang:monitor(process, Parent),

    Agents = wait_for_agents(State),
    lists:foreach(
      fun ({_Node, Agent}) ->
              erlang:monitor(process, Agent)
      end, Agents),

    set_service_manager(State),
    case run_op_worker(State) of
        ok ->
            %% Only unset the service_manager when everything went
            %% smoothly. Otherwise, the cleanup will happen
            %% asynchronously.
            unset_service_manager(State);
        {error, Reason} ->
            exit(Reason)
    end.

wait_for_agents(#state{op_type = Type,
                       service = Service,
                       all_nodes = AllNodes}) ->
    Timeout = wait_for_agents_timeout(Type),
    {ok, Agents} = service_agent:wait_for_agents(Service, AllNodes, Timeout),
    Agents.

wait_for_agents_timeout(Type) ->
    Default = wait_for_agents_default_timeout(Type),
    ?get_timeout({wait_for_agent, Type}, Default).

wait_for_agents_default_timeout(rebalance) ->
    60000;
wait_for_agents_default_timeout(failover) ->
    10000;
wait_for_agents_default_timeout(pause_bucket) ->
    10000;
wait_for_agents_default_timeout(resume_bucket) ->
    10000.

set_service_manager(#state{service = Service,
                           all_nodes = AllNodes,
                           service_manager = Manager}) ->
    ok = service_agent:set_service_manager(Service, AllNodes, Manager).

unset_service_manager(#state{service = Service,
                             all_nodes = AllNodes,
                             service_manager = Manager}) ->
    case service_agent:unset_service_manager(Service, AllNodes, Manager) of
        ok ->
            ok;
        Other ->
            ?log_warning("Failed to unset "
                         "service_manager on some nodes:~n~p", [Other])
    end.

run_op_worker(#state{parent = Parent, op_type = Type} = State) ->
    {_, false} = process_info(self(), trap_exit),

    misc:with_trap_exit(
      fun () ->
              Worker = proc_lib:spawn_link(?cut(do_run_op(State))),
              receive
                  {'EXIT', Worker, normal} ->
                      ?log_debug("Worker terminated normally"),
                      ok;
                  {'EXIT', Worker, _Reason} = Exit ->
                      ?log_error("Worker terminated abnormally: ~p", [Exit]),
                      {error, {worker_died, Exit}};
                  {'EXIT', Parent, Reason} = Exit ->
                      ?log_error("Got exit message from parent: ~p", [Exit]),
                      misc:unlink_terminate_and_wait(Worker, shutdown),
                      {error, Reason};
                  {'DOWN', _, _, Parent, Reason} = Down ->
                      ?log_error("Parent died unexpectedly: ~p", [Down]),
                      misc:unlink_terminate_and_wait(Worker, shutdown),
                      {error, {parent_died, Parent, Reason}};
                  {'DOWN', _, _, Agent, Reason} = Down ->
                      ?log_error("Agent terminated during op: ~p, ~p",
                                 [Type, Down]),
                      misc:unlink_terminate_and_wait(Worker, shutdown),
                      {error, {agent_died, Agent, Reason}}
              end
      end).

do_run_op(#state{op_body = OpBody,
                 op_args = OpArgs,
                 service = Service,
                 all_nodes = AllNodes,
                 service_manager = Manager} = State) ->
    erlang:register(worker_name(State), self()),

    Id = couch_uuids:random(),

    {ok, NodeInfos} = service_agent:get_node_infos(Service,
                                                   AllNodes, Manager),
    ?log_debug("Got node infos:~n~p", [NodeInfos]),

    LeaderCandidates = leader_candidates(State),
    Leader = pick_leader(NodeInfos, LeaderCandidates),

    ?log_debug("Using node ~p as a leader", [Leader]),

    OpBody(State, OpArgs, Id, Leader, NodeInfos),
    wait_for_task_completion(State).

wait_for_task_completion(#state{service = Service, op_type = Type} = State) ->
    Timeout = ?get_timeout({Type, Service}, 10 * 60 * 1000),
    wait_for_task_completion_loop(Timeout, State).

wait_for_task_completion_loop(Timeout, #state{op_type = Type} = State) ->
    receive
        {task_progress, Progress} ->
            report_progress(Progress, State),
            wait_for_task_completion_loop(Timeout, State);
        {task_failed, Error} ->
            exit({task_failed, Type, {service_error, Error}});
        task_done ->
            ok
    after
        Timeout ->
            exit({task_failed, Type, inactivity_timeout})
    end.

report_progress(Progress, #state{all_nodes = AllNodes,
                                 progress_callback = Callback}) ->
    D = dict:from_list([{N, Progress} || N <- AllNodes]),
    Callback(D).

leader_candidates(#state{op_type = Op,
                         op_args = OpArgs}) when Op =:= rebalance;
                                                 Op =:= failover ->
    #rebalance_args{keep_nodes = Nodes} = OpArgs,
    Nodes;
leader_candidates(#state{op_type = Op,
                         all_nodes = Nodes}) when Op =:= pause_bucket;
                                                  Op =:= resume_bucket ->
    Nodes.

rebalance_op(#state{
                op_type = Type,
                service = Service,
                all_nodes = AllNodes,
                service_manager = Manager},
             #rebalance_args{
                keep_nodes = KeepNodes,
                eject_nodes = EjectNodes,
                delta_nodes = DeltaNodes}, Id, Leader, NodeInfos) ->

    ?rebalance_info("Rebalancing service ~p with id ~p."
                    "~nKeepNodes: ~p~nEjectNodes: ~p~nDeltaNodes: ~p",
                    [Service, Id, KeepNodes, EjectNodes, DeltaNodes]),

    {KeepNodesArg, EjectNodesArg} = build_rebalance_args(KeepNodes, EjectNodes,
                                                         DeltaNodes, NodeInfos),

    ok = service_agent:prepare_rebalance(Service, AllNodes, Manager,
                                         Id, Type, KeepNodesArg, EjectNodesArg),

    ok = service_agent:start_rebalance(Service, Leader, Manager,
                                       Id, Type, KeepNodesArg, EjectNodesArg).

pause_bucket_op(#state{service = Service,
                       all_nodes = Nodes,
                       service_manager = Manager},
                #pause_bucket_args{bucket = Bucket,
                                   remote_path = RemotePath},
                Id, Leader, _NodesInfo) ->
    ok = service_agent:prepare_pause_bucket(Service, Nodes, Bucket, RemotePath,
                                            Id, Manager),
    ok = service_agent:pause_bucket(Service, Leader, Bucket, RemotePath, Id,
                                    Manager).

resume_bucket_op(#state{service = Service,
                        all_nodes = Nodes,
                        service_manager = Manager},
                 #resume_bucket_args{bucket = Bucket,
                                     remote_path = RemotePath,
                                     dry_run = DryRun},
                 Id, Leader, _NodesInfo) ->
    ok = service_agent:prepare_resume_bucket(Service, Nodes, Bucket, RemotePath,
                                             DryRun, Id, Manager),
    ok = service_agent:resume_bucket(Service, Leader, Bucket, RemotePath,
                                     DryRun, Id, Manager).

build_rebalance_args(KeepNodes, EjectNodes, DeltaNodes0, NodeInfos0) ->
    NodeInfos = dict:from_list(NodeInfos0),
    DeltaNodes = sets:from_list(DeltaNodes0),

    KeepNodesArg =
        lists:map(
          fun (Node) ->
                  NodeInfo = dict:fetch(Node, NodeInfos),
                  RecoveryType =
                      case sets:is_element(Node, DeltaNodes) of
                          true ->
                              delta;
                          false ->
                              full
                      end,
                  {NodeInfo, RecoveryType}
          end, KeepNodes),

    EjectNodesArg = [dict:fetch(Node, NodeInfos) || Node <- EjectNodes],

    {KeepNodesArg, EjectNodesArg}.

worker_name(#state{service = Service}) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ atom_to_list(Service) ++ "-worker").

name(#state{service = Service}) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ atom_to_list(Service)).

pick_leader(NodeInfos, KeepNodes) ->
    Master = node(),
    {Leader, _} =
        misc:min_by(
          fun ({NodeLeft, InfoLeft}, {NodeRight, InfoRight}) ->
                  {_, PrioLeft} = lists:keyfind(priority, 1, InfoLeft),
                  {_, PrioRight} = lists:keyfind(priority, 1, InfoRight),
                  KeepLeft = lists:member(NodeLeft, KeepNodes),
                  KeepRight = lists:member(NodeRight, KeepNodes),

                  {PrioLeft, KeepLeft, NodeLeft =:= Master} >
                      {PrioRight, KeepRight, NodeRight =:= Master}
          end, NodeInfos),

    Leader.
