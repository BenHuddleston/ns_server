%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%

%% @doc rest api's for collections

-module(menelaus_web_collections).

-include("ns_common.hrl").
-include("cut.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([handle_get/2,
         handle_post_scope/2,
         handle_post_collection/3,
         handle_delete_scope/3,
         handle_delete_collection/4,
         handle_patch_collection/4,
         handle_set_manifest/2,
         assert_api_available/1,
         get_formatted_err_msg/1,
         handle_ensure_manifest/3]).

handle_get(Bucket, Req) ->
    assert_collections_enabled(),
    menelaus_util:reply_json(
      Req, collections:manifest_json(menelaus_auth:get_identity(Req),
                                     Bucket, direct)).

handle_post_scope(Bucket, Req) ->
    assert_api_available(Bucket),

    validator:handle(
      fun (Values) ->
              Name = proplists:get_value(name, Values),
              RV = collections:create_scope(Bucket, Name),
              maybe_audit(RV, Req, ns_audit:create_scope(_, Bucket, Name, _)),
              maybe_add_event_log(RV, Bucket, []),
              handle_rv(RV, Req)
      end, Req, form, scope_validators(default_not_allowed)).

maybe_audit({ok, {Uid, _}}, Req, SuccessfulAuditFun) ->
    SuccessfulAuditFun(Req, Uid);
maybe_audit({ok, Uid}, Req, SuccessfulAuditFun) ->
    SuccessfulAuditFun(Req, Uid);
maybe_audit(forbidden, Req, _SuccessfulAuditFun) ->
    ns_audit:auth_failure(Req);
maybe_audit(_, _Req, _SuccessfulAuditFun) ->
    ok.

%% Add event logs for a specific set of operations.
get_event_and_attributes({create_scope, Name, _}) ->
    {scope_created, [{scope, Name}]};
get_event_and_attributes({drop_scope, Name}) ->
    {scope_deleted, [{scope, Name}]};
get_event_and_attributes({create_collection, Scope, Collection, _}) ->
    {collection_created, [{scope, Scope},
                          {collection, Collection}]};
get_event_and_attributes({drop_collection, Scope, Collection}) ->
    {collection_deleted, [{scope, Scope},
                          {collection, Collection}]};
get_event_and_attributes(_) ->
    ok.

maybe_add_event_log({ok, {Uid, OperationsDone}}, Bucket, Extra) ->
    JsonifyFun = fun (K, V) when is_list(V) ->
                         {K, list_to_binary(V)};
                     (K, V) ->
                         {K, V}
                 end,
    lists:foreach(fun (Operation) ->
                          case get_event_and_attributes(Operation) of
                              {Event, Attributes} ->
                                  AttrsJson =
                                      [JsonifyFun(K, V) ||
                                       {K, V} <- Attributes],
                                  event_log:add_log(
                                    Event,
                                    [{bucket, list_to_binary(Bucket)}] ++
                                    AttrsJson ++ Extra ++
                                    [{new_manifest_id, Uid}]);
                              _ ->
                                  ok
                          end
                  end, OperationsDone);
maybe_add_event_log(_, _, _) ->
    ok.

scope_validators(default_not_allowed) ->
    scope_validators([]);
scope_validators(special_allowed) ->
    scope_validators(["_default", ?SYSTEM_SCOPE_NAME] ++
                     collections:system_collections());
scope_validators(Exceptions) ->
    [validator:required(name, _),
     validator:string(name, _),
     validator:length(name, 1, 251, _),
     name_validator(_),
     name_first_char_validator(_, Exceptions),
     validator:unsupported(_)].

bucket_has_config_validator(Name, BucketConfig, BucketKey, BucketValue, State) ->
    validator:validate(
        fun (Value) ->
            ConfiguredValue = proplists:get_value(BucketKey, BucketConfig),
            case ConfiguredValue of
                undefined ->
                    {error, io_lib:format("Bucket does not have ~s configured",
                                          [BucketKey])};
                ConfiguredValue when ConfiguredValue =:= BucketValue ->
                    {value, Value};
                ConfiguredValue ->
                    {error, io_lib:format("Bucket must have ~s=~s, not ~s",
                                          [BucketKey, BucketValue,
                                           ConfiguredValue])}
            end
        end, Name, State).

collection_modifiable_validators(BucketConfig) ->
    [validator:boolean(history, _),
     validator:valid_in_enterprise_only(history, _),
     validator:changeable_in_72_only(history, false, _),
     bucket_has_config_validator(history, BucketConfig, storage_mode, magma,
                                 _)].

collection_validators(DefaultAllowed, BucketConfig) ->
    [validator:integer(maxTTL, 0, ?MC_MAXINT, _),
     validator:changeable_in_enterprise_only(maxTTL, 0, _)] ++
     collection_modifiable_validators(BucketConfig) ++
     scope_validators(DefaultAllowed).

handle_post_collection(Bucket, Scope, Req) ->
    assert_api_available(Bucket),

    case ns_bucket:get_bucket(Bucket) of
        {ok, BucketConf} ->
            validator:handle(
                fun (Values) ->
                    Name = proplists:get_value(name, Values),
                    RV = collections:create_collection(
                        Bucket, Scope, Name, proplists:delete(name, Values)),
                    maybe_audit(RV, Req,
                        ns_audit:create_collection(_, Bucket, Scope, Name,
                            _)),
                    maybe_add_event_log(RV, Bucket, []),
                    handle_rv(RV, Req)
                end, Req, form,
                collection_validators(default_not_allowed, BucketConf));
        not_present ->
            handle_rv({bucket_not_found, Bucket}, Req)
    end.

handle_patch_collection(Bucket, Scope, Name, Req) ->
    assert_api_available(Bucket),
    case ns_bucket:get_bucket(Bucket) of
        {ok, BucketConf} ->
            validator:handle(
                fun (Values) ->
                    RV =  collections:modify_collection(
                        Bucket, Scope, Name, proplists:delete(name, Values)),
                    maybe_audit(RV, Req,
                                ns_audit:modify_collection(_, Bucket, Scope,
                                                           Name, _)),
                    maybe_add_event_log(RV, Bucket, []),
                    handle_rv(RV, Req)
                end, Req, form,
                collection_modifiable_validators(BucketConf) ++
                % Don't allow any other params
                [validator:unsupported(_)]);
        not_present ->
            handle_rv({bucket_not_found, Bucket}, Req)
    end.

handle_delete_scope(Bucket, Name, Req) ->
    assert_api_available(Bucket),
    RV = collections:drop_scope(Bucket, Name),
    maybe_audit(RV, Req, ns_audit:drop_scope(_, Bucket, Name, _)),
    maybe_add_event_log(RV, Bucket, []),
    handle_rv(RV, Req).

handle_delete_collection(Bucket, Scope, Name, Req) ->
    assert_api_available(Bucket),
    RV = collections:drop_collection(Bucket, Scope, Name),
    maybe_audit(RV, Req, ns_audit:drop_collection(_, Bucket, Scope, Name, _)),
    maybe_add_event_log(RV, Bucket, []),
    handle_rv(RV, Req).

handle_set_manifest(Bucket, Req) ->
    assert_api_available(Bucket),

    ValidOnUid = proplists:get_value("validOnUid",
                                     mochiweb_request:parse_qs(Req)),
    case ns_bucket:get_bucket(Bucket) of
        {ok, BucketConf} ->
            validator:handle(
                fun (KVList) ->
                    Scopes = proplists:get_value(scopes, KVList),
                    Identity = menelaus_auth:get_identity(Req),
                    RV = collections:set_manifest(Bucket, Identity, Scopes,
                                                  ValidOnUid),
                    InputManifest = mochiweb_request:recv_body(Req),
                    maybe_audit(RV, Req,
                                ns_audit:set_manifest(_, Bucket, InputManifest,
                                                      ValidOnUid, _)),
                    %% Add event logs for each of the specific operation performed.
                    maybe_add_event_log(RV, Bucket, []),
                    handle_rv(RV, Req)
                end, Req, json,
                [validator:required(scopes, _),
                 validate_scopes(scopes, BucketConf, _),
                 check_duplicates(scopes, _),
                 validator:unsupported(_)]);
        _ ->
            handle_rv({error,
                      io_lib:format("Could not get config for Bucket ~p",
                                    [Bucket])},
                      Req)
    end.

check_duplicates(Name, State) ->
    validator:validate(
      fun (JsonArray) ->
              Names = [proplists:get_value(name, Props) ||
                          {Props} <- JsonArray],
              case length(Names) =:= length(lists:usort(Names)) of
                  true ->
                      ok;
                  false ->
                      {error, "Contains duplicate name"}
              end
      end, Name, State).

validate_scopes(Name, BucketConfig, State) ->
    validator:json_array(
      Name, [validate_collections(collections, BucketConfig, _),
             check_duplicates(collections, _) |
             scope_validators(special_allowed)],
      State).

validate_collections(Name, BucketConfig, State) ->
    validator:json_array(Name,
                         collection_validators(special_allowed, BucketConfig),
                         State).

handle_ensure_manifest(Bucket, Uid, Req) ->
    assert_api_available(Bucket),
    UidInt = convert_uid(Uid),
    Snapshot = ns_bucket:get_snapshot(Bucket, [uuid, props]),
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket, Snapshot),

    BucketNodes = ns_bucket:live_bucket_nodes_from_config(BucketConfig),
    BucketUuid = ns_bucket:uuid(Bucket, Snapshot),

    validator:handle(
      fun (Values) ->
              Nodes = proplists:get_value(nodes, Values, BucketNodes),
              Timeout = proplists:get_value(timeout, Values, 30000),
              case collections:wait_for_manifest_uid(
                     Nodes, Bucket, BucketUuid, UidInt, Timeout) of
                  ok ->
                      menelaus_util:reply(Req, 200);
                  timeout ->
                      menelaus_util:reply_text(Req, "timeout", 504);
                  stopped ->
                      menelaus_util:reply_text(Req, "bucket no longer exists",
                                               404)
              end
      end, Req, form,
      [validator:integer(timeout, 0, 300000, _),
       nodes_validator(BucketNodes, Req, _),
       validator:unsupported(_)]).

assert_collections_enabled() ->
    case collections:enabled() of
        true ->
            ok;
        false ->
            menelaus_util:web_exception(
              400, "Not allowed until entire cluster is upgraded to 7.0")
    end.

assert_api_available(Bucket) ->
    assert_collections_enabled(),
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case collections:enabled(BucketConfig) of
        true ->
            ok;
        false ->
            menelaus_util:web_exception(
              400, "Not allowed on this type of bucket")
    end.

name_first_char_validator(State, Exceptions) ->
    validator:validate(
      fun ([Char | _] = Elem) ->
              case lists:member(Char, "_%") of
                  true ->
                      case lists:member(Elem, Exceptions) of
                          false ->
                              {error, "First character must not be _ or %"};
                          true ->
                              ok
                      end;
                  false ->
                      ok
              end
      end, name, State).

name_validator(State) ->
    validator:string(
      name, "^[0-9A-Za-z_%\-]+$", [dollar_endonly],
      "Can only contain characters A-Z, a-z, 0-9 and the following symbols "
      "_ - %", State).

convert_uid(Uid) ->
    try collections:convert_uid_from_memcached(Uid) of
        UidInt when UidInt < 0 ->
            menelaus_util:web_exception(400, "Invalid UID");
        UidInt ->
            UidInt
    catch error:badarg ->
            menelaus_util:web_exception(400, "Invalid UID")
    end.

nodes_validator(BucketNodes, Req, State) ->
    validator:validate(
      fun (NodesStr) ->
              Nodes = string:split(NodesStr, ",", all),
              {Good, Bad} =
                  lists:foldl(
                    fun (HostPort, {G, B}) ->
                            case menelaus_web_node:find_node_hostname(
                                   HostPort, Req) of
                                {error, _} ->
                                    {G, [HostPort | B]};
                                {ok, Node} ->
                                    case lists:member(Node, BucketNodes) of
                                        true ->
                                            {[Node | G], B};
                                        false ->
                                            {G, [HostPort | B]}
                                    end
                            end
                    end, {[], []}, Nodes),
              case Bad of
                  [] ->
                      {value, Good};
                  _ ->
                      {error, "Invalid nodes : " ++ string:join(Bad, ",")}
              end
      end, nodes, State).

get_err_code_msg(forbidden) ->
    {"Operation is not allowed due to insufficient permissions", 403};
get_err_code_msg(invalid_uid) ->
    {"Invalid validOnUid", 400};
get_err_code_msg(uid_mismatch) ->
    {"validOnUid doesn't match the current manifest Uid", 400};
get_err_code_msg({cannot_create_default_collection, ScopeName}) ->
    {"Cannot create _default collection in scope ~p. Creation of _default "
     "collection is not allowed.", [ScopeName], 400};
get_err_code_msg({cannot_create_collection_in_system_scope}) ->
    {"cannot create collection in '_system' scope", 400};
get_err_code_msg({cannot_drop_system_collection, Scope, Collection}) ->
    {"Cannot drop system collection ~p for scope ~p",
     [Collection, Scope], 400};
get_err_code_msg({cannot_modify_collection, Scope, Collection}) ->
    {"Cannot modify collection properties for Scope ~p Collection ~p",
     [Scope, Collection], 400};
get_err_code_msg({scope_already_exists, ScopeName}) ->
    {"Scope with name ~p already exists", [ScopeName], 400};
get_err_code_msg({collection_already_exists, ScopeName, CollectionName}) ->
    {"Collection with name ~p in scope ~p already exists",
     [CollectionName, ScopeName], 400};
get_err_code_msg({collection_not_found, ScopeName, CollectionName}) ->
    {"Collection with name ~p in scope ~p is not found",
     [CollectionName, ScopeName], 404};
get_err_code_msg({scope_not_found, ScopeName}) ->
    {"Scope with name ~p is not found", [ScopeName], 404};
get_err_code_msg(cannot_drop_default_scope) ->
    {"Deleting _default scope is not allowed", 400};
get_err_code_msg(cannot_drop_system_scope) ->
    {"Deleting _system scope is not allowed", 400};
get_err_code_msg({bucket_limit, max_number_exceeded, num_collections, Num}) ->
    {"Maximum number of collections (~p) for this bucket has been reached",
     [Num], 429};
get_err_code_msg({bucket_limit, max_number_exceeded, num_scopes, Num}) ->
    {"Maximum number of scopes (~p) for this bucket has been reached",
     [Num], 429};
get_err_code_msg({max_number_exceeded, num_scopes}) ->
    {"Maximum number of scopes has been reached", 400};
get_err_code_msg({max_number_exceeded, num_collections}) ->
    {"Maximum number of collections has been reached", 400};
get_err_code_msg(exceeded_retries) ->
    {"Exceeded retries due to conflicting operations on bucket properties.",
     503};
get_err_code_msg({nodes_are_behind, Nodes}) ->
    {"Operation is not possible due to following nodes being too far behind: "
     "~p.", [Nodes], 503};
get_err_code_msg(unfinished_failover) ->
    {"Operation is not possible during unfinished failover.", 503};
get_err_code_msg({bucket_not_found, Bucket}) ->
    {"Bucket with name ~p not found", [Bucket], 404};
get_err_code_msg(Error) ->
    {"Unknown error ~p", [Error], 400}.

get_formatted_err_msg(Error) ->
    case get_err_code_msg(Error) of
        {Msg, Code} -> {Msg, Code};
        {Msg, Params, Code} -> {io_lib:format(Msg, Params), Code}
    end.

handle_rv({ok, {Uid, _}}, Req) ->
    handle_rv({ok, Uid}, Req);
handle_rv({ok, Uid}, Req) ->
    menelaus_util:reply_json(Req, {[{uid, Uid}]}, 200);
handle_rv({errors, List}, Req) when is_list(List) ->
    Errors = lists:map(fun (Elem) ->
                               {Msg, _} = get_formatted_err_msg(Elem),
                               Msg
                       end, lists:usort(List)),
    menelaus_util:reply_json(Req, {[{errors, Errors}]}, 400);
handle_rv(Error, Req) ->
    {Msg, Code} = get_formatted_err_msg(Error),
    reply_global_error(Req, Msg, Code).

reply_global_error(Req, Msg, Code) ->
    menelaus_util:reply_json(
      Req, {[{errors, {[{<<"_">>, iolist_to_binary(Msg)}]}}]}, Code).

-ifdef(TEST).
bucket_has_config_validator_test() ->
    Args = [{"test", ok}],

    {error, [{"test", ErrorEmpty}]} =
        validator:handle_proplist(Args,
                                  [bucket_has_config_validator(test,
                                                               [],
                                                               storage_mode,
                                                               magma,
                                                               _)]),
    ?assertEqual("Bucket does not have storage_mode configured", ErrorEmpty),

    BucketConfCouchstore = [{storage_mode, couchstore}],
    {error, [{"test", ErrorIncorrect}]} =
        validator:handle_proplist(
            Args,
            [bucket_has_config_validator(test, BucketConfCouchstore,
                                         storage_mode, magma, _)]),
    ?assertEqual("Bucket must have storage_mode=magma, not couchstore",
                 ErrorIncorrect),

    BucketConfMagma = [{storage_mode, magma}],
    {ok, _} =
        validator:handle_proplist(Args,
                                  [bucket_has_config_validator(test,
                                                               BucketConfMagma,
                                                               storage_mode,
                                                               magma,
                                                               _)]).

bucket_config_not_found_when_posting_collections_test() ->
    meck:new(collections, [passthrough]),
    meck:expect(collections, enabled, fun() -> true end),
    meck:expect(collections, enabled, fun(_) -> true end),

    % We need to pass the first get_bucket call and fail the second, we can use
    % meck:seq to specify a sequence of return values
    meck:new(ns_bucket),
    meck:expect(ns_bucket, get_bucket, 1, meck:seq([{ok, []}, not_present])),

    meck:new(menelaus_auth),
    meck:expect(menelaus_auth, get_identity, fun (_) -> ok end),

    % Matching the function clause in the expect here is the test
    meck:new(menelaus_util),
    meck:expect(menelaus_util,
                reply_json,
                fun (_,
                     {[{errors, {[{<<"_">>,
                                   <<"Bucket with name [] not found">>}]}}]},
                     404) -> ok
                end),

    % Values passed in here don't matter, we're mocking everything we need
    handle_post_collection([],[],[]),

    meck:unload(menelaus_util),
    meck:unload(menelaus_auth),
    meck:unload(ns_bucket),
    meck:unload(collections).
-endif.
