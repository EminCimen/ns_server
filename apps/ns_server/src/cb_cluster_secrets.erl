%% @author Couchbase <info@couchbase.com>
%% @copyright 2024-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(cb_cluster_secrets).

-behaviour(gen_server).

-include("ns_common.hrl").
-include_lib("ns_common/include/cut.hrl").
-include("cb_cluster_secrets.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MASTER_MONITOR_NAME, {via, leader_registry, cb_cluster_secrets_master}).
-define(RETRY_TIME, ?get_param(retry_time, 10000)).
-define(SYNC_TIMEOUT, ?get_timeout(sync, 60000)).
-define(NODE_PROC, node_monitor_process).
-define(MASTER_PROC, master_monitor_process).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

%% API
-export([start_link_node_monitor/0,
         start_link_master_monitor/0,
         add_new_secret/1,
         replace_secret/2,
         get_all/0,
         get_secret/1,
         get_secret/2,
         rotate/1,
         ensure_can_encrypt_bucket/3]).

%% Can be called by other nodes:
-export([add_new_secret_internal/1,
         replace_secret_internal/2,
         rotate_internal/1,
         sync_with_node_monitor/0]).

-record(state, {proc_type :: ?NODE_PROC | ?MASTER_PROC,
                jobs :: [node_job()] | [master_job()],
                timers = #{retry_jobs => undefined}
                         :: #{atom() := reference() | undefined}}).

-type secret_props() ::
    #{id := secret_id(),
      name := string(),
      creation_time := calendar:datetime(),
      type := secret_type(),
      usage := [{bucket_encryption, BucketName :: string()} |
                secrets_encryption],
      data := autogenerated_key_data() | aws_key_data()}.
-type secret_type() :: ?GENERATED_KEY_TYPE | ?AWSKMS_KEY_TYPE.
-type autogenerated_key_data() :: #{auto_rotation := boolean(),
                                    rotation_interval := pos_integer(),
                                    first_rotation_time := calendar:datetime(),
                                    active_key_id := kek_id(),
                                    keys := [kek_props()],
                                    encrypt_by := nodeSecretManager |
                                                  clusterSecret,
                                    encrypt_secret_id := secret_id() |
                                                         ?SECRET_ID_NOT_SET}.
-type kek_props() :: #{id := kek_id(),
                       creation_time := calendar:datetime(),
                       key := {sensitive | encrypted_binary, binary()},
                       encrypted_by := undefined | {secret_id(), kek_id()}}.
-type aws_key_data() :: #{key_arn := string(),
                          region := string(),
                          profile := string(),
                          config_file := string(),
                          credentials_file := string(),
                          use_imds := boolean(),
                          uuid := uuid()}.
-type secret_id() :: non_neg_integer().
-type kek_id() :: uuid().
-type chronicle_snapshot() :: direct | map().
-type uuid() :: binary(). %% uuid as binary string
-type node_job() :: ensure_all_keks_on_disk |
                    maybe_reencrypt_per_node_deks.

-type master_job() :: maybe_reencrypt_secrets.

-type bad_encrypt_id() :: {encrypt_id, not_allowed | not_found}.
-type bad_usage_change() :: {usage, in_use}.

%%%===================================================================
%%% API
%%%===================================================================

%% Starts on each cluster node
-spec start_link_node_monitor() -> {ok, pid()}.
start_link_node_monitor() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [?NODE_PROC], []).

%% Starts on the master node only
-spec start_link_master_monitor() -> {ok, pid()}.
start_link_master_monitor() ->
    misc:start_singleton(gen_server, start_link,
                         [?MASTER_MONITOR_NAME, ?MODULE, [?MASTER_PROC], []]).

-spec get_all() -> [secret_props()].
get_all() -> get_all(direct).

-spec get_all(chronicle_snapshot()) -> [secret_props()].
get_all(Snapshot) ->
    chronicle_compat:get(Snapshot, ?CHRONICLE_SECRETS_KEY, #{default => []}).

-spec get_secret(secret_id()) -> {ok, secret_props()} | {error, not_found}.
get_secret(SecretId) -> get_secret(SecretId, direct).

-spec get_secret(secret_id(), chronicle_snapshot()) ->
                                    {ok, secret_props()} | {error, not_found}.
get_secret(SecretId, Snapshot) when is_integer(SecretId) ->
    SearchFun = fun (#{id := Id}) -> SecretId == Id end,
    case lists:search(SearchFun, get_all(Snapshot)) of
        {value, Props} ->
            {ok, Props};
        false ->
            {error, not_found}
    end.

-spec add_new_secret(secret_props()) -> {ok, secret_props()} |
                                        {error, not_supported |
                                                bad_encrypt_id() |
                                                bad_usage_change()}.
add_new_secret(Props) ->
    execute_on_master({?MODULE, add_new_secret_internal, [Props]}).

-spec add_new_secret_internal(secret_props()) ->
                                            {ok, secret_props()} |
                                            {error, not_supported |
                                                    bad_encrypt_id() |
                                                    bad_usage_change()}.
add_new_secret_internal(Props) ->
    CurrentDateTime = erlang:universaltime(),
    PropsWTime = Props#{creation_time => CurrentDateTime},
    RV = chronicle_kv:transaction(
           kv, [?CHRONICLE_SECRETS_KEY, ?CHRONICLE_NEXT_ID_KEY,
                ns_bucket:root()],
           fun (Snapshot) ->
               CurList = get_all(Snapshot),
               NextId = chronicle_compat:get(Snapshot, ?CHRONICLE_NEXT_ID_KEY,
                                             #{default => 0}),
               PropsWId = PropsWTime#{id => NextId},
               maybe
                   {ok, FinalProps} ?= prepare_new_secret(PropsWId),
                   NewList = [FinalProps | CurList],
                   ok ?= validate_secret_in_txn(FinalProps, #{}, Snapshot),
                   {commit, [{set, ?CHRONICLE_SECRETS_KEY, NewList},
                             {set, ?CHRONICLE_NEXT_ID_KEY, NextId + 1}],
                    FinalProps}
               else
                   {error, Reason} -> {abort, {error, Reason}}
               end
            end),
    case RV of
        {ok, _, Res} ->
            sync_with_all_node_monitors(),
            {ok, Res};
        {error, _} = Error -> Error
    end.

-spec replace_secret(secret_props(), map()) ->
                                    {ok, secret_props()} |
                                    {error, not_found | bad_encrypt_id() |
                                            bad_usage_change()}.
replace_secret(OldProps, NewProps) ->
    execute_on_master({?MODULE, replace_secret_internal, [OldProps, NewProps]}).

-spec replace_secret_internal(secret_props(), map()) ->
                                    {ok, secret_props()} |
                                    {error, not_found | bad_encrypt_id() |
                                            bad_usage_change()}.
replace_secret_internal(OldProps, NewProps) ->
    Props = copy_static_props(OldProps, NewProps),
    Res =
        chronicle_compat:txn(
          fun (Txn) ->
              SecretsSnapshot =
                  chronicle_compat:txn_get_many([?CHRONICLE_SECRETS_KEY], Txn),
              BucketSnapshot =
                  ns_bucket:fetch_snapshot(all, Txn, [props]),
              Snapshot = maps:merge(BucketSnapshot, SecretsSnapshot),
              CurList = get_all(Snapshot),
              case replace_secret_in_list(Props, CurList) of
                  false -> %% already removed, we should not create new
                      {abort, {error, not_found}};
                  NewList ->
                      case validate_secret_in_txn(Props, OldProps, Snapshot) of
                          ok ->
                              {commit,
                               [{set, ?CHRONICLE_SECRETS_KEY, NewList}]};
                          {error, _} = Error ->
                              {abort, Error}
                      end
              end
           end),
    case Res of
        {ok, _} ->
            sync_with_all_node_monitors(),
            {ok, Props};
        {error, _} = Error -> Error
    end.

%% Cipher should have type crypto:cipher() but it is not exported
-spec generate_raw_key(Cipher :: atom()) -> binary().
generate_raw_key(Cipher) ->
    #{key_length := Length} = crypto:cipher_info(Cipher),
    crypto:strong_rand_bytes(Length).

-spec rotate(secret_id()) -> ok | {error, not_found | not_supported |
                                          bad_encrypt_id()}.
rotate(Id) ->
    execute_on_master({?MODULE, rotate_internal, [Id]}).

-spec rotate_internal(secret_id()) -> ok | {error, not_found |
                                                   not_supported |
                                                   bad_encrypt_id()}.
rotate_internal(Id) ->
    maybe
        {ok, #{type := ?GENERATED_KEY_TYPE} = SecretProps} ?= get_secret(Id),
        ?log_info("Rotating secret #~b", [Id]),
        {ok, NewKey} ?= generate_key(erlang:universaltime(), SecretProps),
        ok ?= add_active_key(Id, NewKey),
        sync_with_all_node_monitors(),
        ok
    else
        {ok, #{}} ->
            ?log_info("Secret #~p rotation failed: not_supported", [Id]),
            {error, not_supported};
        {error, Reason} ->
            ?log_error("Secret #~p rotation failed: ~p", [Id, Reason]),
            {error, Reason}
    end.

-spec get_active_key_id(secret_id(), chronicle_snapshot()) ->
                                            {ok, kek_id()} |
                                            {error, not_found | not_supported}.
get_active_key_id(SecretId, Snapshot) ->
    maybe
        {ok, SecretProps} ?= get_secret(SecretId, Snapshot),
        {ok, _} ?= get_active_key_id_from_secret(SecretProps)
    else
        {error, _} = Err -> Err
    end.

-spec sync_with_node_monitor() -> ok.
sync_with_node_monitor() ->
    %% Mostly needed to make sure local cb_cluster_secret has pushed all new
    %% keys to disk before we try using them.
    %% chronicle_kv:sync() makes sure we have the latest chronicle data
    %% chronicle_compat_events:sync() makes sure all notifications has been sent
    %% sync([node()]) makes sure local cb_cluster_secret has handled that
    %% notification
    ok = chronicle_kv:sync(kv, ?SYNC_TIMEOUT),
    chronicle_compat_events:sync(),
    gen_server:call(?MODULE, sync, ?SYNC_TIMEOUT).

-spec ensure_can_encrypt_bucket(secret_id(), string(), chronicle_snapshot()) ->
                                        ok | {error, not_allowed | not_found}.
ensure_can_encrypt_bucket(SecretId, BucketName, Snapshot) ->
    maybe
        {ok, SecretProps} ?= get_secret(SecretId, Snapshot),
        true ?= can_secret_props_encrypt_bucket(SecretProps, BucketName),
        ok
    else
        false -> {error, not_allowed};
        {error, not_found} -> {error, not_found}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Type]) ->
    EventFilter =
        fun (?CHRONICLE_SECRETS_KEY) -> true;
            (_Key) -> false
        end,
    Self = self(),
    chronicle_compat_events:subscribe(
      EventFilter, fun (Key) -> Self ! {config_change, Key} end),
    Jobs = case Type of
               ?MASTER_PROC ->
                   [maybe_reencrypt_secrets];
               ?NODE_PROC ->
                   [ensure_all_keks_on_disk,
                    maybe_reencrypt_per_node_deks]
           end,
    {ok, work(#state{proc_type = Type, jobs = Jobs})}.

handle_call({call, {M, F, A} = MFA}, _From,
            #state{proc_type = ?MASTER_PROC} = State) ->
    try
        ?log_debug("Calling ~p", [MFA]),
        {reply, {succ, erlang:apply(M, F, A)}, State}
    catch
        C:E:ST ->
            ?log_warning("Call ~p failed: ~p:~p~n~p", [MFA, C, E, ST]),
            {reply, {exception, {C, E, ST}}, State}
    end;

handle_call(sync, _From, #state{proc_type = ?NODE_PROC} = State) ->
    {reply, ok, State};

handle_call(Request, _From, State) ->
    ?log_warning("Unhandled call: ~p", [Request]),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?log_warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({config_change, ?CHRONICLE_SECRETS_KEY} = Msg,
            #state{proc_type = ?NODE_PROC} = State) ->
    ?log_debug("Secrets in chronicle have changed..."),
    misc:flush(Msg),
    NewJobs = [ensure_all_keks_on_disk,  %% Adding keks + AWS key change
               maybe_reencrypt_per_node_deks], %% Keks rotation
    {noreply, add_jobs(NewJobs, State)};

handle_info({config_change, ?CHRONICLE_SECRETS_KEY} = Msg,
            #state{proc_type = ?MASTER_PROC} = State) ->
    ?log_debug("Secrets in chronicle have changed..."),
    misc:flush(Msg),
    NewJobs = [maybe_reencrypt_secrets], %% Modififcation of encryptBy or
                                         %% rotation of secret that encrypts
                                         %% other secrets
    {noreply, add_jobs(NewJobs, State)};

handle_info({config_change, _}, State) ->
    {noreply, State};

handle_info({timer, retry_jobs}, State) ->
    ?log_debug("Retrying jobs"),
    misc:flush({timer, retry_jobs}),
    {noreply, work(State)};

handle_info(Info, State) ->
    ?log_warning("Unhandled info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec generate_key(Creation :: calendar:datetime(), secret_props()) ->
                                            {ok, kek_props()} |
                                            {error, bad_encrypt_id()}.
generate_key(CreationDateTime, #{data := SecretData}) ->
    maybe
        Key = generate_raw_key(?ENVELOP_CIPHER),
        {ok, EncryptedBy} ?=
            case SecretData of
                #{encrypt_by := nodeSecretManager} -> {ok, undefined};
                #{encrypt_by := clusterSecret,
                  encrypt_secret_id := EncSecretId} ->
                    case get_active_key_id(EncSecretId, direct) of
                        {ok, EncKekId} ->
                            {ok, {EncSecretId, EncKekId}};
                        {error, not_found} ->
                            {error, {encrypt_id, not_found}};
                        {error, not_supported} ->
                            {error, {encrypt_id, not_allowed}}
                    end
            end,
        KeyProps = #{id => misc:uuid_v4(),
                     creation_time => CreationDateTime,
                     key => {sensitive, Key},
                     encrypted_by => undefined},
        case maybe_reencrypt_kek(KeyProps, EncryptedBy) of
            no_change -> {ok, KeyProps};
            NewKeyProps -> {ok, NewKeyProps}
        end
    else
        {error, Reason} -> {error, Reason}
    end.

-spec set_active_key_in_props(secret_props(), kek_id()) -> secret_props().
set_active_key_in_props(#{type := ?GENERATED_KEY_TYPE,
                          data := Data} = SecretProps,
                        KeyId) ->
    SecretProps#{data => Data#{active_key_id => KeyId}}.

-spec set_keys_in_props(secret_props(), [kek_props()]) -> secret_props().
set_keys_in_props(#{type := ?GENERATED_KEY_TYPE, data := Data} = SecretProps,
                  Keys) ->
    SecretProps#{data => Data#{keys => Keys}}.

-spec copy_static_props(secret_props(), secret_props()) -> secret_props().
%% Copies properties that secret can never change
copy_static_props(#{type := Type, id := Id,
                    creation_time := CreationDT} = OldSecretProps,
                  #{type := Type} = NewSecretProps) ->
    NewSecretProps2 = NewSecretProps#{id => Id, creation_time => CreationDT},
    case NewSecretProps2 of
        #{type := ?GENERATED_KEY_TYPE} ->
            #{data := #{active_key_id := OldActiveId, keys := Keys}} =
                OldSecretProps,
            functools:chain(NewSecretProps2,
                            [set_keys_in_props(_, Keys),
                             set_active_key_in_props(_, OldActiveId)]);
        #{type := ?AWSKMS_KEY_TYPE} ->
            #{data := #{uuid := UUID}} = OldSecretProps,
            #{data := NewData} = NewSecretProps2,
            NewSecretProps2#{data => NewData#{uuid => UUID}};
        _ ->
            NewSecretProps2
    end.

-spec replace_secret_in_list(secret_props(), [secret_props()]) ->
                                                      [secret_props()] | false.
replace_secret_in_list(NewProps, List) ->
    Id = maps:get(id, NewProps),
    ReplaceFun = fun Replace([], _Acc) -> false;
                     Replace([Next | Rest], Acc) ->
                         case maps:get(id, Next) of
                             Id -> lists:reverse([NewProps | Acc], Rest);
                             _ -> Replace(Rest, [Next | Acc])
                         end
                 end,
    ReplaceFun(List, []).

-spec add_active_key(secret_id(), kek_props()) -> ok | {error, not_found}.
add_active_key(Id, #{id := KekId, encrypted_by := EncryptedBy} = Kek) ->
    %% Id of the secret that encrypted that new kek
    ESecretId = case EncryptedBy of
                    undefined -> undefined;
                    {S, _} -> S
                end,
    RV = chronicle_kv:transaction(
           kv, [?CHRONICLE_SECRETS_KEY],
           fun (Snapshot) ->
               maybe
                   {ok, #{type := ?GENERATED_KEY_TYPE,
                          data := SecretData} = SecretProps} ?=
                       get_secret(Id, Snapshot),
                   #{keys := CurKeks} = SecretData,
                   ExpectedESecretId =
                      case SecretData of
                          #{encrypt_by := clusterSecret,
                            encrypt_secret_id := SId} -> SId;
                          #{encrypt_by := nodeSecretManager} -> undefined
                      end,
                   %% Making sure that encryption secret id hasn't changed
                   %% since we encrypted new active kek.
                   %% It should not normally happen because modification of
                   %% secrets and rotations are supposed to run in the same
                   %% process.
                   {expected, ExpectedESecretId} ?= {expected, ESecretId},

                   Updated = functools:chain(
                               SecretProps,
                               [set_keys_in_props(_, [Kek | CurKeks]),
                                set_active_key_in_props(_, KekId)]),
                   NewList = replace_secret_in_list(Updated,
                                                    get_all(Snapshot)),
                   true = is_list(NewList),
                   {commit, [{set, ?CHRONICLE_SECRETS_KEY, NewList}]}
               else
                   {error, not_found} ->
                       {abort, {error, not_found}};
                   {expected, _} ->
                       {abort, {error, encrypt_secret_has_changed}}
               end
           end),

    case RV of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec ensure_all_keks_on_disk() -> ok | {error, list()}.
ensure_all_keks_on_disk() ->
    RV = lists:map(fun (#{id := Id,
                          type := ?GENERATED_KEY_TYPE} = SecretProps)  ->
                           {Id, ensure_generated_keks_on_disk(SecretProps)};
                       (#{id := Id, type := ?AWSKMS_KEY_TYPE} = SecretProps) ->
                           {Id, ensure_aws_kek_on_disk(SecretProps)};
                       (#{id := Id}) ->
                           {Id, ok}
                   end, get_all()),
    misc:many_to_one_result(RV).

-spec ensure_generated_keks_on_disk(secret_props()) -> ok | {error, list()}.
ensure_generated_keks_on_disk(#{type := ?GENERATED_KEY_TYPE, id := SecretId,
                                data := #{keys := Keys}}) ->
    ?log_debug("Ensure all keys are on disk for secret ~p "
               "(number of keys to check: ~b)", [SecretId, length(Keys)]),
    Res = lists:map(fun (#{id := Id} = K) ->
                        {Id, ensure_kek_on_disk(K)}
                    end, Keys),
    misc:many_to_one_result(Res).

-spec ensure_kek_on_disk(kek_props()) -> ok | {error, _}.
ensure_kek_on_disk(#{id := Id, key := {sensitive, Key},
                     encrypted_by := undefined}) ->
    encryption_service:store_kek(Id, Key, _IsEncrypted = false, undefined);
ensure_kek_on_disk(#{id := Id, key := {encrypted_binary, Key},
                     encrypted_by := {_ESecretId, EKekId}}) ->
    encryption_service:store_kek(Id, Key, _IsEncrypted = true, EKekId).

-spec ensure_aws_kek_on_disk(secret_props()) -> ok | {error, _}.
ensure_aws_kek_on_disk(#{data := Data}) ->
    #{uuid := UUID, key_arn := KeyArn, region := Region, profile := Profile,
      config_file := ConfigFile, credentials_file := CredsFile,
      use_imds := UseIMDS} = Data,
    encryption_service:store_awskey(UUID, KeyArn, Region, Profile,
                                    CredsFile, ConfigFile, UseIMDS).

-spec prepare_new_secret(secret_props()) ->
            {ok, secret_props()} | {error, not_supported | bad_encrypt_id()}.
prepare_new_secret(#{type := ?GENERATED_KEY_TYPE,
                     creation_time := CurrentTime} = Props) ->
    maybe
        %% Creating new auto-generated key
        {ok, #{id := KekId} = KeyProps} ?= generate_key(CurrentTime, Props),
        {ok, functools:chain(Props, [set_keys_in_props(_, [KeyProps]),
                                     set_active_key_in_props(_, KekId)])}
    else
        {error, _} = Error -> Error
    end;
prepare_new_secret(#{type := ?AWSKMS_KEY_TYPE, data := Data} = Props) ->
    {ok, Props#{data => Data#{uuid => misc:uuid_v4()}}};
prepare_new_secret(#{type := _Type}) ->
    {error, not_supported}.

-spec maybe_reencrypt_per_node_deks() -> ok.
maybe_reencrypt_per_node_deks() ->
    %% TODO
    ok.

-spec validate_secret_in_txn(secret_props(), #{} | secret_props(),
                             chronicle_snapshot()) ->
                                            ok | {error, bad_encrypt_id() |
                                                         bad_usage_change()}.
validate_secret_in_txn(NewProps, PrevProps, Snapshot) ->
    maybe
        ok ?= validate_secrets_encryption_usage_change(NewProps, PrevProps,
                                                       Snapshot),
        ok ?= validate_encryption_secret_id(NewProps, Snapshot),
        ok ?= validate_bucket_encryption_usage_change(NewProps, PrevProps,
                                                      Snapshot)
    end.

-spec execute_on_master({module(), atom(), [term()]}) -> term().
execute_on_master({_, _, _} = MFA) ->
    misc:wait_for_global_name(cb_cluster_secrets_master),
    case gen_server:call(?MASTER_MONITOR_NAME, {call, MFA}, 60000) of
        {succ, Res} -> Res;
        {exception, {C, E, ST}} -> erlang:raise(C, E, ST)
    end.

-spec get_active_key_id_from_secret(secret_props()) -> {ok, kek_id()} |
                                                       {error, not_supported}.
get_active_key_id_from_secret(#{type := ?GENERATED_KEY_TYPE,
                                data := #{active_key_id := Id}}) ->
    {ok, Id};
get_active_key_id_from_secret(#{type := ?AWSKMS_KEY_TYPE,
                                data := #{uuid := UUID}}) ->
    {ok, UUID};
get_active_key_id_from_secret(#{}) ->
    {error, not_supported}.

-spec maybe_reencrypt_secrets() -> ok.
maybe_reencrypt_secrets() ->
    RV = chronicle_kv:transaction(
           kv, [?CHRONICLE_SECRETS_KEY],
           fun (Snapshot) ->
               All = get_all(Snapshot),
               KeksMap =
                   maps:from_list(
                     lists:filtermap(
                       fun (#{id := Id} = P) ->
                           maybe
                               {ok, KekId} ?= get_active_key_id_from_secret(P),
                               {true, {Id, KekId}}
                           else
                               {error, not_supported} ->
                                   false
                           end
                       end, All)),
               {Changed, Unchanged} =
                   misc:partitionmap(
                     fun (Secret) ->
                         case maybe_reencrypt_secret_txn(Secret, KeksMap) of
                             {true, NewSecret} -> {left, NewSecret};
                             false -> {right, Secret}
                         end
                     end, All),
               case Changed of
                   [] -> {abort, no_change};
                   [_ | _] ->
                       NewSecretsList = Changed ++ Unchanged,
                       {commit, [{set, ?CHRONICLE_SECRETS_KEY, NewSecretsList}]}
               end
           end),
    case RV of
        {commit, _} ->
            sync_with_node_monitor(),
            ok;
        no_change -> ok
    end.

-spec maybe_reencrypt_secret_txn(secret_props(), #{secret_id() := kek_id()}) ->
                                                false | {true, secret_props()}.
maybe_reencrypt_secret_txn(#{type := ?GENERATED_KEY_TYPE} = Secret, KeksMap) ->
    #{data := #{keys := Keys} = Data} = Secret,
    case maybe_reencrypt_keks(Keys, Secret, KeksMap) of
        {ok, NewKeks} -> {true, Secret#{data => Data#{keys => NewKeks}}};
        no_change -> false
    end;
maybe_reencrypt_secret_txn(#{}, _) ->
    false.

-spec maybe_reencrypt_keks([kek_props()], secret_props(),
                           #{secret_id() := kek_id()}) ->
                                                {ok, [kek_props()]} | no_change.
maybe_reencrypt_keks(Keys, #{data := SecretData}, KeksMap) ->
    NewEncryptedBy =
        case SecretData of
            #{encrypt_by := nodeSecretManager} -> undefined;
            #{encrypt_by := clusterSecret,
              encrypt_secret_id := TargetSecretId} ->
                TargetKekId = maps:get(TargetSecretId, KeksMap),
                {TargetSecretId, TargetKekId}
        end,
    RV = lists:mapfoldl(
           fun (Key, Acc) ->
               case maybe_reencrypt_kek(Key, NewEncryptedBy) of
                   no_change -> {Key, Acc};
                   NewKey -> {NewKey, changed}
               end
           end, no_change, Keys),
    case RV of
        {NewKeyList, changed} -> {ok, NewKeyList};
        {_, no_change} -> no_change
    end.

-spec maybe_reencrypt_kek(kek_props(), undefined | {secret_id(), kek_id()}) ->
                                                        no_change | kek_props().
%% Already encrypted with correct key
maybe_reencrypt_kek(#{key := {encrypted_binary, _},
                      encrypted_by := {SecretId, KekId}},
                    {SecretId, KekId}) ->
    no_change;
%% Encrypted with wrong key, should reencrypt
maybe_reencrypt_kek(#{key := {encrypted_binary, Bin},
                      encrypted_by := {_SecretId, KekId}} = Key,
                    {NewSecretId, NewKekId}) ->
    {ok, RawKey} = encryption_service:decrypt_key(Bin, KekId),
    {ok, EncryptedKey} = encryption_service:encrypt_key(RawKey, NewKekId),
    Key#{key => {encrypted_binary, EncryptedKey},
         encrypted_by => {NewSecretId, NewKekId}};
%% Encrypted, but we want it to be unencrypted (encrypted by node SM actually)
maybe_reencrypt_kek(#{key := {encrypted_binary, Bin},
                      encrypted_by := {_SecretId, KekId}} = Key,
                    undefined) ->
    {ok, RawKey} = encryption_service:decrypt_key(Bin, KekId),
    Key#{key => {sensitive, RawKey}, encrypted_by => undefined};
%% Not encrypted but should be
maybe_reencrypt_kek(#{key := {sensitive, Bin},
                      encrypted_by := undefined} = Key,
                    {NewSecretId, NewKekId}) ->
    {ok, EncryptedKey} = encryption_service:encrypt_key(Bin, NewKekId),
    Key#{key => {encrypted_binary, EncryptedKey},
         encrypted_by => {NewSecretId, NewKekId}};
%% Not encrypted, and that's right
maybe_reencrypt_kek(#{key := {sensitive, _Bin},
                      encrypted_by := undefined},
                    undefined) ->
    no_change.

-spec add_jobs([node_job()] | [master_job()], #state{}) -> #state{}.
add_jobs(NewJobs, #state{jobs = Jobs} = State) ->
    work(State#state{jobs = NewJobs ++ (Jobs -- NewJobs)}).

-spec work(#state{}) -> #state{}.
work(#state{jobs = Jobs} = State) ->
    NewJobs = lists:filter(
                fun (J) ->
                    ?log_debug("Starting job: ~p", [J]),
                    try do(J) of
                        ok ->
                            ?log_debug("Job complete: ~p", [J]),
                            false;
                        BadRes ->
                            ?log_error("Job ~p returned: ~p", [J, BadRes]),
                            true
                    catch
                        C:E:ST ->
                            ?log_error("Job ~p failed: ~p:~p~nStacktrace:~p~n"
                                       "State: ~p", [J, C, E, ST, State]),
                            true
                    end
                end, Jobs),
    UpdatedState = State#state{jobs = NewJobs},
    case NewJobs of
        [] -> stop_timer(retry_jobs, UpdatedState);
        [_ | _] -> restart_timer(retry_jobs, ?RETRY_TIME, UpdatedState)
    end.

-spec do(node_job() | master_job()) -> ok | {error, _}.
do(ensure_all_keks_on_disk) ->
    ensure_all_keks_on_disk();
do(maybe_reencrypt_secrets) ->
    maybe_reencrypt_secrets();
do(maybe_reencrypt_per_node_deks) ->
    maybe_reencrypt_per_node_deks().

-spec stop_timer(Name :: atom(), #state{}) -> #state{}.
stop_timer(Name, #state{timers = Timers} = State) ->
    case maps:get(Name, Timers) of
        undefined -> State;
        Ref ->
            erlang:cancel_timer(Ref),
            State#state{timers = Timers#{Name => undefined}}
    end.

-spec restart_timer(Name :: atom(), Time :: non_neg_integer(), #state{}) ->
          #state{}.
restart_timer(Name, Time, #state{timers = Timers} = State) ->
    NewState = stop_timer(Name, State),
    ?log_debug("Starting ~p timer for ~b...", [Name, Time]),
    Ref = erlang:send_after(Time, self(), {timer, Name}),
    NewState#state{timers = Timers#{Name => Ref}}.

-spec validate_encryption_secret_id(secret_props(), chronicle_snapshot()) ->
                    ok | {error, bad_encrypt_id()}.
validate_encryption_secret_id(#{type := ?GENERATED_KEY_TYPE,
                                data := #{encrypt_by := clusterSecret,
                                          encrypt_secret_id := Id}},
                              Snapshot) ->
    case secret_can_encrypt_secrets(Id, Snapshot) of
        ok -> ok;
        {error, not_found} -> {error, {encrypt_id, not_found}};
        {error, not_allowed} -> {error, {encrypt_id, not_allowed}}
    end;
validate_encryption_secret_id(#{}, _Snapshot) ->
    ok.

-spec secret_can_encrypt_secrets(secret_id(), chronicle_snapshot()) ->
                                        ok | {error, not_found | not_allowed}.
secret_can_encrypt_secrets(SecretId, Snapshot) ->
    case get_secret(SecretId, Snapshot) of
        {ok, #{usage := Usage}} ->
            case lists:member(secrets_encryption, Usage) of
                true -> ok;
                false -> {error, not_allowed}
            end;
        {error, not_found} -> {error, not_found}
    end.

-spec validate_secrets_encryption_usage_change(secret_props(),
                                               #{} | secret_props(),
                                               chronicle_snapshot()) ->
                                            ok | {error, bad_usage_change()}.
validate_secrets_encryption_usage_change(NewProps, PrevProps, Snapshot) ->
    PrevUsage = maps:get(usage, PrevProps, []),
    NewUsage = maps:get(usage, NewProps, []),
    case (not lists:member(secrets_encryption, NewUsage)) andalso
         (lists:member(secrets_encryption, PrevUsage)) of
        true ->
            #{id := PrevId} = PrevProps,
            case secret_encrypts_other_secrets(PrevId, Snapshot) of
                true -> {error, {usage, in_use}};
                false -> ok
            end;
        false ->
            ok
    end.

-spec secret_encrypts_other_secrets(secret_id(), chronicle_snapshot()) ->
                                                                    boolean().
secret_encrypts_other_secrets(Id, Snapshot) ->
    lists:any(fun (#{type := ?GENERATED_KEY_TYPE,
                     data := #{encrypt_by := clusterSecret,
                               encrypt_secret_id := EncId}}) ->
                      EncId == Id;
                  (#{}) ->
                      false
              end, get_all(Snapshot)).

-dialyzer({nowarn_function, validate_bucket_encryption_usage_change/3}).
-spec validate_bucket_encryption_usage_change(secret_props(),
                                              #{} | secret_props(),
                                              chronicle_snapshot()) ->
                                            ok | {error, bad_usage_change()}.
validate_bucket_encryption_usage_change(_NewProps, PrevProps, _Snapshot)
                                        when map_size(PrevProps) == 0 ->
    %% it is a new secret
    ok;
validate_bucket_encryption_usage_change(NewProps, #{id := PrevId}, Snapshot) ->
    case lists:all(
           fun (Bucket) ->
               can_secret_props_encrypt_bucket(NewProps, Bucket)
           end,
           get_buckets_by_secret_id(PrevId, Snapshot)) of
        true -> ok;
        false -> {error, {usage, in_use}}
    end.

-spec can_secret_props_encrypt_bucket(secret_props(), string()) -> boolean().
can_secret_props_encrypt_bucket(#{usage := List}, BucketName) ->
    lists:any(fun ({bucket_encryption, "*"}) -> true;
                  ({bucket_encryption, B}) -> B == BucketName;
                  (_) -> false
              end, List).

-spec sync_with_all_node_monitors() -> ok | {error, [atom()]}.
sync_with_all_node_monitors() ->
    Nodes = ns_node_disco:nodes_actual(),
    Res = erpc:multicall(Nodes, ?MODULE, sync_with_node_monitor, [],
                         ?SYNC_TIMEOUT),
    BadNodes = lists:filtermap(
                 fun ({_Node, {ok, _}}) ->
                         false;
                     ({Node, {Class, Exception}}) ->
                         ?log_error("Node ~p sync failed: ~p ~p",
                                    [Node, Class, Exception]),
                         {true, Node}
                 end, lists:zip(Nodes, Res)),
    case BadNodes of
        [] -> ok;
        _ ->
            ?log_error("Sync failed, bad nodes: ~p", [BadNodes]),
            {error, BadNodes}
    end.

-spec get_buckets_by_secret_id(secret_id(), chronicle_snapshot()) -> [string()].
get_buckets_by_secret_id(Id, Snapshot) ->
    Buckets = ns_bucket:get_bucket_names(Snapshot),
    lists:filter(fun (B) ->
                     {ok, BConfig} = ns_bucket:get_bucket(B),
                     Id == proplists:get_value(encryption_secret_id, BConfig)
                 end, Buckets).

-ifdef(TEST).
replace_secret_in_list_test() ->
    ?assertEqual(false, replace_secret_in_list(#{id => 3, p => 5}, [])),
    ?assertEqual(false,
                 replace_secret_in_list(#{id => 3, p => 5}, [#{id => 4}])),
    ?assertEqual([#{id => 4, p => 1}, #{id => 3, p => 5}, #{id => 1}],
                 replace_secret_in_list(
                   #{id => 3, p => 5},
                   [#{id => 4, p => 1}, #{id => 3, p => 6}, #{id => 1}])).
-endif.
