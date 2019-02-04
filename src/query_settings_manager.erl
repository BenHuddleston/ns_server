%% @author Couchbase <info@couchbase.com>
%% @copyright 2015-2019 Couchbase, Inc.
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
-module(query_settings_manager).

-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behavior(json_settings_manager).

-export([start_link/0,
         get/1,
         get_from_config/3,
         update/2,
         config_upgrade_to_55/0
        ]).

-export([cfg_key/0,
         is_enabled/0,
         known_settings/0,
         on_update/2]).

-import(json_settings_manager,
        [id_lens/1]).

-define(QUERY_CONFIG_KEY, {metakv, <<"/query/settings/config">>}).

start_link() ->
    json_settings_manager:start_link(?MODULE).

get(Key) ->
    json_settings_manager:get(?MODULE, Key, undefined).

get_from_config(Config, Key, Default) ->
    json_settings_manager:get_from_config(?MODULE, Config, Key, Default).

cfg_key() ->
    ?QUERY_CONFIG_KEY.

is_enabled() ->
    cluster_compat_mode:is_cluster_55().

on_update(_Key, _Value) ->
    ok.

update(Key, Value) ->
    json_settings_manager:update(?MODULE, [{Key, Value}]).

config_upgrade_to_55() ->
    [{set, ?QUERY_CONFIG_KEY,
      json_settings_manager:build_settings_json(default_settings_for_55(),
                                                dict:new(), known_settings())}].

known_settings() ->
    [{generalSettings, general_settings_lens()},
     {curlWhitelistSettings, curl_whitelist_settings_lens()}].

default_settings_for_55() ->
    [{generalSettings, general_settings_defaults()},
     {curlWhitelistSettings, curl_whitelist_settings_defaults()}].

general_settings_lens_props() ->
    [{queryTmpSpaceDir, id_lens(<<"query.settings.tmp_space_dir">>)},
     {queryTmpSpaceSize, id_lens(<<"query.settings.tmp_space_size">>)}].

curl_whitelist_settings_len_props() ->
    [{queryCurlWhitelist, id_lens(<<"query.settings.curl_whitelist">>)}].

general_settings_defaults() ->
    [{queryTmpSpaceDir, list_to_binary(path_config:component_path(tmp))},
     {queryTmpSpaceSize, ?QUERY_TMP_SPACE_DEF_SIZE}].

curl_whitelist_settings_defaults() ->
    [{queryCurlWhitelist, {[{<<"all_access">>, false},
                            {<<"allowed_urls">>, []},
                            {<<"disallowed_urls">>, []}]}}].

general_settings_lens() ->
    json_settings_manager:props_lens(general_settings_lens_props()).

curl_whitelist_settings_lens() ->
    json_settings_manager:props_lens(curl_whitelist_settings_len_props()).


-ifdef(TEST).
defaults_test() ->
    Keys = fun (L) -> lists:sort([K || {K, _} <- L]) end,

    ?assertEqual(Keys(known_settings()), Keys(default_settings_for_55())),
    ?assertEqual(Keys(curl_whitelist_settings_len_props()),
                 Keys(curl_whitelist_settings_defaults())),
    ?assertEqual(Keys(general_settings_lens_props()),
                 Keys(general_settings_defaults())).
-endif.
