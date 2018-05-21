%% @author Couchbase <info@couchbase.com>
%% @copyright 2018 Couchbase, Inc.
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
-module(rebalance_quirks).

-define(TABLE, ?MODULE).
-define(WAIT_STATUSES_TIMEOUT,
        ns_config:get_timeout({?MODULE, wait_statuses}, 15000)).

-export([get_quirks/1, is_enabled/2, get_node_quirks/2,
         default_config/0, upgrade_config_to_4_6_5/0]).
-export_type([quirk/0]).

-type quirk() :: takeover_via_orchestrator |
                 disable_old_master |
                 reset_replicas |
                 trivial_moves.

%% APIs
get_quirks(Nodes) ->
    Config = ns_config:get(),
    OverrideQuirks =
        lists:filtermap(
          fun (Node) ->
                  case get_override_quirks(Node, Config) of
                      false ->
                          false;
                      {value, Quirks} ->
                          {true, {Node, Quirks}}
                  end
          end, Nodes),

    OtherNodes     = Nodes -- proplists:get_keys(OverrideQuirks),
    ComputedQuirks = compute_quirks(OtherNodes, Config),

    OverrideQuirks ++
        lists:map(
          fun ({Node, NodeQuirks}) ->
                  Extra    = get_extra_quirks(Node, Config),
                  Disabled = get_disabled_quirks(Node, Config),

                  {Node, lists:usort(NodeQuirks ++ Extra) -- Disabled}
          end, ComputedQuirks).

is_enabled(Quirk, Quirks) ->
    true = lists:member(Quirk, all_quirks()),
    proplists:get_bool(Quirk, Quirks).

get_node_quirks(Node, Quirks) ->
    proplists:get_value(Node, Quirks, []).

default_config() ->
    [{project_intact_vulnerable_key(), false}].

upgrade_config_to_4_6_5() ->
    [{set, project_intact_vulnerable_key(), false}].

%% internal
get_override_quirks(Node, Config) ->
    ns_config:search_node(Node, Config, override_rebalance_quirks).

get_extra_quirks(Node, Config) ->
    ns_config:search_node_with_default(Node, Config,
                                       extra_rebalance_quirks, []).

get_disabled_quirks(Node, Config) ->
    ns_config:search_node_with_default(Node, Config,
                                       disable_rebalance_quirks, []).

compute_quirks(Nodes, Config) ->
    Unpatched = [N || N <- Nodes,
                      not has_project_intact_patches(N, Config)],

    case Unpatched of
        [] ->
            [{N, []} || N <- Nodes];
        _ ->
            lists:map(fun ({Node, Status}) ->
                              case get_version(Status) of
                                  {ok, Version} ->
                                      {Node, quirks_for_version(Version)};
                                  no_version ->
                                      exit({no_version_for_node, Node})
                              end
                      end, get_statuses(Nodes))
    end.

get_statuses(Nodes) ->
    case ns_doctor:wait_statuses(Nodes, ?WAIT_STATUSES_TIMEOUT) of
        {ok, Statuses} ->
            dict:to_list(Statuses);
        {error, {timeout, MissingNodes}} ->
            exit({missing_node_statuses, MissingNodes})
    end.

get_version(Status) ->
    AppVersions = proplists:get_value(version, Status, []),
    case proplists:get_value(ns_server, AppVersions) of
        undefined ->
            no_version;
        Version ->
            try misc:parse_version(Version) of
                {[_, _, _] = VersionTriple, _, _} ->
                    {ok, VersionTriple};
                _Other ->
                    no_version
            catch
                _:_ ->
                    no_version
            end
    end.

-spec all_quirks() -> [quirk()].
all_quirks() ->
    [takeover_via_orchestrator,
     disable_old_master,
     reset_replicas,
     trivial_moves].

quirks_for_version(Version) ->
    [Quirk || Quirk <- all_quirks(),
              is_quirk_required(Quirk, Version)].

is_quirk_required(takeover_via_orchestrator, Version) ->
    Version < [5, 1, 0];
is_quirk_required(_, _) ->
    false.

has_project_intact_patches(Node, Config) ->
    not ns_config:search(Config, project_intact_vulnerable_key(Node), true).

project_intact_vulnerable_key() ->
    project_intact_vulnerable_key(node()).

project_intact_vulnerable_key(Node) ->
    {node, Node, {project_intact, is_vulnerable}}.
