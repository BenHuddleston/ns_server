%% @author Couchbase <info@couchbase.com>
%% @copyright 2019 Couchbase, Inc.
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
%% Settings for various features that trigger automatic rebalance.
%%

-module(auto_rebalance_settings).

-include("ns_common.hrl").

%% Retry rebalance max attempts
-define(RETRY_ATTEMPTS_DEFAULT, 1).
%% Retry rebalance after time period in seconds
-define(RETRY_AFTER_DEFAULT, 300).

-export([config_upgrade_to_madhatter/0,
         get_retry_rebalance/0,
         set_retry_rebalance/1,
         get_retry_after/1,
         get_retry_max/1,
         is_retry_enabled/0]).

config_upgrade_to_madhatter() ->
    DefaultEnable = cluster_compat_mode:is_enterprise(),
    Cfg = [{enabled, DefaultEnable},
           {after_time_period, ?RETRY_AFTER_DEFAULT},
           {max_attempts, ?RETRY_ATTEMPTS_DEFAULT}],
    [{set, retry_rebalance, Cfg}].

get_retry_rebalance() ->
    get_retry_rebalance(ns_config:latest()).

get_retry_rebalance(Config) ->
    ns_config:search(Config, retry_rebalance, []).

get_retry_after(Config) ->
    proplists:get_value(after_time_period, get_retry_rebalance(Config)).

get_retry_max(Config) ->
    proplists:get_value(max_attempts, get_retry_rebalance(Config)).

is_retry_enabled() ->
    %% TODO: Replcae with ns_config:latest() once MB-32881 is fixed.
    is_retry_enabled(ns_config:get()).

is_retry_enabled(Config) ->
    proplists:get_value(enabled, get_retry_rebalance(Config), false).

set_retry_rebalance(Settings) ->
    Curr = get_retry_rebalance(ns_config:latest()),
    CurrEn = proplists:get_value(enabled, Curr),
    CurrAfter = proplists:get_value(after_time_period, Curr),
    CurrMax = proplists:get_value(max_attempts, Curr),

    %% TODO: adjust time for any retry currently pending.
    After = proplists:get_value(afterTimePeriod, Settings, CurrAfter),
    %% TODO: adjust count for any retry currently pending.
    Max = proplists:get_value(maxAttempts, Settings, CurrMax),
    NewEn = proplists:get_value(enabled, Settings),

    maybe_cancel_pending_retry(CurrEn, NewEn),

    New = [{enabled, NewEn}, {after_time_period, After}, {max_attempts, Max}],
    ns_config:set(retry_rebalance, New).

maybe_cancel_pending_retry(true, false) ->
    auto_rebalance:cancel_any_pending_retry("feature disable");
maybe_cancel_pending_retry(_, _) ->
    ok.

