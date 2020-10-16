%% @author Couchbase <info@couchbase.com>
%% @copyright 2009-2019 Couchbase, Inc.
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
%% @doc Web server for menelaus.

-module(menelaus_alert).
-author('Northscale <info@northscale.com>').

-include("ns_log.hrl").
-include("ns_common.hrl").
-include("cut.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([handle_logs/1,
         handle_settings_alerts/1,
         handle_settings_alerts_post/1,
         handle_settings_alerts_send_test_email/1,
         build_alerts_json/1,
         build_alerts_config/1]).

-export([category_bin/1]).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3,
         reply/2]).

%% External API

-define(DEFAULT_LIMIT, 250).

handle_logs(Req) ->
    reply_json(Req, {struct, [{list, build_logs(mochiweb_request:parse_qs(Req))}]}).

%% @doc Handle the email alerts request.
handle_settings_alerts(Req) ->
    {value, Config} = ns_config:search(email_alerts),
    reply_json(Req, {struct, build_alerts_json(Config)}).

%% @doc Handle the email alerts post.
handle_settings_alerts_post(Req) ->
    validator:handle(fun (Values) ->
                             Config = build_alerts_config(Values),
                             ns_config:set(email_alerts, Config),
                             ns_audit:alerts(Req, Config),
                             reply(Req, 200)
                     end, Req, form, alerts_query_validators()).

%% @doc Sends a test email with the current settings
handle_settings_alerts_send_test_email(Req) ->
    validator:handle(fun (Values) ->
                             Subject = proplists:get_value(subject, Values),
                             Body = proplists:get_value(body, Values),
                             Config = build_alerts_config(Values),
                             send_test_message(Req, Subject, Body, Config)
                     end, Req, form, alerts_query_validators()).

%% @doc Returns the config settings as Mochijson2 JSON
-spec build_alerts_json([{atom(), any()}]) -> [{atom(), any()}].
build_alerts_json(Config) ->
    Server = proplists:get_value(email_server, Config),
    Rcpts = [list_to_binary(R) || R <- proplists:get_value(recipients,
                                                           Config)],
    [{recipients, Rcpts},
     {sender, list_to_binary(proplists:get_value(sender, Config))},
     {enabled, proplists:get_value(enabled, Config)},
     {emailServer,
      {struct,
       [{user, list_to_binary(proplists:get_value(user, Server))},
        {pass, <<"">>},
        {host, list_to_binary(proplists:get_value(host, Server))},
        {port, proplists:get_value(port, Server)},
        {encrypt, proplists:get_value(encrypt, Server)}]}},
     {alerts, proplists:get_value(alerts, Config)}].

%% @doc Create the config structure from the Args proplist.
%% arguments.
-spec build_alerts_config([{atom(), any()}]) -> [{atom(), any()}].
build_alerts_config(Args) ->
    [{recipients, proplists:get_value(recipients, Args, [])},
     {sender, proplists:get_value(sender, Args, "couchbase@localhost")},
     {enabled, proplists:get_bool(enabled, Args)},
     {email_server, [{user, proplists:get_value(emailUser, Args, "")},
                     {pass, proplists:get_value(emailPass, Args, "")},
                     {host,
                      proplists:get_value(emailHost, Args, "localhost")},
                     {port, proplists:get_value(emailPort, Args, 25)},
                     {encrypt,
                      proplists:get_bool(emailEncrypt, Args)}]},
     {alerts, proplists:get_value(alerts, Args, [])}].

%%
%% Internal functions
%%

default(message_body) ->
    "This email was sent to you to test the email alert email server settings.";
default(subject)->
    "Test email from Couchbase Server".

alerts_query_validators() ->
    [validator:required(enabled, _),
     validator:boolean(enabled, _),

     validator:string(sender, _),
     validator:default(sender, "couchbase@localhost", _),
     validator:email_address(sender, _),

     validator:string(recipients, _),
     validator:token_list(recipients, ",", _),
     validate_recipients(_),
     validator:default(recipients, [], _),

     validator:string(emailHost, _),
     validator:default(emailHost, "localhost",  _),

     validator:integer(emailPort, _),
     validator:default(emailPort, 25, _),

     validator:boolean(emailEncrypt, _),
     validator:default(emailEncrypt, false, _),

     validator:string(emailUser, _),
     validator:default(emailUser, "", _),

     validator:string(emailPass, _),
     validator:default(emailPass, "", _),

     validator:string(alerts, _),
     validate_alerts(alerts, _),
     validator:default(alerts, [], _),

     validator:string(body, _),
     validator:default(body, default(message_body), _),

     validator:string(subject, _),
     validator:default(subject, default(subject), _),

     %% Any other parameters are unsupported.
     validator:unsupported(_)
].

send_test_message(Req, Subject, Body, Config) ->
    case ns_mail:send(Subject, Body, Config) of
        ok ->
            reply(Req, 200);
        {error, Reason} ->
            Msg =
                case Reason of
                    {_, _, {error, R}} ->
                        R;
                    {_, _, R} ->
                        R;
                    R ->
                        R
                end,

            reply_json(Req, {struct, [{error, couch_util:to_binary(Msg)}]}, 400)
    end.

%% @doc Returns a list of all alerts that might send out an email notification.
%% Every module that creates alerts that should be sent by email needs to
%% implement an alert_keys/0 function that returns all its alert keys.
-spec alert_keys() -> [atom()].
alert_keys() ->
    Modules = [auto_failover, menelaus_web_alerts_srv],
    Keys = [M:alert_keys() || M <- Modules],
    lists:append(Keys).

-spec alert_keys_string_list() -> [string()].
alert_keys_string_list() ->
    [atom_to_list(K) || K <- alert_keys()].

-spec alert_keys_string([atom()]) -> string().
alert_keys_string(Keys) ->
    string:join([atom_to_list(K) || K <- Keys], ", ").

-spec is_legal_alert_key_string(Key::string()) -> boolean().
is_legal_alert_key_string(Key) ->
   lists:member(Key, alert_keys_string_list()).

%% validate a string containing alert keys
-spec validate_alerts(atom(), tuple()) -> tuple().
validate_alerts(Name, State) ->
    validator:validate(
      fun (AlertsString) ->
              AlertsKeys = string:lexemes(AlertsString, ","),
              GoodKeys = lists:filter(
                           fun(Key) -> is_legal_alert_key_string(Key) end,
                           AlertsKeys),
              BadKeys = AlertsKeys -- GoodKeys,

              case BadKeys of
                  [] ->
                      GoodKeysAtoms = [list_to_atom(A) || A <- GoodKeys],
                      {value, GoodKeysAtoms};
                  _ ->
                      {error, error_message(bad_key)}
              end
      end, Name, State).

error_message(bad_key) ->
    io_lib:format("alerts contained invalid keys. Valid keys are: ~s.",
                  [alert_keys_string(alert_keys())]);
error_message(bad_recipients) ->
    "recipients must be a comma separated list of valid email addresses.".

%% validate email recipients
-spec validate_recipients(tuple()) -> tuple().
validate_recipients(State) ->
    validator:validate(
      fun (Recipients) ->
              Good = lists:filter(
                       fun menelaus_util:validate_email_address/1, Recipients),
              Bad = Recipients -- Good,
              case Bad of
                  [] ->
                      {value, Good};
                  _ ->
                      {error, error_message(bad_recipients)}
              end
      end, recipients, State).

build_logs(Params) ->
    {MinTStamp, Limit} = common_params(Params),
    build_log_structs(ns_log:recent(), MinTStamp, Limit).

build_log_structs(LogEntriesIn, MinTStamp, Limit) ->
    LogEntries =
        lists:filter(
          fun(#log_entry{tstamp = TStamp}) ->
                  misc:timestamp_to_time(TStamp, millisecond) > MinTStamp
          end,
          LogEntriesIn),
    LogEntries2 = lists:reverse(lists:keysort(#log_entry.tstamp, LogEntries)),
    LogEntries3 = lists:sublist(LogEntries2, Limit),
    LogStructs =
        lists:foldl(
          fun(#log_entry{node = Node,
                         module = Module,
                         code = Code,
                         msg = Msg,
                         args = Args,
                         cat = Cat,
                         tstamp = TStamp = {_, _, MicroSecs},
                         server_time = ServerTime}, Acc) ->
                  case catch(io_lib:format(Msg, Args)) of
                      S when is_list(S) ->
                          CodeString = ns_log:code_string(Module, Code),
                          S1 = ns_log:prepare_message(Module, Code, S),
                          [{struct,
                            [{node, Node},
                             {type, category_bin(Cat)},
                             {code, Code},
                             {module, list_to_binary(atom_to_list(Module))},
                             {tstamp, misc:timestamp_to_time(TStamp,
                                                             millisecond)},
                             {shortText, list_to_binary(CodeString)},
                             {text, list_to_binary(S1)},
                             {serverTime, menelaus_util:format_server_time(
                                            ServerTime, MicroSecs)}
                            ]} | Acc];
                      _ -> Acc
                  end
          end,
          [],
          LogEntries3),
    LogStructs.

category_bin(info) -> <<"info">>;
category_bin(warn) -> <<"warning">>;
category_bin(crit) -> <<"critical">>;
category_bin(_)    -> <<"info">>.


common_params(Params) ->
    MinTStamp = case proplists:get_value("sinceTime", Params) of
                     undefined -> 0;
                     V -> list_to_integer(V)
                 end,
    Limit = case proplists:get_value("limit", Params) of
                undefined -> ?DEFAULT_LIMIT;
                L -> list_to_integer(L)
            end,
    {MinTStamp, Limit}.

-ifdef(TEST).
sort_if_list(X) when is_list(X) ->
    %% Only sort non-string lists.
    case io_lib:printable_list(X) of
        true ->
            X;
        _ ->
            lists:sort(X)
    end;
sort_if_list(X) ->
    X.

%% Sort a key/value list by key, also sorting the values if they are
%% non-string lists.
sort_kv(L) ->
    lists:sort([{K, sort_if_list(V)} || {K, V} <- L]).

validate_all_params_correct_test() ->
    Params =
        [{"alerts",
          "auto_failover_node,"
          "auto_failover_maximum_reached,"
          "auto_failover_other_nodes_down,"
          "auto_failover_cluster_too_small"},
         {"body", default(message_body)},
         {"emailEncrypt", "false"},
         {"emailHost", "foo.com"},
         {"emailPass", "password"},
         {"emailPort", "25"},
         {"emailUser", "ploni"},
         {"enabled", "true"},
         {"recipients", "foo@bar.com,bar@bar.com"},
         {"sender", "noreply@couchbase.com"},
         {"subject", default(subject)}],

    ExpectedValues =
        [{alerts, [auto_failover_node,auto_failover_maximum_reached,
                   auto_failover_other_nodes_down,
                   auto_failover_cluster_too_small]},
         {body, default(message_body)},
         {emailEncrypt, false},
         {emailHost, "foo.com"},
         {emailPass, "password"},
         {emailPort, 25},
         {emailUser, "ploni"},
         {enabled, true},
         {sender, "noreply@couchbase.com"},
         {subject, default(subject)},
         {recipients, ["foo@bar.com", "bar@bar.com"]}],

    {ok, Values} = validator:handle_proplist(Params, alerts_query_validators()),
    ?assertEqual(sort_kv(ExpectedValues), sort_kv(Values)).

validate_params_defaults_test() ->
    %% All parameters except "enabled" have default values.
    Params = [{"enabled", "true"}],

    ExpectedValues =
        [{alerts, []},
         {body, default(message_body) },
         {emailEncrypt, false},
         {emailHost, "localhost"},
         {emailPass, []},
         {emailPort, 25},
         {emailUser, []},
         {enabled, true},
         {sender, "couchbase@localhost"},
         {subject, default(subject)},
         {recipients, []}],

    {ok, Values} = validator:handle_proplist(Params, alerts_query_validators()),
    ?assertEqual(sort_kv(ExpectedValues), sort_kv(Values)).

%% Ensure that we get an error when an invalid parameter is supplied.
validate_params_invalid_parameter_test() ->
    Params =
        [{"alerts",
          "auto_failover_node,"
          "auto_failover_maximum_reached,"
          "auto_failover_other_nodes_down,"
          "auto_failover_cluster_too_small"},
         %% unsupported parameter
         {"bogus_parameter", "some_value"},
         {"body", default(message_body)},
         {"emailEncrypt", "false"},
         {"emailHost", "foo.com"},
         {"emailPass", "password"},
         {"emailPort", "25"},
         {"emailUser", "ploni"},
         {"enabled", "true"},
         {"recipients", "foo@bar.com,bar@bar.com"},
         {"sender", "noreply@couchbase.com"},
         {"subject", default(subject)}],

    ExpectedErrors = [{"bogus_parameter", <<"Unsupported key">>}],

    {error, Errors} =
        validator:handle_proplist(Params, alerts_query_validators()),
    ?assertEqual(sort_kv(ExpectedErrors), sort_kv(Errors)).

%% Ensure that we get an error when invalid alert keys are supplied.
validate_params_invalid_alerts_list_test() ->
    Params =
        [{"alerts",
          "auto_failover_node,"
          "auto_failover_maximum_reached,"
          "auto_failover_other_nodes_down,"
          "auto_failover_cluster_too_small"
          "bogus_alert"},
         {"body", default(message_body)},
         {"emailEncrypt", "false"},
         {"emailHost", "foo.com"},
         {"emailPass", "password"},
         {"emailPort", "25"},
         {"emailUser", "ploni"},
         {"enabled", "true"},
         {"recipients", "foo@bar.com,bar@bar.com"},
         {"sender", "noreply@couchbase.com"},
         {"subject", default(subject)}],

    ExpectedErrors = [{"alerts", error_message(bad_key)}],

    {error, Errors} =
        validator:handle_proplist(Params, alerts_query_validators()),
    ?assertEqual(sort_kv(ExpectedErrors), sort_kv(Errors)).

%% Ensure that we get an error when invalid recipients are supplied.
validate_params_invalid_recipients_test() ->
    Params =
        [{"alerts",
          "auto_failover_node,"
          "auto_failover_maximum_reached,"
          "auto_failover_other_nodes_down,"
          "auto_failover_cluster_too_small"},
         {"body", default(message_body)},
         {"emailEncrypt", "false"},
         {"emailHost", "foo.com"},
         {"emailPass", "password"},
         {"emailPort", "25"},
         {"emailUser", "ploni"},
         {"enabled", "true"},
         {"recipients", "foo@,@bar.com"},
         {"sender", "noreply@couchbase.com"},
         {"subject", default(subject)}],

    ExpectedErrors = [{"recipients", error_message(bad_recipients)}],

    {error, Errors} =
        validator:handle_proplist(Params, alerts_query_validators()),
    ?assertEqual(sort_kv(ExpectedErrors), sort_kv(Errors)).

build_alerts_config_all_specified_test() ->
    Values =
        [{alerts, [auto_failover_node,auto_failover_maximum_reached,
                   auto_failover_other_nodes_down,
                   auto_failover_cluster_too_small]},
         {body, "the message body shouldn't be in the config"},
         {emailEncrypt, false},
         {emailHost, "foo.com"},
         {emailPass, "password"},
         {emailPort, 25},
         {emailUser, "ploni"},
         {enabled, true},
         {sender, "noreply@couchbase.com"},
         {subject, "the subject line shouldn't be in the config"},
         {recipients, ["foo@bar.com", "bar@bar.com"]}],

    ExpectedConfig =
        [{alerts, [auto_failover_node,auto_failover_maximum_reached,
                   auto_failover_other_nodes_down,
                   auto_failover_cluster_too_small]},
         %% body shouldn't be in the config.
         {email_server,[{encrypt, false},
                        {host, "foo.com"},
                        {pass, "password"},
                        {port, 25},
                        {user, "ploni"}]},
         {enabled, true},
         {sender, "noreply@couchbase.com"},
         %% subject shouldn't be in the config.
         {recipients, ["foo@bar.com", "bar@bar.com"]}],

    Config = build_alerts_config(Values),
    ?assertEqual(sort_kv(ExpectedConfig), sort_kv(Config)).

build_alerts_config_defaults_test() ->
    Values =
        [{alerts, [auto_failover_node,auto_failover_maximum_reached,
                   auto_failover_other_nodes_down,
                   auto_failover_cluster_too_small]},
         %% leave out emailEncrypt
         {emailHost, "foo.com"},
         {emailPass, "password"},
         {emailPort, 25},
         {emailUser, "ploni"},
         {enabled, true},
         %% leave out sender
         {recipients, ["foo@bar.com", "bar@bar.com"]}],

    ExpectedConfig =
        [{alerts, [auto_failover_node,auto_failover_maximum_reached,
                   auto_failover_other_nodes_down,
                   auto_failover_cluster_too_small]},
         {email_server,[%% email_encrypt default value
                        {encrypt, false},
                        {host, "foo.com"},
                        {pass, "password"},
                        {port, 25},
                        {user, "ploni"}]},
         {enabled, true},
         % sender default value
         {sender, "couchbase@localhost"},
         {recipients, ["foo@bar.com", "bar@bar.com"]}],

    Config = build_alerts_config(Values),
    ?assertEqual(sort_kv(ExpectedConfig), sort_kv(Config)).
-endif.
