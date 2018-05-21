%% @author Couchbase <info@couchbase.com>
%% @copyright 2009-2018 Couchbase, Inc.
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
-module(token_server).

-include("ns_common.hrl").

-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([generate/2, maybe_refresh/2,
         check/3, check/2, reset_all/1, remove/2,
         purge/2, take/2]).

start_link(Module, MaxTokens, ExpirationSeconds) ->
    gen_server:start_link({local, Module}, ?MODULE,
                           [Module, MaxTokens, ExpirationSeconds], []).

tok2bin(Token) when is_list(Token) ->
    list_to_binary(Token);
tok2bin(Token) ->
    Token.

generate(Module, Memo) ->
    gen_server:call(Module, {generate, Memo}, infinity).

maybe_refresh(Module, Token) ->
    gen_server:call(Module, {maybe_refresh, tok2bin(Token)}, infinity).


check(Module, Token) ->
    check(Module, Token, node()).

check(_, undefined, _) ->
    false;
check(Module, Token, Node) ->
    case lists:member(Node, ns_node_disco:nodes_actual()) of
        true ->
            gen_server:call({Module, Node}, {check, tok2bin(Token)}, infinity);
        false ->
            false
    end.

reset_all(Module) ->
    gen_server:call(Module, reset_all, infinity).

remove(Module, Token) ->
    gen_server:call(Module, {remove, tok2bin(Token)}, infinity).

take(Module, Token) ->
    gen_server:call(Module, {take, tok2bin(Token)}, infinity).

purge(Module, MemoPattern) ->
    gen_server:cast(Module, {purge, MemoPattern}).

-record(state, {table_by_token,
                table_by_exp,
                max_tokens,
                exp_seconds}).

init([Module, MaxTokens, ExpirationSeconds]) ->
    ExpTable = list_to_atom(atom_to_list(Module) ++ "_by_expiration"),
    _ = ets:new(Module, [protected, named_table, set]),
    _ = ets:new(ExpTable, [protected, named_table, ordered_set]),
    Module:init(),
    {ok, #state{table_by_token = Module,
                table_by_exp = ExpTable,
                max_tokens = MaxTokens,
                exp_seconds = ExpirationSeconds}}.

maybe_expire(#state{table_by_token = Table,
                    max_tokens = MaxTokens} = State) ->
    Size = ets:info(Table, size),
    case Size < MaxTokens of
        true ->
            ok;
        _ ->
            expire_oldest(State)
    end.

expire_oldest(#state{table_by_token = Table,
                     table_by_exp = ExpTable}) ->
    {Expiration, Token} = ets:first(ExpTable),
    ets:delete(ExpTable, {Expiration, Token}),
    ets:delete(Table, Token),
    ok.

remove_token(Token, #state{table_by_token = Table,
                           table_by_exp = ExpTable}) ->
    case ets:lookup(Table, Token) of
        [{Token, Expiration, ReplacedToken, _}] ->
            ets:delete(ExpTable, {Expiration, Token}),
            ets:delete(Table, Token),
            ReplacedToken;
        [] ->
            false
    end.

remove_token_with_predecessor(Token, State) ->
    %% NOTE: {maybe_refresh... above is inserting new token when old is
    %% still valid (to give current requests time to finish). But
    %% gladly we also store older and potentially valid token, so we
    %% can delete it as well here
    OlderButMaybeValidToken = remove_token(Token, State),
    case OlderButMaybeValidToken of
        undefined ->
            ok;
        false ->
            ok;
        _ ->
            remove_token(OlderButMaybeValidToken, State)
    end,
    ok.

get_now() ->
    erlang:monotonic_time(second).

do_generate_token(ReplacedToken, Memo,
                  #state{table_by_token = Table,
                         table_by_exp = ExpTable,
                         exp_seconds = ExpirationSeconds}) ->
    %% NOTE: couch_uuids:random is using crypto-strong random
    %% generator
    Token = couch_uuids:random(),
    Expiration = get_now() + ExpirationSeconds,
    ets:insert(Table, {Token, Expiration, ReplacedToken, Memo}),
    ets:insert(ExpTable, {{Expiration, Token}}),
    Token.

validate_token_maybe_expire(Token, #state{table_by_token = Table} = State) ->
    case ets:lookup(Table, Token) of
        [{Token, Expiration, _, Memo}] ->
            Now = get_now(),
            case Expiration < Now of
                true ->
                    remove_token(Token, State),
                    false;
                _ ->
                    {Expiration, Now, Memo}
            end;
        [] ->
            false
    end.

handle_call(reset_all, _From, #state{table_by_token = Table,
                                     table_by_exp = ExpTable} = State) ->
    ets:delete_all_objects(Table),
    ets:delete_all_objects(ExpTable),
    {reply, ok, State};
handle_call({generate, Memo}, _From, State) ->
    maybe_expire(State),
    Token = do_generate_token(undefined, Memo, State),
    {reply, Token, State};
handle_call({maybe_refresh, Token}, _From,
            #state{exp_seconds = ExpirationSeconds} = State) ->
    case validate_token_maybe_expire(Token, State) of
        false ->
            {reply, nothing, State};
        {Expiration, Now, Memo} ->
            case Expiration - Now < ExpirationSeconds / 2 of
                true ->
                    %% NOTE: we take note of current and still valid
                    %% token for correctness of logout
                    %%
                    %% NOTE: condition above ensures that there are at
                    %% most 2 valid tokens per session
                    NewToken = do_generate_token(Token, Memo, State),
                    {reply, {new_token, NewToken}, State};
                false ->
                    {reply, nothing, State}
            end
    end;
handle_call({remove, Token}, _From, State) ->
    remove_token_with_predecessor(Token, State),
    {reply, ok, State};
handle_call({take, Token}, _From, State) ->
    case validate_token_maybe_expire(Token, State) of
        false ->
            {reply, false, State};
        {_, _, Memo} ->
            remove_token_with_predecessor(Token, State),
            {reply, {ok, Memo}, State}
    end;
handle_call({check, Token}, _From, State) ->
    case validate_token_maybe_expire(Token, State) of
        false ->
            {reply, false, State};
        {_, _, Memo} ->
            {reply, {ok, Memo}, State}
    end;
handle_call(Msg, From, _State) ->
    erlang:error({unknown_call, Msg, From}).

handle_cast({purge, MemoPattern}, #state{table_by_token = Table} = State) ->
    Tokens = ets:match(Table, {'$1', '_', '_', MemoPattern}),
    ?log_debug("Purge tokens ~p", [Tokens]),
    [remove_token(Token, State) || [Token] <- Tokens],
    {noreply, State};

handle_cast(Msg, _State) ->
    erlang:error({unknown_cast, Msg}).

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
