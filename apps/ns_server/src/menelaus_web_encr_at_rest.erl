%% @author Couchbase <info@couchbase.com>
%% @copyright 2024-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(menelaus_web_encr_at_rest).

-include("ns_common.hrl").
-include_lib("ns_common/include/cut.hrl").
-include("cb_cluster_secrets.hrl").

-export([handle_get/2, handle_post/2, get_settings/1, handle_drop_keys/2,
         handle_bucket_drop_keys/2]).

encr_method(Param, EncrType) ->
    {Param,
     #{cfg_key => [EncrType, encryption],
       type => {one_of, existing_atom,
                [disabled, encryption_service, secret]}}}.

encr_secret_id(Param, EncrType) ->
    {Param,
     #{cfg_key => [EncrType, secret_id],
       type => {int, -1, infinity}}}.

encr_dek_lifetime(Param, EncrType) ->
    {Param,
     #{cfg_key => [EncrType, dek_lifetime_in_sec],
       type => {int, 0, infinity}}}.

encr_dek_rotate_intrvl(Param, EncrType) ->
    {Param,
     #{cfg_key => [EncrType, dek_rotation_interval_in_sec],
       type => {int, 0, infinity}}}.

encr_deks_drop_date(Param, EncrType) ->
    {Param,
     #{cfg_key => [EncrType, dek_drop_datetime],
       type => {read_only, {optional, datetime_iso8601}}}}.

params() ->
    [encr_method("config.encryptionMethod", config_encryption),
     encr_method("log.encryptionMethod", log_encryption),
     encr_method("audit.encryptionMethod", audit_encryption),

     encr_secret_id("config.encryptionSecretId", config_encryption),
     encr_secret_id("log.encryptionSecretId", log_encryption),
     encr_secret_id("audit.encryptionSecretId", audit_encryption),

     encr_dek_lifetime("config.dekLifetime", config_encryption),
     encr_dek_lifetime("log.dekLifetime", log_encryption),
     encr_dek_lifetime("audit.dekLifetime", audit_encryption),

     encr_dek_rotate_intrvl("config.dekRotationInterval", config_encryption),
     encr_dek_rotate_intrvl("log.dekRotationInterval", log_encryption),
     encr_dek_rotate_intrvl("audit.dekRotationInterval", audit_encryption),

     encr_deks_drop_date("config.dekLastDropDate", config_encryption),
     encr_deks_drop_date("log.dekLastDropDate", log_encryption),
     encr_deks_drop_date("audit.dekLastDropDate", audit_encryption)].

handle_get(Path, Req) ->
    Settings = get_settings(direct),
    List = maps:to_list(maps:map(fun (_, V) -> maps:to_list(V) end, Settings)),
    menelaus_web_settings2:handle_get(Path, params(), undefined, List, Req).

handle_post(Path, Req) ->
    menelaus_web_settings2:handle_post(
      fun (Params, Req2) ->
          NewSettings = maps:map(fun (_, V) -> maps:from_list(V) end,
                                 maps:groups_from_list(
                                   fun ({[K1, _K2], _V}) -> K1 end,
                                   fun ({[_K1, K2], V}) -> {K2, V} end,
                                   Params)),
          RV = chronicle_kv:transaction(
                 kv, [?CHRONICLE_SECRETS_KEY,
                      ?CHRONICLE_ENCR_AT_REST_SETTINGS_KEY],
                 fun (Snapshot) ->
                     MergedNewSettings = get_settings(Snapshot, NewSettings),
                     ToApply = apply_auto_fields(
                                 Snapshot, MergedNewSettings),
                     case validate_all_settings_txn(maps:to_list(ToApply),
                                                    Snapshot) of
                         ok ->
                             {commit, [{set,
                                        ?CHRONICLE_ENCR_AT_REST_SETTINGS_KEY,
                                        ToApply}]};
                         {error, _} = Error ->
                             {abort, Error}
                     end
                 end),
         case RV of
             {ok, _} ->
                 cb_cluster_secrets:sync_with_all_node_monitors(),
                 handle_get(Path, Req2);
             {error, Msg} ->
                 menelaus_util:reply_global_error(Req2, Msg)
         end
      end, Path, params(), undefined, Req).

handle_bucket_drop_keys(Bucket, Req) ->
    handle_set_drop_time(
      fun (Time) ->
          Key = ns_bucket:sub_key(Bucket, encr_at_rest),
          chronicle_kv:transaction(
            kv, [ns_bucket:root(), ns_bucket:sub_key(Bucket, props), Key],
            fun (Snapshot) ->
                case ns_bucket:bucket_exists(Bucket, Snapshot) of
                    true ->
                        CurVal = chronicle_compat:get(Snapshot, Key,
                                                      #{default => #{}}),
                        NewVal = CurVal#{dek_drop_datetime => Time},
                        {commit, [{set, Key, NewVal}]};
                    false ->
                        menelaus_util:web_exception(
                          404, "Requested resource not found.\r\n")
                end
            end)
      end, Req).

handle_drop_keys(TypeName, Req) ->
    handle_set_drop_time(
      fun (Time) ->
          TypeKey =
              case TypeName of
                  "config" -> config_encryption
                  %% assuming other types will be added soon
              end,
          chronicle_kv:transaction(
            kv, [?CHRONICLE_ENCR_AT_REST_SETTINGS_KEY],
            fun (Snapshot) ->
                AllSettings = chronicle_compat:get(
                                Snapshot,
                                ?CHRONICLE_ENCR_AT_REST_SETTINGS_KEY,
                                #{default => #{}}),
                SubSettings = maps:get(TypeKey, AllSettings, #{}),
                NewSubSetting = SubSettings#{dek_drop_datetime => {set, Time}},
                NewSettings = AllSettings#{TypeKey => NewSubSetting},
                {commit,
                 [{set, ?CHRONICLE_ENCR_AT_REST_SETTINGS_KEY, NewSettings}]}
            end)
      end, Req).

handle_set_drop_time(SetTimeFun, Req) ->
    validator:handle(
      fun (ParsedList) ->
          Time = case proplists:get_value(datetime, ParsedList) of
                     undefined -> calendar:universal_time();
                     DT -> DT
                 end,
          SetTimeFun(Time),
          Reply = {[{dropKeysDate, iso8601:format(Time)}]},
          menelaus_util:reply_json(Req, Reply)
      end, Req, form, [validator:iso_8601_parsed(datetime, _),
                       validator:unsupported(_)]).

validate_all_settings_txn([], _Snapshot) -> ok;
validate_all_settings_txn([{Usage, Cfg} | Tail], Snapshot) ->
    maybe
        ok ?= validate_sec_settings(Usage, Cfg, Snapshot),
        ok ?= validate_no_unencrypted_secrets(Usage, Cfg, Snapshot),
        validate_all_settings_txn(Tail, Snapshot)
    end.

get_settings(Snapshot) -> get_settings(Snapshot, #{}).
get_settings(Snapshot, ExtraSettings) ->
    Merge = fun (Settings1, Settings2) ->
                maps:merge_with(fun (_K, V1, V2) -> maps:merge(V1, V2) end,
                                Settings1, Settings2)
            end,
    Settings = chronicle_compat:get(Snapshot,
                                    ?CHRONICLE_ENCR_AT_REST_SETTINGS_KEY,
                                    #{default => #{}}),
    Merge(Merge(defaults(), Settings), ExtraSettings).

defaults() ->
    #{config_encryption => #{encryption => encryption_service,
                             secret_id => ?SECRET_ID_NOT_SET,
                             dek_lifetime_in_sec => 365*60*60*24,
                             dek_rotation_interval_in_sec => 30*60*60*24,
                             dek_drop_datetime => {not_set, ""}},
      log_encryption => #{encryption => disabled,
                          secret_id => ?SECRET_ID_NOT_SET,
                          dek_lifetime_in_sec => 365*60*60*24,
                          dek_rotation_interval_in_sec => 30*60*60*24,
                          dek_drop_datetime => {not_set, ""}},
      audit_encryption => #{encryption => disabled,
                            secret_id => ?SECRET_ID_NOT_SET,
                            dek_lifetime_in_sec => 365*60*60*24,
                            dek_rotation_interval_in_sec => 30*60*60*24,
                            dek_drop_datetime => {not_set, ""}}}.

validate_no_unencrypted_secrets(config_encryption,
                                #{encryption := disabled,
                                  secret_id := ?SECRET_ID_NOT_SET}, Snapshot) ->
    Secrets = lists:filter(
                fun cb_cluster_secrets:is_encrypted_by_secret_manager/1,
                cb_cluster_secrets:get_all(Snapshot)),
    Names = lists:map(fun (#{name := Name}) -> Name end, Secrets),
    case Names of
        [] -> ok;
        [_ | _] ->
            NamesStr = lists:join(", ", Names),
            {error, "Encryption can't be disabled because it will leave "
                    "some cluster secrets unencrypted: " ++ NamesStr}
    end;
validate_no_unencrypted_secrets(_, #{}, _Snapshot) ->
    ok.

validate_sec_settings(_, #{encryption := disabled,
                           secret_id := ?SECRET_ID_NOT_SET}, _) ->
    ok;
validate_sec_settings(_, #{encryption := disabled,
                           secret_id := _}, _) ->
    {error, "Secret id must not be set when encryption is disabled"};
validate_sec_settings(_, #{encryption := encryption_service,
                           secret_id := ?SECRET_ID_NOT_SET}, _) ->
    ok;
validate_sec_settings(_, #{encryption := encryption_service,
                           secret_id := _}, _) ->
    {error, "Secret id must not be set when encryption_service is used"};
validate_sec_settings(_, #{encryption := secret,
                        secret_id := ?SECRET_ID_NOT_SET}, _) ->
    {error, "Secret id must be set"};
validate_sec_settings(Name, #{encryption := secret,
                              secret_id := Id}, Snapshot) ->
    case cb_cluster_secrets:is_allowed_usage_for_secret(Id, Name, Snapshot) of
        ok -> ok;
        {error, not_found} -> {error, "Secret not found"};
        {error, not_allowed} -> {error, "Secret not allowed"}
    end.

apply_auto_fields(Snapshot, NewSettings) ->
    CurSettings = get_settings(Snapshot),
    IsEnabled = fun (S) -> maps:get(encryption, S) == disabled end,
    maps:fold(
      fun (T, V1, Acc) ->
          #{T := V2} = Acc,
          case IsEnabled(V1) /= IsEnabled(V2) of
              true -> Acc#{T => V2#{encryption_last_toggle_datetime =>
                                        calendar:universal_time()}};
              false -> Acc
          end
      end, NewSettings, CurSettings).
