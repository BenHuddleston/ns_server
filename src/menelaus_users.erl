%% @author Couchbase <info@couchbase.com>
%% @copyright 2016-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc implementation of local and external users

-module(menelaus_users).

-include("ns_common.hrl").
-include("ns_config.hrl").
-include("rbac.hrl").
-include("pipes.hrl").
-include("cut.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
%% User management:
         store_user/6,
         store_users/1,
         delete_user/1,
         select_users/1,
         select_users/2,
         select_auth_infos/1,
         user_exists/1,
         get_roles/1,
         get_user_name/1,
         get_limits_version/0,
         get_users_version/0,
         get_auth_version/0,
         get_auth_info/1,
         get_user_props/1,
         get_user_props/2,
         get_user_limits/1,
         get_user_uuid/1,
         change_password/2,

%% Group management:
         store_group/4,
         delete_group/1,
         select_groups/1,
         select_groups/2,
         get_group_roles/1,
         has_group_ldap_ref/1,
         is_empty_ldap_group_ref/1,
         get_group_props/1,
         group_exists/1,
         get_groups_version/0,

%% UI Profiles
         get_profile/1,
         store_profile/2,
         delete_profile/1,
         select_profiles/0,

%% Actions:
         authenticate/2,
         authenticate_with_info/2,
         build_auth/1,
         format_plain_auth/1,
         empty_storage/0,
         cleanup_bucket_roles/1,
         get_passwordless/0,
         get_salt_and_mac/1,

%% Backward compatibility:
         upgrade/3,
         config_upgrade/0,
         upgrade_in_progress/0,
         upgrade_in_progress/1,
         upgrade_props/4
        ]).

%% callbacks for replicated_dets
-export([init/1, on_save/2, on_empty/1, handle_call/4, handle_info/2]).

-export([start_storage/0, start_replicator/0, start_auth_cache/0]).

%% RPC'd from ns_couchdb node
-export([get_auth_info_on_ns_server/1]).

-define(MAX_USERS_ON_CE, 20).
-define(LDAP_GROUPS_CACHE_SIZE, 1000).
-define(DEFAULT_PROPS, [name, uuid, user_roles, group_roles, passwordless,
                        password_change_timestamp, groups, external_groups]).
-define(DEFAULT_GROUP_PROPS, [description, roles, ldap_group_ref]).

-record(state, {base, passwordless}).

replicator_name() ->
    users_replicator.

storage_name() ->
    users_storage.

versions_name() ->
    menelaus_users_versions.

auth_cache_name() ->
    menelaus_users_cache.

start_storage() ->
    Replicator = erlang:whereis(replicator_name()),
    Path = filename:join(path_config:component_path(data, "config"), "users.dets"),
    replicated_dets:start_link(?MODULE, [], storage_name(), Path, Replicator).

get_users_version() ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            [{user_version, V, Base}] = ets:lookup(versions_name(), user_version),
            {V, Base};
        true ->
            rpc:call(ns_node_disco:ns_server_node(), ?MODULE, get_users_version, [])
    end.

get_groups_version() ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            [{group_version, V, Base}] = ets:lookup(versions_name(),
                                                    group_version),
            {V, Base};
        true ->
            rpc:call(ns_node_disco:ns_server_node(), ?MODULE,
                     get_groups_version, [])
    end.

get_auth_version() ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            [{auth_version, V, Base}] = ets:lookup(versions_name(), auth_version),
            {V, Base};
        true ->
            rpc:call(ns_node_disco:ns_server_node(), ?MODULE, get_auth_version, [])
    end.

get_limits_version() ->
    [{limits_version, V, Base}] = ets:lookup(versions_name(), limits_version),
    {V, Base}.

start_replicator() ->
    GetRemoteNodes =
        fun () ->
                ns_node_disco:nodes_actual_other()
        end,
    doc_replicator:start_link(replicator_name(), GetRemoteNodes,
                              storage_name()).

start_auth_cache() ->
    versioned_cache:start_link(
      auth_cache_name(), 200,
      fun (I) ->
              ?log_debug("Retrieve user ~p from ns_server node",
                         [ns_config_log:tag_user_data(I)]),
              rpc:call(ns_node_disco:ns_server_node(), ?MODULE, get_auth_info_on_ns_server, [I])
      end,
      fun () ->
              dist_manager:wait_for_node(fun ns_node_disco:ns_server_node/0),
              [{{user_storage_events, ns_node_disco:ns_server_node()}, fun (_) -> true end}]
      end,
      fun () ->
              {get_auth_version(), get_users_version(), get_groups_version()}
      end).

empty_storage() ->
    replicated_dets:empty(storage_name()).

get_passwordless() ->
    gen_server:call(storage_name(), get_passwordless, infinity).

init([]) ->
    _ = ets:new(versions_name(), [protected, named_table]),
    mru_cache:new(ldap_groups_cache, ?LDAP_GROUPS_CACHE_SIZE),
    #state{base = init_versions()}.

init_versions() ->
    Base = misc:rand_uniform(0, 16#100000000),
    Versions =
        [{V, 0, Base} ||
            V <- [user_version, group_version, auth_version, limits_version]],
    ets:insert_new(versions_name(), Versions),
    [gen_event:notify(user_storage_events, {V, {0, Base}}) ||
        {V, _, _} <- Versions],
    Base.

on_save(Docs, State) ->
    ProcessDoc =
        fun ({group, _}, _Doc, S) ->
                {{change_version, group_version}, S};
            ({limits, _}, _Doc, S) ->
                {{change_version, limits_version}, S};
            ({user, _}, _Doc, S) ->
                {{change_version, user_version}, S};
            ({auth, Identity}, Doc, S) ->
                {{change_version, auth_version},
                 maybe_update_passwordless(
                   Identity,
                   replicated_dets:get_value(Doc),
                   replicated_dets:is_deleted(Doc),
                   S)};
            (_, _, S) ->
                {undefined, S}
        end,

    {MessagesToSend, NewState} =
        lists:foldl(
          fun (Doc, {MessagesAcc, StateAcc}) ->
                  {Message, NewState} =
                      ProcessDoc(replicated_dets:get_id(Doc), Doc, StateAcc),
                  {sets:add_element(Message, MessagesAcc), NewState}
          end, {sets:new(), State}, Docs),
    case sets:is_element({change_version, group_version}, MessagesToSend) of
        true -> mru_cache:flush(ldap_groups_cache);
        false -> ok
    end,
    [self() ! Msg || Msg <- sets:to_list(MessagesToSend), Msg =/= undefined],
    NewState.

handle_info({change_version, Key} = Msg, #state{base = Base} = State) ->
    misc:flush(Msg),
    Ver = ets:update_counter(versions_name(), Key, 1),
    gen_event:notify(user_storage_events, {Key, {Ver, Base}}),
    {noreply, State}.

on_empty(State) ->
    true = ets:delete_all_objects(versions_name()),
    {noreply, State}.

maybe_update_passwordless(_Identity, _Value, _Deleted, State = #state{passwordless = undefined}) ->
    State;
maybe_update_passwordless(Identity, _Value, true, State = #state{passwordless = Passwordless}) ->
    State#state{passwordless = lists:delete(Identity, Passwordless)};
maybe_update_passwordless(Identity, Auth, false, State = #state{passwordless = Passwordless}) ->
    NewPasswordless =
        case authenticate_with_info(Auth, "") of
            true ->
                case lists:member(Identity, Passwordless) of
                    true ->
                        Passwordless;
                    false ->
                        [Identity | Passwordless]
                end;
            false ->
                lists:delete(Identity, Passwordless)
        end,
    State#state{passwordless = NewPasswordless}.

handle_call(get_passwordless, _From, TableName, #state{passwordless = undefined} = State) ->
    Passwordless =
        pipes:run(
          replicated_dets:select(TableName, {auth, '_'}, 100),
          ?make_consumer(
             pipes:fold(?producer(),
                        fun ({{auth, Identity}, Auth}, Acc) ->
                                case authenticate_with_info(Auth, "") of
                                    true ->
                                        [Identity | Acc];
                                    false ->
                                        Acc
                                end
                        end, []))),
    {reply, Passwordless, State#state{passwordless = Passwordless}};
handle_call(get_passwordless, _From, _TableName, #state{passwordless = Passwordless} = State) ->
    {reply, Passwordless, State}.

select_users(KeySpec) ->
    select_users(KeySpec, ?DEFAULT_PROPS).

select_users(KeySpec, ItemList) ->
    pipes:compose([replicated_dets:select(storage_name(), {user, KeySpec}, 100),
                   make_props_transducer(ItemList)]).

make_props_transducer(ItemList) ->
    PropsState = make_props_state(ItemList),
    pipes:map(fun ({{user, Id}, Props}) ->
                      {{user, Id}, make_props(Id, Props, ItemList, PropsState)}
              end).

make_props(Id, Props, ItemList) ->
    make_props(Id, Props, ItemList, make_props_state(ItemList)).

make_props(Id, Props, ItemList, {Passwordless, Definitions,
                                 Snapshot}) ->

    %% Groups calculation might be heavy, so we want to make sure they
    %% are calculated only once
    GetDirtyGroups = fun (#{dirty_groups := Groups} = Cache) ->
                             {Groups, Cache};
                         (Cache) ->
                             Groups = get_dirty_groups(Id, Props),
                             {Groups, Cache#{dirty_groups => Groups}}
                     end,

    GetGroups = fun (#{groups := Groups} = Cache) ->
                        {Groups, Cache};
                    (Cache) ->
                        {DirtyGroups, NewCache} = GetDirtyGroups(Cache),
                        Groups = clean_groups(DirtyGroups),
                        {Groups, NewCache#{groups => Groups}}
                end,

    EvalProp =
      fun (password_change_timestamp, Cache) ->
              {replicated_dets:get_last_modified(
                 storage_name(), {auth, Id}, undefined), Cache};
          (group_roles, Cache) ->
              {Groups, NewCache} = GetGroups(Cache),
              Roles = get_groups_roles(Groups, Definitions, Snapshot),
              {Roles, NewCache};
          (user_roles, Cache) ->
              UserRoles = get_user_roles(Props, Definitions, Snapshot),
              {UserRoles, Cache};
          (roles, Cache) ->
              {DirtyGroups, NewCache} = GetDirtyGroups(Cache),
              UserRoles = get_user_roles(Props, Definitions, Snapshot),
              GroupsAndRoles = get_groups_roles(DirtyGroups, Definitions,
                                                Snapshot),
              GroupRoles = lists:concat([R || {_, R} <- GroupsAndRoles]),
              {lists:usort(UserRoles ++ GroupRoles), NewCache};
          (passwordless, Cache) ->
              {lists:member(Id, Passwordless), Cache};
          (groups, Cache) ->
              {{Groups, _}, NewCache} = GetGroups(Cache),
              {Groups, NewCache};
          (external_groups, Cache) ->
              {{_, ExtGroups}, NewCache} = GetGroups(Cache),
              {ExtGroups, NewCache};
          (dirty_groups, Cache) ->
              {DirtyGroups, NewCache} = GetDirtyGroups(Cache),
              {DirtyGroups, NewCache};
          (Name, Cache) ->
              {proplists:get_value(Name, Props), Cache}
        end,

    {Res, _} = lists:mapfoldl(
                   fun (Key, Cache) ->
                           {Value, NewCache} = EvalProp(Key, Cache),
                           {{Key, Value}, NewCache}
                   end, #{}, ItemList),
    Res.

make_props_state(ItemList) ->
    Passwordless = lists:member(passwordless, ItemList) andalso
                       get_passwordless(),
    {Definitions, Snapshot} =
        case lists:member(roles, ItemList) orelse
             lists:member(user_roles, ItemList) orelse
             lists:member(group_roles, ItemList) of
            true -> {menelaus_roles:get_definitions(public),
                     ns_bucket:get_snapshot(all, [collections, uuid])};
            false -> {undefined, undefined}
        end,
    {Passwordless, Definitions, Snapshot}.

select_auth_infos(KeySpec) ->
    replicated_dets:select(storage_name(), {auth, KeySpec}, 100).

build_auth(false, undefined) ->
    password_required;
build_auth(false, Password) ->
    build_auth([Password]);
build_auth({_, _}, undefined) ->
    same;
build_auth({_, CurrentAuth}, Password) ->
    case authenticate_with_info(CurrentAuth, Password) of
        true ->
            case has_scram_hashes(CurrentAuth) of
                false ->
                    build_auth([Password]);
                _ ->
                    same
            end;
        false ->
            build_auth([Password])
    end.

-spec store_user(rbac_identity(), rbac_user_name(),
                 {password, rbac_password()} | {auth, rbac_auth()},
                 [rbac_role()], [rbac_group_id()],
                 [{atom(), [{atom(), term()}]}]) ->
    ok | {error, {roles_validation, _}} |
    {error, password_required} | {error, too_many}.
store_user(Identity, Name, PasswordOrAuth, Roles,
           Groups, Limits) ->
    Props = [{name, Name} || Name =/= undefined] ++
            [{groups, Groups} || Groups =/= undefined] ++
            [{pass_or_auth, PasswordOrAuth},
             {roles, Roles},
             {limits, Limits}],
    store_users([{Identity, Props}]).

store_users(Users) ->
    Snapshot = ns_bucket:get_snapshot(all, [collections, uuid]),
    case prepare_store_users_docs(Snapshot, Users) of
        {ok, PreparedDocs} ->
            ok = replicated_dets:change_multiple(storage_name(), PreparedDocs);
        {error, _} = Error ->
            Error
    end.

prepare_store_users_docs(Snapshot, Users) ->
    try
        {ok, lists:flatmap(prepare_store_user(Snapshot, _), Users)}
    catch
        throw:{error, _} = Error -> Error
    end.

prepare_store_user(Snapshot, {{_, Domain} = Identity, Props}) ->
    UUID = get_user_uuid(Identity, misc:uuid_v4()),
    Name = proplists:get_value(name, Props),
    Groups = proplists:get_value(groups, Props),
    PasswordOrAuth = proplists:get_value(pass_or_auth, Props),
    Roles = proplists:get_value(roles, Props),
    Limits = proplists:get_value(limits, Props),

    UserProps = [{name, Name} || Name =/= undefined] ++
                [{uuid, UUID} || UUID =/= undefined] ++
                [{groups, Groups} || Groups =/= undefined],

    UserProps2 =
        case menelaus_roles:validate_roles(Roles, Snapshot) of
            {NewRoles, []} -> [{roles, NewRoles} | UserProps];
            {_, BadRoles} -> throw({error, {roles_validation, BadRoles}})
        end,

    case check_limit(Identity) of
        true -> ok;
        false -> throw({error, too_many})
    end,

    Auth =
        case {Domain, PasswordOrAuth} of
            {external, _} -> same;
            {local, {password, Password}} ->
                CurrentAuth = replicated_dets:get(storage_name(),
                                                  {auth, Identity}),
                case build_auth(CurrentAuth, Password) of
                    password_required -> throw({error, password_required});
                    A -> A
                end;
            {local, {auth, A}} -> A
        end,

    store_user_changes(Identity, UserProps2, Auth, Limits).

count_users() ->
    pipes:run(select_users('_', []),
              ?make_consumer(
                 pipes:fold(?producer(),
                            fun (_, Acc) ->
                                    Acc + 1
                            end, 0))).

check_limit(Identity) ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            true;
        false ->
            case count_users() >= ?MAX_USERS_ON_CE of
                true ->
                    user_exists(Identity);
                false ->
                    true
            end
    end.

store_user_changes(Identity, Props, Auth, Limits) ->
    case replicated_dets:get(storage_name(), {user, Identity}) of
        false ->
            [{delete, {limits, Identity}},
             {delete, profile_key(Identity)}];
        _ ->
            []
    end ++
    [{set, {user, Identity}, Props}] ++
    [{set, {auth, Identity}, Auth} || Auth /= same] ++
    apply_limits_changes(Identity, Limits).

apply_limits_changes(_Identity, undefined) ->
    [];
apply_limits_changes(Identity, []) ->
    [{delete, {limits, Identity}}];
apply_limits_changes(Identity, Limits) ->
    Sorted = lists:usort([{S, lists:usort(L)} || {S, L} <- Limits]),
    CurLimits = get_user_limits(Identity),
    case CurLimits =:= Sorted of
        true ->
            [];
        false ->
            [{set, {limits, Identity}, Sorted}]
    end.

store_auth(_Identity, same) ->
    unchanged;
store_auth(Identity, Auth) when is_list(Auth) ->
    ok = replicated_dets:set(storage_name(), {auth, Identity}, Auth).

change_password({_UserName, local} = Identity, Password) when is_list(Password) ->
    case replicated_dets:get(storage_name(), {user, Identity}) of
        false ->
            user_not_found;
        _ ->
            CurrentAuth = replicated_dets:get(storage_name(), {auth, Identity}),
            Auth = build_auth(CurrentAuth, Password),
            store_auth(Identity, Auth)
    end.

-spec delete_user(rbac_identity()) -> {commit, ok} |
                                      {abort, {error, not_found}}.
delete_user({_, Domain} = Identity) ->
    case Domain of
        local ->
            _ = replicated_dets:delete(storage_name(), {limits, Identity}),
            _ = replicated_dets:delete(storage_name(), {auth, Identity}),
            _ = delete_profile(Identity);
        external ->
            ok
    end,
    case replicated_dets:delete(storage_name(), {user, Identity}) of
        {not_found, _} ->
            {abort, {error, not_found}};
        ok ->
            {commit, ok}
    end.

get_salt_and_mac(Auth) ->
    case proplists:get_value(<<"hash">>, Auth) of
        undefined -> obsolete_get_salt_and_mac(Auth);
        {Props} -> Props
    end.

obsolete_get_salt_and_mac(Auth) ->
    SaltAndMacBase64 = binary_to_list(proplists:get_value(<<"plain">>, Auth)),
    <<Salt:16/binary, Mac:20/binary>> = base64:decode(SaltAndMacBase64),
    [{?HASH_ALG_KEY, ?SHA1_HASH},
     {?SALT_KEY, base64:encode(Salt)},
     {?HASHES_KEY, [base64:encode(Mac)]}].

has_scram_hashes(Auth) ->
    proplists:is_defined(<<"sha1">>, Auth).

-spec authenticate(rbac_user_id(), rbac_password()) -> boolean().
authenticate(Username, Password) ->
    Identity = {Username, local},
    case get_auth_info(Identity) of
        false ->
            false;
        Auth ->
            authenticate_with_info(Auth, Password)
    end.

get_auth_info(Identity) ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            get_auth_info_on_ns_server(Identity);
        true ->
            versioned_cache:get(auth_cache_name(), Identity)
    end.

get_auth_info_on_ns_server(Identity) ->
    case replicated_dets:get(storage_name(), {user, Identity}) of
        false ->
            false;
        _ ->
            case replicated_dets:get(storage_name(), {auth, Identity}) of
                false ->
                    false;
                {_, Auth} ->
                    Auth
            end
    end.

-spec authenticate_with_info(list(), rbac_password()) -> boolean().
authenticate_with_info(Auth, Password) ->
    ns_config_auth:check_hash(get_salt_and_mac(Auth), Password).

get_user_props(Identity) ->
    get_user_props(Identity, ?DEFAULT_PROPS).

get_user_props(Identity, ItemList) ->
    make_props(Identity, get_props_raw(user, Identity), ItemList).

get_props_raw(Type, Identity) when Type == user; Type == group; Type == auth ->
    replicated_dets:get(storage_name(), {Type, Identity}, []).

-spec user_exists(rbac_identity()) -> boolean().
user_exists(Identity) ->
    false =/= replicated_dets:get(storage_name(), {user, Identity}).

-spec get_roles(rbac_identity()) -> [rbac_role()].
get_roles(Identity) ->
    proplists:get_value(roles, get_user_props(Identity, [roles]), []).

%% Groups functions

store_group(Identity, Description, Roles, LDAPGroup) ->
    Snapshot = ns_bucket:get_snapshot(all, [collections, uuid]),
    case menelaus_roles:validate_roles(Roles, Snapshot) of
        {NewRoles, []} ->
            Props = [{description, Description} || Description =/= undefined] ++
                    [{ldap_group_ref, LDAPGroup} || LDAPGroup =/= undefined] ++
                    [{roles, NewRoles}],
            ok = replicated_dets:set(storage_name(), {group, Identity}, Props),
            ok;
        {_, BadRoles} ->
            {error, {roles_validation, BadRoles}}
    end.

delete_group(GroupId) ->
    UpdateFun =
        fun ({user, Key}, Props) ->
                Groups = proplists:get_value(groups, Props, []),
                case lists:member(GroupId, Groups) of
                    true ->
                        NewProps = misc:key_update(groups, Props,
                                                   lists:delete(GroupId, _)),
                        ?log_debug("Updating user ~p groups: ~p -> ~p",
                                   [ns_config_log:tag_user_data(Key),
                                    Props, NewProps]),
                        {update, NewProps};
                    false ->
                        skip
                end
        end,

    case replicated_dets:select_with_update(storage_name(), {user, '_'},
                                            100, UpdateFun) of
        [] -> ok;
        Error -> ?log_warning("Failed to remove users from group: ~p", [Error])
    end,
    case replicated_dets:delete(storage_name(), {group, GroupId}) of
        ok -> ok;
        {not_found, _} -> {error, not_found}
    end.

select_groups(KeySpec) ->
    select_groups(KeySpec, ?DEFAULT_GROUP_PROPS).

select_groups(KeySpec, Items) ->
    pipes:compose(
        [replicated_dets:select(storage_name(), {group, KeySpec}, 100),
         make_group_props_transducer(Items)]).

make_group_props_transducer(Items) ->
    PropsState = make_props_state(Items),
    pipes:map(fun ({Id, Props}) ->
                      {Id, make_group_props(Props, Items, PropsState)}
              end).

get_group_props(GroupId) ->
    get_group_props(GroupId, ?DEFAULT_GROUP_PROPS).

get_group_props(GroupId, Items) ->
    Props = get_props_raw(group, GroupId),
    make_group_props(Props, Items).

get_group_props(GroupId, Items, Definitions, Buckets) ->
    Props = get_props_raw(group, GroupId),
    make_group_props(Props, Items, {[], Definitions, Buckets}).

group_exists(GroupId) ->
    false =/= replicated_dets:get(storage_name(), {group, GroupId}).

get_group_ldap_ref(GroupId) ->
    proplists:get_value(ldap_group_ref,
                        get_group_props(GroupId, [ldap_group_ref])).

has_group_ldap_ref(GroupId) ->
    not is_empty_ldap_group_ref(get_group_ldap_ref(GroupId)).

%% Unfortunately we allow ldap_group_ref as "".
is_empty_ldap_group_ref(Ref) ->
    undefined =:= Ref orelse [] =:= Ref.

get_group_roles(GroupId) ->
    proplists:get_value(roles, get_group_props(GroupId, [roles]), []).

get_group_roles(GroupId, Definitions, Snapshot) ->
    Props = get_group_props(GroupId, [roles], Definitions, Snapshot),
    proplists:get_value(roles, Props, []).

make_group_props(Props, Items) ->
    make_group_props(Props, Items, make_props_state(Items)).

make_group_props(Props, Items, {_, Definitions, Snapshot}) ->
    lists:map(
      fun (roles = Name) ->
              Roles = proplists:get_value(roles, Props, []),
              Roles2 = menelaus_roles:filter_out_invalid_roles(
                         Roles, Definitions, Snapshot),
              {Name, Roles2};
          (Name) ->
              {Name, proplists:get_value(Name, Props)}
      end, Items).

get_user_roles(UserProps, Definitions, Snapshot) ->
    menelaus_roles:filter_out_invalid_roles(
      proplists:get_value(roles, UserProps, []), Definitions, Snapshot).

clean_groups({DirtyLocalGroups, DirtyExtGroups}) ->
    {lists:filter(group_exists(_), DirtyLocalGroups),
     lists:filter(group_exists(_), DirtyExtGroups)}.

get_dirty_groups(Id, Props) ->
    LocalGroups = proplists:get_value(groups, Props, []),
    ExternalGroups =
        case Id of
            {_, local} -> [];
            {User, external} ->
                case ldap_util:get_setting(authorization_enabled) of
                    true -> get_ldap_groups(User);
                    false -> []
                end
        end,
    {LocalGroups, ExternalGroups}.

get_groups_roles({LocalGroups, ExtGroups}, Definitions, Snapshot) ->
    [{G, get_group_roles(G, Definitions, Snapshot)}
        || G <- LocalGroups ++ ExtGroups].

get_ldap_groups(User) ->
    try ldap_auth_cache:user_groups(User) of
        LDAPGroups ->
            GroupsMap =
                lists:foldl(
                  fun (LDAPGroup, Acc) ->
                          Groups = get_groups_by_ldap_group(LDAPGroup),
                          lists:foldl(?cut(_2#{_1 => true}), Acc, Groups)
                  end, #{}, LDAPGroups),
            maps:keys(GroupsMap)
    catch
        error:Error ->
            ?log_error("Failed to get ldap groups for ~p: ~p",
                       [ns_config_log:tag_user_name(User), Error]),
            []
    end.

get_groups_by_ldap_group(LDAPGroup) ->
    case mru_cache:lookup(ldap_groups_cache, LDAPGroup) of
        {ok, Value} -> Value;
        false ->
            GroupFilter =
                fun ({_, Props}) ->
                        LDAPGroup == proplists:get_value(ldap_group_ref, Props)
                end,
            Groups = pipes:run(select_groups('_', [ldap_group_ref]),
                               [pipes:filter(GroupFilter),
                                pipes:map(fun ({{group, G}, _}) -> G end)],
                               pipes:collect()),
            mru_cache:add(ldap_groups_cache, LDAPGroup, Groups),
            Groups
    end.

%% ui profiles

profile_key(Identity) ->
    {ui_profile, Identity}.

get_profile(Identity) ->
    replicated_dets:get(storage_name(), profile_key(Identity), undefined).

store_profile(Identity, Json) ->
    ok = replicated_dets:set(storage_name(), profile_key(Identity), Json).

delete_profile(Identity) ->
    case replicated_dets:delete(storage_name(), profile_key(Identity)) of
        ok -> ok;
        {not_found, _} -> {error, not_found}
    end.

select_profiles() ->
    replicated_dets:select(storage_name(), profile_key('_'), 100).

-spec get_user_name(rbac_identity()) -> rbac_user_name().
get_user_name({_, Domain} = Identity) when Domain =:= local orelse Domain =:= external ->
    proplists:get_value(name, get_user_props(Identity, [name]));
get_user_name(_) ->
    undefined.

get_user_limits(Identity) ->
    case replicated_dets:get(storage_name(), {limits, Identity}) of
        false ->
            undefined;
        {_, Limits} ->
            Limits
    end.

-spec get_user_uuid(rbac_identity()) -> binary() | undefined.
get_user_uuid(Identity) ->
    get_user_uuid(Identity, undefined).

-spec get_user_uuid(rbac_identity(), binary() | undefined) -> binary() |
                                                              undefined.
get_user_uuid({_, local} = Identity, Default) ->
    proplists:get_value(uuid, get_props_raw(user, Identity), Default);
get_user_uuid(_, _) ->
    undefined.

build_auth(Passwords) ->
    build_plain_auth(Passwords) ++ scram_sha:build_auth(Passwords).

build_plain_auth(Passwords) ->
    case cluster_compat_mode:is_cluster_elixir() of
        true ->
            HashType = ns_config:read_key_fast(password_hash_alg,
                                               ?DEFAULT_PWHASH),
            format_plain_auth(ns_config_auth:new_password_hash(HashType,
                                                               Passwords));
        false ->
            format_pre_elixir_plain_auth(
              ns_config_auth:new_password_hash(?SHA1_HASH, Passwords))
    end.

format_plain_auth(HashInfo) ->
    [{<<"hash">>, {HashInfo}}].

format_pre_elixir_plain_auth(HashInfo) ->
    Salt = base64:decode(proplists:get_value(?SALT_KEY, HashInfo)),
    [Hash | _] = proplists:get_value(?HASHES_KEY, HashInfo),
    Mac = base64:decode(Hash),
    SaltAndMac = <<Salt/binary, Mac/binary>>,
    [{<<"plain">>, base64:encode(SaltAndMac)}].

rbac_upgrade_key(_) ->
    rbac_upgrade_key().

rbac_upgrade_key() ->
    rbac_upgrade.

config_upgrade() ->
    [{delete, rbac_upgrade_key()}].

upgrade_in_progress() ->
    upgrade_in_progress(ns_config:latest()).

upgrade_in_progress(Config) ->
    ns_config:search(Config, rbac_upgrade_key()) =/= false.

filter_out_invalid_roles(Props, Definitions, Snapshot) ->
    Roles = proplists:get_value(roles, Props, []),
    FilteredRoles = menelaus_roles:filter_out_invalid_roles(Roles, Definitions,
                                                            Snapshot),
    lists:keystore(roles, 1, Props, {roles, FilteredRoles}).

cleanup_bucket_roles(BucketName) ->
    ?log_debug("Delete all roles for bucket ~p", [BucketName]),
    Snapshot = ns_bucket:remove_from_snapshot(
                 BucketName, ns_bucket:get_snapshot(all, [collections, uuid])),

    Definitions = menelaus_roles:get_definitions(all),
    UpdateFun =
        fun ({Type, Key}, Props) when Type == user; Type == group ->
                case filter_out_invalid_roles(Props, Definitions, Snapshot) of
                    Props ->
                        skip;
                    NewProps ->
                        ?log_debug("Changing properties of ~p ~p from ~p "
                                   "to ~p due to deletion of ~p",
                                   [Type, ns_config_log:tag_user_data(Key),
                                    Props, NewProps, BucketName]),
                        {update, NewProps}
                end
        end,

    UpdateRecords = replicated_dets:select_with_update(storage_name(), _, 100,
                                                       UpdateFun),

    case {UpdateRecords({user, '_'}), UpdateRecords({group, '_'})} of
        {[], []} -> ok;
        {UserErrors, GroupErrors} ->
            ?log_warning("Failed to cleanup some roles: ~p ~p",
                         [UserErrors, GroupErrors]),
            ok
    end.

sync_with_remotes(Nodes, Version) ->
    replicated_storage:sync_to_me(
      storage_name(), Nodes, ?get_timeout(rbac_upgrade_key(Version), 60000)).

upgrade(Version, Config, Nodes) ->
    try
        ?log_info("Upgrading users database to ~p", [Version]),
        Key = rbac_upgrade_key(Version),
        case ns_config:search(Config, Key) of
            false ->
                ns_config:set(Key, started);
            {value, started} ->
                ?log_info("Found unfinished roles upgrade. Continue.")
        end,

        %% propagate upgrade key to nodes
        ok = ns_config_rep:ensure_config_seen_by_nodes(Nodes),
        sync_with_remotes(Nodes, Version),

        do_upgrade(Version),
        ?log_info("Users database was upgraded to ~p", [Version]),
        sync_with_remotes(Nodes, Version),
        ?log_info("Users database upgrade was delivered to ~p", [Nodes]),
        ok
    catch T:E:S ->
            ale:error(?USER_LOGGER, "Unsuccessful user storage upgrade.~n~p",
                      [{T, E, S}]),
            error
    end.

maybe_upgrade_role_to_70({RoleName, Buckets}) ->
    Length = length(menelaus_roles:get_param_defs(
                      RoleName, menelaus_roles:get_public_definitions(
                                  ?VERSION_70))),
    [{RoleName, misc:align_list(Buckets, Length, any)}];
maybe_upgrade_role_to_70(security_admin) ->
    [security_admin_local, security_admin_external];
maybe_upgrade_role_to_70(Role) ->
    [Role].

upgrade_props(?VERSION_66, user, _Key, Props) ->
    %% remove junk user_roles property that might appear due to MB-39706
    {ok, lists:keydelete(user_roles, 1, Props)};
upgrade_props(?VERSION_70, RecType, _Key, Props) when RecType == user;
                                                      RecType == group ->
    {ok, upgrade_roles(fun maybe_upgrade_role_to_70/1, Props)};
upgrade_props(?VERSION_71, user, Key, Props) ->
    {ok, add_uuid(Key, Props)};
upgrade_props(?VERSION_ELIXIR, auth, _Key, AuthProps) ->
    {ok, functools:chain(AuthProps,
                         [scram_sha:fix_pre_elixir_auth_info(_),
                          get_rid_of_plain_key(_)])};
upgrade_props(_Vsn, _RecType, _Key, _Props) ->
    skip.

add_uuid({_, local}, Props) ->
    lists:keystore(uuid, 1, Props, {uuid, misc:uuid_v4()});
add_uuid(_, Props) ->
    Props.

get_rid_of_plain_key(Auth) ->
    lists:map(
      fun ({<<"plain">>, _}) ->
              {<<"hash">>, {obsolete_get_salt_and_mac(Auth)}};
          (Other) ->
              Other
      end, Auth).

upgrade_roles(Fun, Props) ->
    OldRoles = lists:sort(proplists:get_value(roles, Props)),
    %% Convert roles and remove duplicates.
    case lists:usort(lists:flatmap(Fun, OldRoles)) of
        OldRoles ->
            Props;
        NewRoles ->
            lists:keyreplace(roles, 1, Props, {roles, NewRoles})
    end.

do_upgrade(Version) ->
    UpdateFun =
        fun ({RecType, Key}, Props) ->
                case upgrade_props(Version, RecType, Key, Props) of
                    skip ->
                        skip;
                    {ok, Props} ->
                        skip;
                    {ok, NewProps} ->
                        ?log_debug("Upgrade ~p from ~p to ~p",
                                   [{RecType, ns_config_log:tag_user_data(Key)},
                                    ns_config_log:tag_user_props(Props),
                                    ns_config_log:tag_user_props(NewProps)]),
                        {update, NewProps}
                end
        end,

    [] = replicated_dets:select_with_update(
           storage_name(), '_', 100, UpdateFun).

-ifdef(TEST).

upgrade_test_() ->
    CheckUser =
        fun (Id, Name) ->
                Props = get_props_raw(user, {Id, local}),
                ?assertEqual([name, roles],
                             lists:sort(proplists:get_keys(Props))),
                ?assertEqual(Name, proplists:get_value(name, Props))
        end,

    SetRoles =
        ?cut([{Id, [{roles, Roles}, {name, "Test"}]} || {Id, Roles} <- _]),
    SetGroups =
        ?cut(SetRoles([{{group, Id}, Roles} || {Id, Roles} <- _])),
    SetUsers =
        ?cut(SetRoles([{{user, {Id, local}}, Roles} || {Id, Roles} <- _])),

    CheckRoles =
        fun (List) ->
                fun () ->
                        lists:foreach(
                          fun ({Type, Id, Expected}) ->
                                  Props = get_props_raw(Type, Id),
                                  Actual = proplists:get_value(roles, Props),
                                  ?assertEqual(lists:sort(Expected),
                                               lists:sort(Actual))
                          end, List)
                end
        end,

    CheckUUID =
        fun (User)  ->
            Props = get_props_raw(user, {User, local}),
            ?assert(is_binary(proplists:get_value(uuid, Props)))
        end,

    CheckAuth =
        fun (User, AuthType, Expected) ->
            fun () ->
                Props = get_props_raw(auth, {User, local}),
                {Actual} = proplists:get_value(AuthType, Props, []),
                ?assertEqual(lists:sort(Expected),
                             lists:sort(Actual))
            end
        end,

    Test =
        fun (Version, Users, Checks) ->
                {lists:flatten(io_lib:format("Upgrade to ~p", [Version])),
                 fun () ->
                         [replicated_dets:toy_set(
                            storage_name(), Id, Props) ||
                             {Id, Props} <- Users],
                         do_upgrade(Version),
                         [C() || C <- Checks]
                 end}
        end,
    {foreach,
     fun() ->
             meck:new(replicated_dets, [passthrough]),
             meck:expect(replicated_dets, select_with_update,
                         fun replicated_dets:toy_select_with_update/4),
             replicated_dets:toy_init(storage_name())
     end,
     fun (_) ->
             meck:unload(replicated_dets),
             ets:delete(storage_name())
     end,
     [Test(?VERSION_66,
           [{{user, {"user", local}},
             [{roles, [admin]}, {name, "Test"}, {user_roles, [admin]}]}],
           [?cut(CheckUser("user", "Test"))]),
      Test(?VERSION_70,
           SetUsers([{"user1", [admin, {bucket_admin, ["test"]}]},
                     {"user2", [{data_reader, [any]},
                                {data_writer, ["test"]}]}]) ++
           SetGroups([{"group1", [admin, {bucket_admin, ["test"]}]},
                      {"group2", [{data_reader, [any]},
                                  {data_writer, ["test"]}]}]),
           [CheckRoles(
             [{user, {"user1", local}, [admin, {bucket_admin, ["test"]}]},
              {user, {"user2", local}, [{data_reader, [any, any, any]},
                                        {data_writer, ["test", any, any]}]},
              {group, "group1", [admin, {bucket_admin, ["test"]}]},
              {group, "group2", [{data_reader, [any, any, any]},
                                 {data_writer, ["test", any, any]}]}
                                 ]),
            ?cut(CheckUser("user1", "Test")),
            ?cut(CheckUser("user2", "Test"))]),
      Test(?VERSION_71,
           SetUsers([{"user1", [admin]},
                     {"user2", [{bucket_admin, ["test"]}]}]),
           [?cut([CheckUUID(U) || U <- ["user1", "user2"]])]),
      Test(?VERSION_ELIXIR,
           [{{auth, {"migrated-user", local}},
             [{<<"hash">>, {[anything]}},
              {<<"scram-sha-1">>, {[anything]}}]}],
           [CheckAuth("migrated-user", <<"hash">>, [anything]),
            CheckAuth("migrated-user", <<"scram-sha-1">>, [anything])]),
      Test(?VERSION_ELIXIR,
           [{{auth, {"not-migrated-user", local}},
             [{<<"hash">>, {[anything]}},
              {<<"sha1">>,
               {[{?OLD_SCRAM_SALT_KEY, <<"0ues3mfZqA4OjuljBI/uQY5L0jI=">>},
                 {?OLD_SCRAM_HASH_KEY, <<"kZlCBy+TU+meqxR7rJfg9mS1LZA=">>},
                 {?OLD_SCRAM_ITERATIONS_KEY, 4000}]}}]}],
           [CheckAuth("not-migrated-user", <<"hash">>, [anything]),
            CheckAuth("not-migrated-user", <<"scram-sha-1">>,
                      [{?HASHES_KEY, [{[{?SCRAM_STORED_KEY_KEY,
                                         <<"APXjupUS+LktBEirfdNtNtCYChk=">>},
                                        {?SCRAM_SERVER_KEY_KEY,
                                         <<"Vkelr1rzrz9tT0Z/AhLvKJVuWJs=">>}]}]},
                       {?SCRAM_SALT_KEY, <<"0ues3mfZqA4OjuljBI/uQY5L0jI=">>},
                       {?SCRAM_ITERATIONS_KEY, 4000}])])]}.

-endif.
