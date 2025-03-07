#!/usr/bin/env escript
%% @author Couchbase <info@couchbase.com>
%% @copyright 2020-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.

-mode(compile).

-export([main/1]).

-include("../include/ns_stats.hrl").

main([InputFilename, OutputFilename]) ->
    try
        FileContents = case file:read_file(InputFilename) of
                           {ok, Bin} ->
                               Bin;
                           {error, Reason} ->
                               error({read_failed, InputFilename, Reason})
                       end,
        Module = filename:rootname(filename:basename(OutputFilename), ".erl"),
        Result = format_mappings(list_to_atom(Module), FileContents),
        case file:write_file(OutputFilename, Result) of
            ok -> ok;
            {error, Err} -> error({write_failed, OutputFilename, Err})
        end
    catch
        error:E ->
            io:format("~s~n", [format_error(E)]),
            erlang:halt(1)
    end.

format_mappings(Module, Contents) ->
    Pairs = add_missing_kv_pairs(parse_map_file(Contents)),
    AST = [{attribute, 0, module, Module},
           {attribute, 0, export, [{old_to_new, 1}, {new_to_old, 1}]},
           generate_mappings(old_to_new, old_to_new_kv_stat_mapping(Pairs)),
           generate_mappings(new_to_old, new_to_old_kv_stat_mapping(Pairs))],
    io_lib:format("%% DO NOT EDIT~n"
                  "%% This file is autogenerated~n~n~s~n~n~s",
                  [licence(),
                   [erl_pp:form(Form, fun pp_hook/4) || Form <- AST]]).

pp_hook({term, Term}, _Indent, _Precedence, _Opts) ->
    io_lib:format("~p", [Term]).

generate_mappings(Name, Pairs) ->
    Keys = [K || {K, _} <- Pairs],
    DoublingKeys = Keys -- lists:usort(Keys),
    (DoublingKeys == []) orelse error({duplicating_keys, DoublingKeys}),
    Clauses = [{clause, 0, [{term, From}], [], [{term, {ok, To}}]}
                                                    || {From, To} <- Pairs],
    DefaultClause = {clause, 0, [{var, 0, '_'}], [],
                     [{term, {error, not_found}}]},
    {function, 0, Name, 1, Clauses ++ [DefaultClause]}.

old_to_new_kv_stat_mapping(Pairs) ->
    do_generate_mappings(Pairs,
                         fun (Key, Type, Value, KeyUnit, ValueUnit) ->
                                 {true,
                                  {Key, {Type, Value, {KeyUnit, ValueUnit}}}}
                         end).

new_to_old_kv_stat_mapping(Pairs) ->
    do_generate_mappings(Pairs,
                         fun (Key, _Type, Value, _KeyUnit, _ValueUnit) ->
                                 {true, {Value, Key}}
                         end).

do_generate_mappings(Pairs, BuildMapEntry) ->
    BinCounters = [atom_to_binary(C, latin1) || C <- [?STAT_COUNTERS]],
    BinGauges = [atom_to_binary(G, latin1) || G <- [?STAT_GAUGES]],

    lists:filtermap(
      fun ({{Key, KeyUnit}, {Value, ValueUnit}}) ->
              Type = case lists:member(Key, BinCounters) of
                         true -> counter;
                         false ->
                             case lists:member(Key, BinGauges) of
                                 true -> gauge;
                                 false -> unknown
                             end
                     end,
              case Type of
                  unknown -> false;
                  _ -> BuildMapEntry(Key, Type, Value, KeyUnit, ValueUnit)
              end
      end, Pairs).

add_missing_kv_pairs(Pairs) ->
    PresentKeys = [K || {{K, _}, _} <- Pairs],
    AllMetrics = [atom_to_binary(C, latin1)
                      || C <- [?STAT_COUNTERS, ?STAT_GAUGES]],
    MissingMetrics = AllMetrics -- PresentKeys,
    ExtraPairs = [{{M, none}, {{<<"kv_", M/binary>>, []}, none}}
                      || M <- MissingMetrics],
    Pairs ++ ExtraPairs.

parse_map_file(Contents) ->
    Lines = string:lexemes(Contents, [$\n]),
    lists:filtermap(
      fun (L) ->
              case string:trim(L) of
                  <<"#", _/binary>> -> false;
                  <<>> -> false;
                  Trimmed ->
                      [Token1, Token2, Token3, Token4] = split_line(Trimmed),
                      Key = Token1,
                      KeyUnit = binary_to_atom(Token2, latin1),
                      Val = parse_prometheus_metric(Token3),
                      ValUnit = binary_to_atom(Token4, latin1),
                      {true, {{Key, KeyUnit}, {Val, ValUnit}}}
              end
      end, Lines).

split_line(Bin) ->
    try
        %% Line is supposed to be
        %% "<old_metric> <old_unit> <new_metric> <new_unit>"
        %% Note: <new_metric> may contain spaces, other tokens can't
        [T1, Rest1] = string:split(Bin, " "),
        [T2, Rest2] = string:split(Rest1, " "),
        [T3, T4] = string:split(Rest2, " ", trailing),
        [string:trim(T) || T <- [T1, T2, T3, T4]]
    catch
        _:_ -> error({invalid_value, Bin})
    end.

parse_prometheus_metric(Bin) ->
    case re:run(Bin, <<"^(?<name>[^{\\s]+)({(?<labels>.*)})?$">>,
                [{capture, [name, labels], binary}]) of
        {match, [Name, LabelsBin]} ->
            Labels =
                lists:map(
                  fun (T) ->
                      Re = <<"^\\s*(?<key>\\S+)\\s*=\\s*\"(?<value>.*)\"\\s*">>,
                      case re:run(T, Re, [{capture, [key, value], binary}]) of
                          {match, [Key, Value]} -> {Key, Value};
                          nomatch -> error({invalid_value, Bin})
                      end
                  end, string:lexemes(LabelsBin, ",")),
            {Name, lists:usort(Labels)};
        nomatch ->
            error({invalid_value, Bin})
    end.

format_error({read_failed, Path, Reason}) ->
    io_lib:format("Failed to read file ~s with reason: ~p", [Path, Reason]);
format_error({write_failed, Path, Reason}) ->
    io_lib:format("Failed to write file ~s with reason: ~p", [Path, Reason]);
format_error({duplicating_keys, Keys}) ->
    io_lib:format("Duplicating keys: ~p", [Keys]);
format_error({invalid_value, Bin}) ->
    io_lib:format("Can't parse \"~s\"", [Bin]);
format_error(Error) ->
    io_lib:format("Unexpected error in ~p: ~p", [?MODULE, Error]).

licence() ->
    "%% @author Couchbase <info@couchbase.com>\n"
    "%% @copyright 2020-2021 Couchbase, Inc.\n"
    "%%\n"
    "%% Licensed under the Apache License, Version 2.0 (the \"License\");\n"
    "%% you may not use this file except in compliance with the License.\n"
    "%% You may obtain a copy of the License at\n"
    "%%\n"
    "%%      http://www.apache.org/licenses/LICENSE-2.0\n"
    "%%\n"
    "%% Unless required by applicable law or agreed to in writing, software\n"
    "%% distributed under the License is distributed on an \"AS IS\" BASIS,\n"
    "%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or "
    "implied.\n"
    "%% See the License for the specific language governing permissions and\n"
    "%% limitations under the License.".
