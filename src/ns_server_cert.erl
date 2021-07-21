%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included
%% in the file licenses/BSL-Couchbase.txt.  As of the Change Date specified
%% in that file, in accordance with the Business Source License, use of this
%% software will be governed by the Apache License, Version 2.0, included in
%% the file licenses/APL2.txt.

-module(ns_server_cert).

-include("ns_common.hrl").

-include_lib("public_key/include/public_key.hrl").

-export([decode_cert_chain/1,
         decode_single_certificate/1,
         generate_and_set_cert_and_pkey/0,
         this_node_ca/1,
         this_node_uses_self_generated_certs/0,
         this_node_uses_self_generated_certs/1,
         self_generated_ca/0,
         set_cluster_ca/1, %% deprecated
         load_node_certs_from_inbox/0,
         load_CAs_from_inbox/0,
         add_CAs/2,
         add_CAs/3,
         get_warnings/0,
         get_subject_fields_by_type/2,
         get_sub_alt_names_by_type/2,
         get_node_cert_info/1,
         tls_server_validation_options/0,
         set_generated_ca/1,
         validate_pkey/1,
         get_chain_info/2,
         trusted_CAs/1,
         generate_node_certs/1]).

inbox_ca_path() ->
    filename:join(path_config:component_path(data, "inbox"), "CA").

inbox_chain_path() ->
    filename:join(path_config:component_path(data, "inbox"), "chain.pem").

inbox_pkey_path() ->
    filename:join(path_config:component_path(data, "inbox"), "pkey.key").

%% The CA that signed this node's cert.
%% Could be autogenerated or uploaded by user.
this_node_ca(Config) ->
    CertProps = ns_config:search(Config, {node, node(), node_cert}, []),
    proplists:get_value(ca, CertProps).

this_node_uses_self_generated_certs() ->
    this_node_uses_self_generated_certs(ns_config:latest()).

this_node_uses_self_generated_certs(Config) ->
    CertProps = ns_config:search(Config, {node, node(), node_cert}, []),
    generated == proplists:get_value(type, CertProps).

self_generated_ca() ->
    case ns_config:search(cert_and_pkey) of
        {value, {CA, _}} -> CA;
        %% for 7.0 mixed clusters
        {value, {_, CA, _}} -> CA;
        false ->
            {CA, _} = generate_and_set_cert_and_pkey(false),
            CA
    end.

self_generated_ca_and_pkey() ->
    case ns_config:search(cert_and_pkey) of
        {value, {CA, PKey}} -> {CA, PKey};
        %% for 7.0 mixed clusters
        {value, {_, CA, PKey}} -> {CA, PKey};
        false -> generate_and_set_cert_and_pkey(false)
    end.

generate_and_set_cert_and_pkey() ->
    generate_and_set_cert_and_pkey(true).

generate_and_set_cert_and_pkey(Force) ->
    Pair = generate_cert_and_pkey(),
    RV = ns_config:run_txn(
           fun (Config, SetFn) ->
                   Existing =
                       case ns_config:search(Config, cert_and_pkey) of
                           {value, {_, _, undefined}} -> undefined;
                           {value, {_, undefined}} -> undefined;
                           false -> undefined;
                           {value, OtherPair} -> OtherPair
                       end,
                   case (Existing == undefined) or Force of
                       true -> {commit, SetFn(cert_and_pkey, Pair, Config)};
                       false -> {abort, Existing}
                   end
           end),

    case RV of
        {abort, OtherPair} ->
            OtherPair;
        _ ->
            case cluster_compat_mode:is_cluster_NEO() of
                true ->
                    %% If we crash here the new cert will never get to
                    %% ca_certificates
                    {ok, _} = add_CAs(generated, element(1, Pair));
                false ->
                    %% It will be added during online upgrade
                    ok
            end,
            Pair
    end.

generate_cert_and_pkey() ->
    StartTS = os:timestamp(),
    Args = case ns_config:read_key_fast({cert, use_sha1}, false) of
               true ->
                   ["--use-sha1"];
               false ->
                   []
           end,
    RV = do_generate_cert_and_pkey(Args, []),
    EndTS = os:timestamp(),

    Diff = timer:now_diff(EndTS, StartTS),
    ?log_debug("Generated certificate and private key in ~p us", [Diff]),

    RV.

generate_node_certs(Host) ->
    {CAPEM, PKeyPEM} = self_generated_ca_and_pkey(),
    generate_node_certs(CAPEM, PKeyPEM, Host).

generate_node_certs(_CAPEM, undefined, _Host) ->
    no_private_key;
generate_node_certs(CAPEM, PKeyPEM, Host) ->
    SANArg =
        case misc:is_raw_ip(Host) of
            true -> "--san-ip-addrs=" ++ Host;
            false -> "--san-dns-names=" ++ Host
        end,

    %% CN can't be longer than 64 characters. Since it will be used for
    %% displaying purposing only, it doesn't make sense to make it even
    %% that long
    HostShortened = case string:slice(Host, 0, 20) of
                        Host -> Host;
                        Shortened -> Shortened ++ "..."
                    end,
    Args = ["--generate-leaf",
            "--common-name=Couchbase Server Node (" ++ HostShortened ++ ")",
            SANArg],
    Env = [{"CACERT", binary_to_list(CAPEM)},
           {"CAPKEY", binary_to_list(PKeyPEM)}],
    {NodeCert, NodeKey} = do_generate_cert_and_pkey(Args, Env),
    {CAPEM, NodeCert, NodeKey}.

do_generate_cert_and_pkey(Args, Env) ->
    {Status, Output} = misc:run_external_tool(path_config:component_path(bin, "generate_cert"), Args, Env),
    case Status of
        0 ->
            extract_cert_and_pkey(Output);
        _ ->
            erlang:exit({bad_generate_cert_exit, Status, Output})
    end.

decode_cert_chain(CertPemBin) ->
    Certs = split_certs(CertPemBin),
    decode_cert_chain(Certs, []).

decode_cert_chain([], Res) -> {ok, lists:reverse(Res)};
decode_cert_chain([Cert | Tail], Res) ->
    case decode_single_certificate(Cert) of
        {error, _} = Err -> Err;
        Der -> decode_cert_chain(Tail, [Der | Res])
    end.

decode_single_certificate(CertPemBin) ->
    case do_decode_certificates(CertPemBin) of
        malformed_cert ->
            {error, malformed_cert};
        [PemEntry] ->
            case validate_cert_pem_entry(PemEntry) of
                {ok, {'Certificate', DerCert, not_encrypted}} -> DerCert;
                {error, Reason} -> {error, Reason}
            end;
        [] ->
            {error, malformed_cert};
        [_|_] ->
            {error, too_many_entries}
    end.

decode_certificates(CertPemBin) ->
    case do_decode_certificates(CertPemBin) of
        malformed_cert ->
            {error, malformed_cert};
        PemEntries ->
            lists:foldl(
              fun (_E, {error, R}) -> {error, R};
                  (E, {ok, Acc}) ->
                      case validate_cert_pem_entry(E) of
                          {ok, Cert} -> {ok, [Cert | Acc]};
                          {error, R} -> {error, R}
                      end
              end, {ok, []}, PemEntries)
    end.

do_decode_certificates(CertPemBin) ->
    try
        public_key:pem_decode(CertPemBin)
    catch T:E:S ->
            ?log_error("Unknown error while parsing certificate:~n~p",
                       [{T, E, S}]),
            malformed_cert
    end.

validate_cert_pem_entry({'Certificate', _, not_encrypted} = Cert) ->
    {ok, Cert};
validate_cert_pem_entry({'Certificate', _, _}) ->
    {error, encrypted_certificate};
validate_cert_pem_entry({BadType, _, _}) ->
    {error, {invalid_certificate_type, BadType}}.

validate_pkey(PKeyPemBin) ->
    try public_key:pem_decode(PKeyPemBin) of
        [{Type, _, not_encrypted} = Entry] ->
            case Type of
                'RSAPrivateKey' ->
                    {ok, Entry};
                'DSAPrivateKey' ->
                    {ok, Entry};
                Other ->
                    ?log_debug("Invalid pkey type: ~p", [Other]),
                    {error, {invalid_pkey, Type}}
            end;
        [{_, _, _}] ->
            {error, encrypted_pkey};
        [] ->
            {error, malformed_pkey};
        Other ->
            ?log_debug("Too many (~p) pkey entries.", [length(Other)]),
            {error, too_many_pkey_entries}
    catch T:E:S ->
            ?log_error("Unknown error while parsing private key:~n~p",
                       [{T, E, S}]),
            {error, malformed_pkey}
    end.

validate_cert_and_pkey({'Certificate', DerCert, not_encrypted}, PKey) ->
    case validate_pkey(PKey) of
        {ok, DerKey} ->
            DecodedCert = public_key:pkix_decode_cert(DerCert, otp),

            TBSCert = DecodedCert#'OTPCertificate'.tbsCertificate,
            PublicKeyInfo = TBSCert#'OTPTBSCertificate'.subjectPublicKeyInfo,
            PublicKey = PublicKeyInfo#'OTPSubjectPublicKeyInfo'.subjectPublicKey,
            DecodedKey = public_key:pem_entry_decode(DerKey),

            Msg = <<"1234567890">>,
            Signature = public_key:sign(Msg, sha, DecodedKey),
            case public_key:verify(Msg, sha, Signature, PublicKey) of
                true ->
                    ok;
                false ->
                    {error, cert_pkey_mismatch}
            end;
        Err ->
            Err
    end.

split_certs(PEMCerts) ->
    Begin = <<"-----BEGIN">>,
    [<<>> | Parts0] = binary:split(PEMCerts, Begin, [global]),
    [<<Begin/binary,P/binary>> || P <- Parts0].

extract_cert_and_pkey(Output) ->
    case split_certs(Output) of
        [Cert, PKey] ->
            case decode_single_certificate(Cert) of
                {error, Error} ->
                    erlang:exit({bad_generated_cert, Cert, Error});
                _ ->
                    case validate_pkey(PKey) of
                        {ok, _} ->
                            {Cert, PKey};
                        Err ->
                            erlang:exit({bad_generated_pkey, PKey, Err})
                    end
            end;
        Parts ->
            erlang:exit({bad_generate_cert_output, Parts})
    end.

attribute_string(?'id-at-countryName') ->
    "C";
attribute_string(?'id-at-stateOrProvinceName') ->
    "ST";
attribute_string(?'id-at-localityName') ->
    "L";
attribute_string(?'id-at-organizationName') ->
    "O";
attribute_string(?'id-at-commonName') ->
    "CN";
attribute_string(_) ->
    undefined.

format_attribute([#'AttributeTypeAndValue'{type = Type,
                                           value = Value}], Acc) ->
    case attribute_string(Type) of
        undefined ->
            Acc;
        Str ->
            [[Str, "=", format_value(Value)] | Acc]
    end.

format_value({utf8String, Utf8Value}) ->
    unicode:characters_to_list(Utf8Value);
format_value({_, Value}) when is_list(Value) ->
    Value;
format_value(Value) when is_list(Value) ->
    Value;
format_value(Value) ->
    io_lib:format("~p", [Value]).

format_name({rdnSequence, STVList}) ->
    Attributes = lists:foldl(fun format_attribute/2, [], STVList),
    lists:flatten(string:join(lists:reverse(Attributes), ", ")).

extract_fields_by_type({rdnSequence, STVList}, Type) ->
    [format_value(V) || [#'AttributeTypeAndValue'{type = T, value = V}] <- STVList,
                        T =:= Type];
extract_fields_by_type(_, _) ->
    [].

convert_date(Year, Rest) ->
    {ok, [Month, Day, Hour, Min, Sec], "Z"} = io_lib:fread("~2d~2d~2d~2d~2d", Rest),
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Min, Sec}}).

convert_date({utcTime, [Y1, Y2 | Rest]}) ->
    Year =
        case list_to_integer([Y1, Y2]) of
            YY when YY < 50 ->
                YY + 2000;
            YY ->
                YY + 1900
        end,
    convert_date(Year, Rest);
convert_date({generalTime, [Y1, Y2, Y3, Y4 | Rest]}) ->
    Year = list_to_integer([Y1, Y2, Y3, Y4]),
    convert_date(Year, Rest).

get_cert_info({'Certificate', DerCert, not_encrypted}) ->
    get_der_info(DerCert).

get_der_info(DerCert) ->
    Decoded = public_key:pkix_decode_cert(DerCert, otp),
    TBSCert = Decoded#'OTPCertificate'.tbsCertificate,
    Subject = format_name(TBSCert#'OTPTBSCertificate'.subject),

    Validity = TBSCert#'OTPTBSCertificate'.validity,
    NotBefore = convert_date(Validity#'Validity'.notBefore),
    NotAfter = convert_date(Validity#'Validity'.notAfter),
    {Subject, NotBefore, NotAfter}.

-spec get_subject_fields_by_type(binary(), term()) -> list() | {error, not_found}.
get_subject_fields_by_type(Cert, Type) ->
    OtpCert = public_key:pkix_decode_cert(Cert, otp),
    TBSCert = OtpCert#'OTPCertificate'.tbsCertificate,
    case extract_fields_by_type(TBSCert#'OTPTBSCertificate'.subject, Type) of
        [] ->
            {error, not_found};
        Vals ->
            Vals
    end.

-spec get_sub_alt_names_by_type(binary(), term()) -> list() | {error, not_found}.
get_sub_alt_names_by_type(Cert, Type) ->
    OtpCert = public_key:pkix_decode_cert(Cert, otp),
    TBSCert = OtpCert#'OTPCertificate'.tbsCertificate,
    TBSExts = TBSCert#'OTPTBSCertificate'.extensions,
    Exts = ssl_certificate:extensions_list(TBSExts),
    case ssl_certificate:select_extension(?'id-ce-subjectAltName', Exts) of
        {'Extension', _, _, Vals} ->
            case [N || {T, N} <- Vals, T == Type] of
                [] ->
                    {error, not_found};
                V ->
                    V
            end;
        _ ->
            {error, not_found}
    end.

parse_cluster_ca(CA) ->
    case decode_single_certificate(CA) of
        {error, Error} ->
            {error, Error};
        RootCertDer ->
            try
                {Subject, NotBefore, NotAfter} = get_der_info(RootCertDer),
                UTC = calendar:datetime_to_gregorian_seconds(
                        calendar:universal_time()),
                case NotBefore > UTC orelse NotAfter < UTC of
                    true ->
                        {error, not_valid_at_this_time};
                    false ->
                        {ok, [{pem, CA},
                              {subject, Subject},
                              {expires, NotAfter}]}
                end
            catch T:E:S ->
                    ?log_error("Failed to get certificate info:~n~p~n~p",
                               [RootCertDer, {T, E, S}]),
                    {error, malformed_cert}
            end
    end.

%% Deprecated. Can be used in pre-NEO clusters only.
set_cluster_ca(CA) ->
    case parse_cluster_ca(CA) of
        {ok, Props} ->
            NewCert = proplists:get_value(pem, Props),
            RV = ns_config:run_txn(
                   fun (Config, SetFn) ->
                           CurCerts =
                               case ns_config:search(Config, cert_and_pkey) of
                                   {value, {NewCert, _}} ->
                                       {error, already_in_use};
                                   {value, {_, _} = Pair} ->
                                       {ok, Pair};
                                   {value, {_, GeneratedCert1, GeneratedKey1}} ->
                                       {ok, {GeneratedCert1, GeneratedKey1}};
                                   false ->
                                       {ok, generate_cert_and_pkey()}
                               end,

                           case CurCerts of
                               {ok, {GeneratedCert, GeneratedKey}} ->
                                   NewCertPKey = {Props, GeneratedCert,
                                                  GeneratedKey},
                                   {commit, SetFn(cert_and_pkey, NewCertPKey,
                                                  Config)};
                               {error, Reason} ->
                                   {abort, Reason}
                           end
                   end),
            case RV of
                {commit, _} ->
                    {ok, Props};
                {abort, Reason} ->
                    {error, Reason};
                retry_needed ->
                    erlang:error(exceeded_retries)
            end;
        {error, Error} ->
            ?log_error("Certificate authority validation failed with ~p", [Error]),
            {error, Error}
    end.

set_generated_ca(CA) ->
    ns_config:set(cert_and_pkey, {CA, undefined}),
    {ok, _} = add_CAs(generated, CA),
    ok.

-record(verify_state, {last_subject, root_cert, chain_len}).

get_subject(Cert) ->
    TBSCert = Cert#'OTPCertificate'.tbsCertificate,
    format_name(TBSCert#'OTPTBSCertificate'.subject).

verify_fun(Cert, Event, State) ->
    Subject = get_subject(Cert),
    ?log_debug("Certificate verification event : ~p", [{Subject, Event}]),

    case Event of
        {bad_cert, invalid_issuer} ->
            case State#verify_state.last_subject of
                undefined ->
                    RootOtpCert = public_key:pkix_decode_cert(State#verify_state.root_cert, otp),
                    RootSubject = get_subject(RootOtpCert),
                    {fail, {invalid_root_issuer, Subject, RootSubject}};
                LastSubject ->
                    {fail, {invalid_issuer, Subject, LastSubject}}
            end;
        {bad_cert, Error} ->
            ?log_error("Certificate ~p validation failed with reason ~p",
                       [Subject, Error]),

            Trace = erlang:process_info(self(), [current_stacktrace]),
            OtpCert = public_key:pkix_decode_cert(State#verify_state.root_cert, otp),
            InitValidationState =
                pubkey_cert:init_validation_state(OtpCert, State#verify_state.chain_len, []),

            ?log_debug("Certificate validation trace:~n     Initial Context: ~p~n"
                       "     Cert: ~p~n     Stack: ~p~n",
                       [InitValidationState, Cert, Trace]),
            {fail, {Error, Subject}};
        {extension, Ext} ->
            ?log_warning(
               "Certificate ~p validation spotted an unknown extension ~p",
               [Subject, Ext]),
            {unknown, State};
        valid ->
            {valid, State#verify_state{last_subject = Subject}};
        valid_peer ->
            {valid, State}
    end.

decode_chain(Chain) ->
    try
        lists:reverse(public_key:pem_decode(Chain))
    catch T:E:S ->
            ?log_error("Unknown error while parsing certificate chain:~n~p",
                       [{T, E, S}]),
            {error, {bad_chain, malformed_cert}}
    end.

validate_chain([]) ->
    ok;
validate_chain([Entry | Rest]) ->
    case validate_cert_pem_entry(Entry) of
        {error, Error} ->
            {error, {bad_chain, Error}};
        {ok, _} ->
            validate_chain(Rest)
    end.

validate_chain_signatures([], _Chain) ->
    {error, no_ca};
validate_chain_signatures([CAProps | Tail], Chain) ->
    CA = proplists:get_value(pem, CAProps),
    CAId = proplists:get_value(id, CAProps),
    [{'Certificate', RootCertDer, not_encrypted}] = public_key:pem_decode(CA),
    DerChain = [Der || {'Certificate', Der, not_encrypted} <- Chain],
    State = #verify_state{root_cert = RootCertDer,
                          chain_len = length(Chain)},
    Options = [{verify_fun, {fun verify_fun/3, State}}],
    case public_key:pkix_path_validation(RootCertDer, DerChain, Options) of
        {ok, _} -> {ok, CA};
        {error, Reason} ->
            ?log_warning("Chain validation failed with root cert #~p: ~p",
                         [CAId, Reason]),
            validate_chain_signatures(Tail, Chain)
    end.

decode_and_validate_chain(CAs, Chain) ->
    case decode_chain(Chain) of
        {error, _} = Err ->
            Err;
        [] ->
            {error, {bad_chain, malformed_cert}};
        PemEntriesReversed ->
            case validate_chain(PemEntriesReversed) of
                {error, _} = Err ->
                    Err;
                ok ->
                    case validate_chain_signatures(CAs, PemEntriesReversed) of
                        {error, _} = Err ->
                            Err;
                        {ok, ChainCA} ->
                            [ChainCADecoded] = public_key:pem_decode(ChainCA),
                            case PemEntriesReversed of
                                [ChainCADecoded | Rest] -> {ok, ChainCA, Rest};
                                _ -> {ok, ChainCA, PemEntriesReversed}
                            end
                    end
            end
    end.

get_chain_info(Chain, CA) when is_binary(Chain), is_binary(CA) ->
    lists:foldl(
                fun (Cert, Acc) ->
                    {NewSub, _, NewExpiration} = get_cert_info(Cert),
                    case Acc of
                        undefined ->
                            {NewSub, NewExpiration};
                        {_Sub, Expiration} when Expiration > NewExpiration ->
                            {NewSub, NewExpiration};
                        {_Sub, Expiration} ->
                            {NewSub, Expiration}
                    end
                end, undefined, public_key:pem_decode(CA) ++
                                lists:reverse(public_key:pem_decode(Chain))).

trusted_CAs(Format) ->
    case chronicle_kv:get(kv, ca_certificates) of
        {ok, {Certs, _}} ->
            SortedCerts = lists:sort(fun (PL1, PL2) ->
                                         Id1 = proplists:get_value(id, PL1),
                                         Id2 = proplists:get_value(id, PL2),
                                         Id1 =< Id2
                                     end, Certs),
            case Format of
                props ->
                    SortedCerts;
                pem ->
                    [proplists:get_value(pem, Props) || Props <- SortedCerts];
                der ->
                    lists:map(
                      fun (Props) ->
                          Pem = proplists:get_value(pem, Props),
                          decode_single_certificate(Pem)
                      end, SortedCerts)
            end;
        {error, not_found} ->
            []
    end.

load_node_certs_from_inbox() ->
    case file:read_file(inbox_chain_path()) of
        {ok, Chain} ->
            case file:read_file(inbox_pkey_path()) of
                {ok, PKey} ->
                    set_node_certificate_chain(Chain, PKey);
                {error, Reason} ->
                    {error, {read_pkey, inbox_pkey_path(), Reason}}
            end;
        {error, Reason} ->
            {error, {read_chain, inbox_chain_path(), Reason}}
    end.

set_node_certificate_chain(Chain, PKey) ->
    case decode_and_validate_chain(trusted_CAs(props), Chain) of
        {ok, CAPem, ChainEntriesReversed} ->
            %% ChainReversed :: [Int cert,..., Node cert] (without CA)
            ChainEntries = lists:reverse(ChainEntriesReversed),
            NodeCert = hd(ChainEntries),
            case validate_cert_and_pkey(NodeCert, PKey) of
                ok ->
                    ns_ssl_services_setup:set_node_certificate_chain(
                           CAPem,
                           public_key:pem_encode(ChainEntries),
                           PKey);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

add_CAs(Type, Pem) ->
    add_CAs(Type, Pem, []).

add_CAs(Type, Pem, Opts) when is_binary(Pem),
                        (Type =:= uploaded) or (Type =:= generated) ->
    SingleCert = proplists:get_bool(single_cert, Opts),
    case decode_certificates(Pem) of
        {ok, PemEntries} when SingleCert,
                              length(PemEntries) > 1 ->
            {error, too_many_entries};
        {ok, PemEntries} ->
            load_CAs([cert_props(Type, E, []) || E <- PemEntries]);
        {error, Reason} ->
            {error, Reason}
    end.

load_CAs_from_inbox() ->
    CAInbox = inbox_ca_path(),
    case read_CAs(CAInbox) of
        {ok, []} ->
            {error, {CAInbox, empty}};
        {ok, NewCAs} ->
            load_CAs(NewCAs);
        {error, R} ->
            {error, R}
    end.

load_CAs(CAPropsList) ->
    UTCTime = calendar:universal_time(),
    LoadTime = calendar:datetime_to_gregorian_seconds(UTCTime),
    {ok, _, AddedCAs} =
        chronicle_kv:transaction(
          kv, [ca_certificates],
          fun (Snapshot) ->
              {CAs, _Rev} = maps:get(ca_certificates, Snapshot,
                                     {[], undefined}),
              ToSet = maybe_append_CA_certs(CAs, CAPropsList, LoadTime),
              NewCAs = ToSet -- CAs,
              {commit, [{set, ca_certificates, ToSet}], NewCAs}
          end, #{}),
    {ok, AddedCAs}.

maybe_append_CA_certs(CAs, [], _) ->
    ?log_error("Appending empty list of certs"),
    CAs;
maybe_append_CA_certs(CAs, CAPropsList, LoadTime) ->
    MaxId = lists:max([-1] ++ [proplists:get_value(id, CA) || CA <- CAs]),
    {_, Res} = lists:foldl(
                 fun (NewCA, {NextId, Acc}) ->
                     L = lists:concat(
                           [public_key:pem_decode(proplists:get_value(pem, CA))
                            || CA <- Acc]),
                     NewPem = proplists:get_value(pem, NewCA),
                     [NewPemDecoded] = public_key:pem_decode(NewPem),
                     case lists:member(NewPemDecoded, L) of
                         true ->
                             ?log_info("Not adding the following CA cert as "
                                       "it is already added: ~p", [NewPem]),
                             {NextId, Acc};
                         false ->
                             ?log_info("Adding new CA cert with id ~p: ~p",
                                       [NextId, NewPem]),
                             NewCA2 = [{id, NextId},
                                       {load_timestamp, LoadTime} | NewCA],
                             {NextId + 1, [NewCA2 | Acc]}
                     end
                 end, {MaxId + 1, CAs}, CAPropsList),
    Res.

read_CAs(CAPath) ->
    case file:list_dir(CAPath) of
        {ok, Files} ->
            lists:foldl(
              fun (_, {error, R}) -> {error, R};
                  (F, {ok, Acc}) ->
                      FullPath = filename:join(CAPath, F),
                      case read_ca_file(FullPath) of
                          {ok, CAPropsList} -> {ok, CAPropsList ++ Acc};
                          {error, R} -> {error, {FullPath, R}}
                      end
              end, {ok, []}, Files);
        {error, Reason} -> {error, {CAPath, {read, Reason}}}
    end.

read_ca_file(Path) ->
    case file:read_file(Path) of
        {ok, CertPemBin} ->
            case decode_certificates(CertPemBin) of
                {ok, PemEntries} ->
                    Host = misc:extract_node_address(node()),
                    Extras = [{load_host, iolist_to_binary(Host)},
                              {load_file, iolist_to_binary(Path)}],
                    {ok, [cert_props(uploaded, E, Extras)
                          || E <- PemEntries]};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {read, Reason}}
    end.

cert_props(Type, DecodedCert, Extras) ->
    {Sub, NotBefore, NotAfter} = get_cert_info(DecodedCert),
    [{subject, iolist_to_binary(Sub)},
     {not_before, NotBefore},
     {not_after, NotAfter},
     {type, Type},
     {pem, public_key:pem_encode([DecodedCert])}] ++ Extras.

get_warnings() ->
    Config = ns_config:get(),
    Nodes = ns_node_disco:nodes_wanted(Config),
    TrustedCAs = trusted_CAs(pem),
    NodeWarnings =
        lists:flatmap(
          fun (Node) ->
              Warnings =
                  case ns_config:search(Config, {node, Node, node_cert}) of
                      {value, Props} -> node_cert_warnings(TrustedCAs, Props);
                      false ->
                          %% Pre-NEO node:
                          case ns_config:search(Config, {node, Node, cert}) of
                              {value, Props} ->
                                   node_cert_warnings(TrustedCAs, Props);
                              false ->
                                   case ns_config:search(cert_and_pkey) of
                                       {value, {_, _}} ->
                                           [self_signed];
                                       _ ->
                                           [mismatch]
                                   end
                          end
                  end,
              [{{node, Node}, W} || W <- Warnings]
          end, Nodes),
    CAWarnings =
        lists:flatmap(
          fun (CAProps) ->
                  SelfSignedWarnings =
                      case proplists:get_value(type, CAProps) of
                          generated -> [self_signed];
                          _ -> []
                      end,
                  ExpWarnings = expiration_warnings(CAProps),
                  Id = proplists:get_value(id, CAProps),
                  [{{ca, Id}, W} || W <- SelfSignedWarnings ++ ExpWarnings]
          end, trusted_CAs(props)),
    NodeWarnings ++ CAWarnings.

expiration_warnings(CertProps) ->
    Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
    WarningDays = ns_config:read_key_fast({cert, expiration_warning_days}, 7),
    WarningThreshold = Now + WarningDays * 24 * 60 * 60,

    Expire = proplists:get_value(expires, CertProps), %% For pre-NEO only
    NotAfter = proplists:get_value(not_after, CertProps, Expire),
    case NotAfter of
        A when is_integer(A) andalso A =< Now ->
            [expired];
        A when is_integer(A) andalso A =< WarningThreshold ->
            [{expires_soon, A}];
        _ ->
            []
    end.

is_trusted(CAPem, TrustedCAs) ->
    Decoded = decode_single_certificate(CAPem),
    lists:any(
      fun (C) ->
          Decoded == decode_single_certificate(C)
      end, TrustedCAs).

node_cert_warnings(TrustedCAs, NodeCertProps) ->
    MissingCAWarnings =
        case proplists:get_value(ca, NodeCertProps) of
            undefined ->
                %% For pre-NEO clusters, old nodes don't have ca prop
                VerifiedWith =
                    proplists:get_value(verified_with, NodeCertProps),
                CAMd5s = [erlang:md5(C) || C <- TrustedCAs],
                case lists:member(VerifiedWith, CAMd5s) of
                    true -> [];
                    false -> [mismatch]
                end;
            CA ->
                case is_trusted(CA, TrustedCAs) of
                    true -> [];
                    false -> [mismatch]
                end
        end,

    ExpirationWarnings = expiration_warnings(NodeCertProps),

    SelfSignedWarnings =
        case proplists:get_value(type, NodeCertProps) of
            generated -> [self_signed];
            _ -> []
        end,

    MissingCAWarnings ++ ExpirationWarnings ++ SelfSignedWarnings.

get_node_cert_info(Node) ->
    Props = ns_config:read_key_fast({node, Node, cert}, []),
    proplists:delete(verified_with, Props).

tls_server_validation_options() ->
    case this_node_uses_self_generated_certs() of
        true -> [];
        false ->
            [{verify, verify_peer},
             {cacerts, trusted_CAs(der)},
             {depth, ?ALLOWED_CERT_CHAIN_LENGTH}]
    end.
