%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015-2018 Couchbase, Inc.
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
-module(services_stats_sup).

-include("ns_common.hrl").

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children =
        [{service_stats_children_sup,
          {supervisor, start_link,
           [{local, service_stats_children_sup}, ?MODULE, child]},
          permanent, infinity, supervisor, []},
         {service_status_keeper_sup,
          {service_status_keeper_sup, start_link, []},
          permanent, infinity, supervisor, []},
         {service_stats_worker, {erlang, apply, [fun start_link_worker/0, []]},
          permanent, 1000, worker, []}],
    {ok, {{one_for_all,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          Children}};
init(child) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

is_notable_event(buckets) ->
    true;
is_notable_event({node, Node, membership}) when Node =:= node() ->
    true;
is_notable_event(rest_creds) ->
    true;
is_notable_event(_) ->
    false.

compute_wanted_children(Service, Snapshot) ->
    case ns_cluster_membership:should_run_service(Snapshot, Service:get_type(),
                                                  node()) of
        false ->
            [];
        true ->
            StaticChildren = [{Service, service_stats_collector}],

            %% Stats reader for Service specific stats (backward compat)
            ServiceChildren =
                [{Service, stats_reader,
                  service_stats_collector:service_event_name(Service)}],

            BucketCfgs = ns_bucket:get_buckets(Snapshot),
            BucketNames =
                [Name || {Name, BConfig} <- BucketCfgs,
                         lists:keyfind(type, 1, BConfig) =:= {type, membase}],
            PerBucketChildren =
                [{Service, stats_reader, Name}
                 || Name <- BucketNames],

            lists:sort(StaticChildren ++ PerBucketChildren ++ ServiceChildren)
    end.

refresh_children() ->
    RunningChildren0 =
        [Id || {Id, _, _, _} <-
                   supervisor:which_children(service_stats_children_sup)],
    RunningChildren = lists:sort(RunningChildren0),
    Snapshot = chronicle_compat:get_snapshot(
                 [ns_bucket:key_filter(),
                  ns_cluster_membership:key_filter()]),
    WantedChildren0 = compute_wanted_children(service_fts, Snapshot) ++
        compute_wanted_children(service_index, Snapshot) ++
        compute_wanted_children(service_cbas, Snapshot) ++
        compute_wanted_children(service_eventing, Snapshot),
    WantedChildren = lists:sort(WantedChildren0),
    ToStart = ordsets:subtract(WantedChildren, RunningChildren),
    ToStop = ordsets:subtract(RunningChildren, WantedChildren),
    lists:foreach(fun stop_child/1, ToStop),
    lists:foreach(fun start_child/1, ToStart),
    ok.

child_spec({Service, Mod, Name}) when Name =:= "@index" orelse
                                      Name =:= "@fts" orelse
                                      Name =:= "@cbas" orelse
                                      Name =:= "@eventing" ->
    {{Service, Mod, Name}, {Mod, start_link, [Name]},
     permanent, 1000, worker, []};
child_spec({Service, Mod, Name}) when Mod =:= stats_reader ->
    {{Service, Mod, Name},
     {Mod, start_link,
      [service_stats_collector:service_prefix(Service) ++ Name]},
     permanent, 1000, worker, []};
child_spec({Service, Mod}) ->
    {{Service, Mod}, {Mod, start_link, [Service]}, permanent, 1000, worker, []}.

start_child(Id) ->
    {ok, _Pid} =
        supervisor:start_child(service_stats_children_sup, child_spec(Id)).

stop_child(Id) ->
    ok = supervisor:terminate_child(service_stats_children_sup, Id),
    ok = supervisor:delete_child(service_stats_children_sup, Id).

start_link_worker() ->
    chronicle_compat:start_refresh_worker(fun is_notable_event/1,
                                          fun refresh_children/0).
