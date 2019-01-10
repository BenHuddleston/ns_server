-module(roles_cache).

-behaviour(active_cache).

%% API
-export([start_link/0, build_compiled_roles/1]).

%% callbacks
-export([init/1, translate_options/1]).

-include("cut.hrl").
-include("ns_common.hrl").
-include("ns_config.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_MAX_PARALLEL_PROCESSES, 100).
-define(DEFAULT_MAX_CACHE_SIZE, 10000).
-define(DEFAULT_VALUE_LIFETIME, 24*60*60*1000).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    Get = ?cut({_1, ns_config:read_key_fast(_1, ?DELETED_MARKER)}),
    Settings = [Get(external_user_roles_cache_size),
                Get(external_user_roles_parrallel_procs),
                Get(external_user_roles_cache_expiration_timeout),
                {external_auth_polling_interval,
                 menelaus_roles:external_auth_polling_interval()}],
    Opts = [opt(P) || P <- Settings],
    active_cache:start_link(?MODULE, ?MODULE, [], Opts).

build_compiled_roles(Identity) ->
    Key = {?FUNCTION_NAME, Identity},
    Fun = fun () -> menelaus_roles:build_compiled_roles(Identity) end,
    active_cache:get_value_and_touch(?MODULE, Key, Fun).

%%%===================================================================
%%% callbacks
%%%===================================================================

init([]) ->
    EventHandler =
        fun ({P, _} = Event)
            when P =:= external_user_roles_cache_size;
                 P =:= external_user_roles_parrallel_procs;
                 P =:= external_user_roles_cache_expiration_timeout;
                 P =:= external_auth_polling_interval ->
                active_cache:reload_opts(?MODULE, [Event]);
            ({ldap_settings, _}) ->
                %% Ldap cache might receive this notification later
                %% but we need to make sure it is flushed before
                %% we renew the upper level cache
                ldap_auth_cache:flush(),
                active_cache:renew_cache(?MODULE);
            (_) -> ok
        end,
    ns_pubsub:subscribe_link(ns_config_events, EventHandler),
    ok.

translate_options([Opt]) -> [opt(Opt)].

%%%===================================================================
%%% Internal functions
%%%===================================================================

opt({external_user_roles_cache_size, ?DELETED_MARKER}) ->
    {max_size, ?DEFAULT_MAX_CACHE_SIZE};
opt({external_user_roles_cache_size, V}) ->
    {max_size, V};
opt({external_user_roles_parrallel_procs, ?DELETED_MARKER}) ->
    {max_parallel_procs, ?DEFAULT_MAX_PARALLEL_PROCESSES};
opt({external_user_roles_parrallel_procs, V}) ->
    {max_parallel_procs, V};
opt({external_user_roles_cache_expiration_timeout, ?DELETED_MARKER}) ->
    {value_lifetime, ?DEFAULT_VALUE_LIFETIME};
opt({external_user_roles_cache_expiration_timeout, V}) ->
    {value_lifetime, V};
opt({external_auth_polling_interval, _}) ->
    Val = menelaus_roles:external_auth_polling_interval(),
    {renew_interval, round(0.75*Val)}.
