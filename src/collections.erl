%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%

%% @doc methods for handling collections

-module(collections).

-include("cut.hrl").
-include("ns_common.hrl").
-include("ns_test.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_link/0,
         enabled/0,
         enabled/1,
         default_manifest/1,
         default_kvs/2,
         uid/1,
         uid/2,
         manifest_json/2,
         manifest_json/3,
         create_scope/2,
         create_collection/4,
         modify_collection/4,
         drop_scope/2,
         drop_collection/3,
         system_collections/0,
         bump_epoch/1,
         wait_for_manifest_uid/5,
         convert_uid_from_memcached/1,
         convert_uid_to_memcached/1,
         key_match/1,
         change/1,
         key/1,
         get_manifest/2,
         get_manifest/3,
         set_manifest/4,
         get_scope/2,
         get_collection/2,
         get_max_supported/1,
         get_uid/1,
         get_collection_uid/3,
         get_scopes/1,
         get_collections/1,
         diff_manifests/2,
         last_seen_ids_key/2,
         last_seen_ids_set/3,
         chronicle_upgrade_to_72/2]).

%% rpc from other nodes
-export([wait_for_manifest_uid/4]).

-define(EPOCH, 16#1000).

start_link() ->
    work_queue:start_link(
      ?MODULE,
      fun () ->
              work_queue:submit_work(?MODULE,
                                     fun update_last_seen_ids/0),
              chronicle_compat_events:subscribe(
                fun (Key) ->
                        case key_match(Key) of
                            {true, Bucket} ->
                                work_queue:submit_work(
                                  ?MODULE, ?cut(update_last_seen_ids(Bucket)));
                            false ->
                                ok
                        end
                end)
      end).

enabled() ->
    cluster_compat_mode:is_enabled(?VERSION_70).

enabled(BucketConfig) ->
    enabled() andalso ns_bucket:bucket_type(BucketConfig) =:= membase.

key(Bucket) ->
    ns_bucket:sub_key(Bucket, collections).

key_match(Key) ->
    case ns_bucket:sub_key_match(Key) of
        {true, Bucket, collections} ->
            {true, Bucket};
        _ ->
            false
    end.

change(Key) ->
    key_match(Key) =/= false.

default_manifest(BucketConf) ->
    case is_system_scope_enabled() of
        false ->
            manifest_without_system_scope(BucketConf);
        true ->
            manifest_with_system_scope(BucketConf)
    end.

historic_default_collection_props() ->
    [{uid, 0}].

get_default_collection_props(BucketConf) ->
    case ns_bucket:history_retention_collection_default(BucketConf) of
        false ->
            historic_default_collection_props();
        true ->
            historic_default_collection_props() ++ [{history, true}]
    end.

manifest_without_system_scope(BucketConf) ->
    StartUid =
        case ns_bucket:history_retention_collection_default(BucketConf) of
            false ->
                %% Historic default manifest
                0;
            true ->
                %% Memcached may treat manifest uid = 0 as a special case
                %% ("epoch"). Start the manifest uid at 1 rather than 0 to
                %% ensure that it is treated like any normal update.
                1
        end,

    [{uid, StartUid},
     {next_uid, StartUid + 1},
     {next_scope_uid, 8},
     {next_coll_uid, 8},
     {num_scopes, 0},
     {num_collections, 0},
     {scopes,
      [{"_default",
        [{uid, 0},
         {collections,
          [{"_default",
              get_default_collection_props(BucketConf)}]}]}]}].

system_collections() ->
    ["_eventing", "_mobile", "_query", "_transactions"].

manifest_with_system_scope(BucketConf) ->
    {NextId, Collections} =
        lists:foldl(
          fun (Name, {Id, Cols}) ->
                  %% Note, not adding history to system collections. They
                  %% probably don't want to assume that history is available,
                  %% but we can change this in the future if necessary
                  {Id + 1, [{Name, [{uid, Id}, {"metered", false}]}] ++ Cols}
          end, {8, []}, system_collections()),

    [{uid, 1},
     {next_uid, 2},
     {next_scope_uid, 9},
     {next_coll_uid, NextId},
     {num_scopes, 0},
     {num_collections, 0},
     {scopes,
      [{"_default",
        [{uid, 0},
         {collections,
          [{"_default",
            get_default_collection_props(BucketConf)}]}]},
       {?SYSTEM_SCOPE_NAME,
        [{uid, 8},
         {collections, Collections}]}]}].

is_system_scope_enabled() ->
    config_profile:get_bool(enable_system_scope).

max_collections_per_bucket() ->
    Default = get_max_supported(num_collections),
    config_profile:get_value(max_collections_per_bucket, Default).

max_scopes_per_bucket() ->
    Default = get_max_supported(num_scopes),
    config_profile:get_value(max_scopes_per_bucket, Default).

default_kvs(Buckets, Nodes) ->
    lists:flatmap(
      fun (Bucket) ->
              {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
              Manifest = default_manifest(BucketConfig),
              [{key(Bucket), Manifest} |
               [{last_seen_ids_key(Node, Bucket), get_next_uids(Manifest)} ||
                   Node <- Nodes]]
      end,  ns_bucket:get_bucket_names_of_type(membase, Buckets)).

with_scope(Fun, ScopeName, Manifest) ->
    Scopes = get_scopes(Manifest),
    case find_scope(ScopeName, Scopes) of
        undefined ->
            {scope_not_found, ScopeName};
        Scope ->
            Fun(Scope)
    end.

with_collection(Fun, ScopeName, CollectionName, Manifest) ->
    with_scope(
      fun (Scope) ->
              Collections = get_collections(Scope),
              case find_collection(CollectionName, Collections) of
                  undefined ->
                      {collection_not_found, ScopeName, CollectionName};
                  Props ->
                      Fun(Props)
              end
      end, ScopeName, Manifest).

-spec get_collection_uid(bucket_name(), string(), string()) ->
          {ok, integer()} |
          {atom(), string()}.
get_collection_uid(Bucket, ScopeName, CollectionName) ->
    Manifest = get_manifest(Bucket, direct),
    true = Manifest =/= undefined,
    with_collection(?cut({ok, get_uid(_)}), ScopeName,
                    CollectionName, Manifest).

uid(Bucket, Snapshot) ->
    case get_manifest(Bucket, Snapshot) of
        undefined ->
            undefined;
        Manifest ->
            uid(Manifest)
    end.

get_uid(Props) ->
    proplists:get_value(uid, Props).

convert_uid_to_memcached(V) ->
    list_to_binary(string:to_lower(integer_to_list(V, 16))).

convert_uid_from_memcached(V) when is_list(V) ->
    list_to_integer(V, 16);
convert_uid_from_memcached(V) when is_binary(V) ->
    convert_uid_from_memcached(binary_to_list(V)).

uid(Props) ->
    convert_uid_to_memcached(get_uid(Props)).

collection_prop_to_memcached(uid, V) ->
    convert_uid_to_memcached(V);
collection_prop_to_memcached(_, V) ->
    V.

%% The default collection properties. These properties may not be specified but
%% can be inferred from the collections manifest if not specified. This has two
%% benefits:
%%
%% 1) Reduces the size of the manifest
%% 2) Improves readability of the manifest
default_collection_props() ->
    [{maxTTL, 0}, {history, false}].

collection_to_memcached(Name, Props, WithDefaults) ->
    AdjustedProps =
        case WithDefaults of
            true ->
                misc:update_proplist(default_collection_props(), Props);
            false ->
                Props
        end,
    {[{name, list_to_binary(Name)} |
      [{K, collection_prop_to_memcached(K, V)} || {K, V} <- AdjustedProps]]}.

filter_scopes_with_roles(Bucket, Scopes, Roles) ->
    lists:filter(
      fun ({ScopeName, _Scope}) ->
              menelaus_roles:is_allowed(
                {[{collection, [Bucket, ScopeName, all]}, collections], write},
                Roles)
      end, Scopes).

filter_system_scopes(Scopes) ->
    lists:filter(
      fun ({?SYSTEM_SCOPE_NAME, _Scope}) -> false;
          ({_, _}) -> true
      end, Scopes).

filter_collections_with_roles(Bucket, Scopes, Roles) ->
    lists:filtermap(
      fun ({ScopeName, Scope}) ->
              case menelaus_roles:is_allowed(
                     {[{collection, [Bucket, ScopeName, any]},
                       collections], read}, Roles) of
                  false ->
                      false;
                  true ->
                      Filtered = lists:filter(
                                   fun ({CName, _Props}) ->
                                           menelaus_roles:is_allowed(
                                             {[{collection,
                                                [Bucket, ScopeName, CName]},
                                               collections], read}, Roles)
                                   end, get_collections(Scope)),
                      {true, {ScopeName, update_collections(Filtered, Scope)}}
              end
      end, Scopes).

manifest_json(Bucket, Snapshot) ->
    Manifest = get_manifest(Bucket, Snapshot),
    jsonify_manifest(Manifest, false).

manifest_json(AuthnRes, Bucket, Snapshot) ->
    Roles = menelaus_roles:get_compiled_roles(AuthnRes),
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket, Snapshot),
    DefaultManifest = default_manifest(BucketConfig),
    Manifest = get_manifest(Bucket, Snapshot, DefaultManifest),
    FilteredManifest = on_scopes(
                         filter_collections_with_roles(Bucket, _, Roles),
                         Manifest),
    jsonify_manifest(FilteredManifest, true).

jsonify_manifest(Manifest, WithDefaults) ->
    ScopesJson =
        lists:map(
          fun ({ScopeName, Scope}) ->
                  {[{name, list_to_binary(ScopeName)},
                    {uid, uid(Scope)},
                    {collections,
                     [collection_to_memcached(CollName, Coll, WithDefaults) ||
                         {CollName, Coll} <- get_collections(Scope)]}]}
          end, get_scopes(Manifest)),
    {[{uid, uid(Manifest)}, {scopes, ScopesJson}]}.

get_max_supported(num_scopes) ->
    get_max_supported_inner(max_scopes_count, ?MAX_SCOPES_SUPPORTED);
get_max_supported(num_collections) ->
    get_max_supported_inner(max_collections_count, ?MAX_COLLECTIONS_SUPPORTED).

get_max_supported_inner(Type, Max) ->
    case ns_config:search(Type) of
        {_, Value} ->
            Value;
        false ->
            case config_profile:get_value(cluster_scope_collection_limit,
                                          false) of
                unlimited ->
                    %% Effectively no limit
                    ?MC_MAXINT;
                false ->
                    Max
            end
    end.

create_scope(Bucket, Name) ->
    update(Bucket, {create_scope, Name}).

create_collection(Bucket, Scope, Name, Props) ->
    update(Bucket, {create_collection, Scope, Name, Props}).

modify_collection(Bucket, Scope, Name, Props) ->
    % Can't remove defaults here as we might be setting a value to the default
    update(Bucket, {modify_collection, Scope, Name, Props}).

drop_scope(Bucket, Name) ->
    update(Bucket, {drop_scope, Name}).

drop_collection(Bucket, Scope, Name) ->
    update(Bucket, {drop_collection, Scope, Name}).

bump_epoch(Bucket) ->
    update(Bucket, bump_epoch).

update(Bucket, Operation) ->
    work_queue:submit_sync_work(
      ?MODULE, ?cut(update_inner(Bucket, Operation))).

update_inner(Bucket, Operation) ->
    case do_update(Bucket, Operation) of
        {ok, _Rev, {UID, OperationsDone}} ->
            {ok, {UID, OperationsDone}};
        {not_changed, UID} ->
            {ok, UID};
        {error, Error} = RV ->
            ?log_debug("Operation ~p for bucket ~p failed with ~p",
                       [Operation, Bucket, RV]),
            Error
    end.

do_update(Bucket, Operation) ->
    ?log_debug("Performing operation ~p on bucket ~p", [Operation, Bucket]),
    %% Derive the total collection and scope that exist outside of this
    %% bucket context. We will use this information to check_limits later on.
    OtherBucketCounts = other_bucket_counts(Bucket),

    %% Likewise for per-bucket limits.
    ScopeCollectionLimits = {max_scopes_per_bucket(),
                             max_collections_per_bucket()},

    case get_last_seen_uids(Bucket, Operation) of
        not_found ->
            {error, not_found};
        LastSeenIdsWithUUID ->
            chronicle_kv:transaction(
              kv, [key(Bucket), ns_bucket:uuid_key(Bucket),
                   chronicle_master:failover_opaque_key()],
              update_txn(Bucket, Operation, OtherBucketCounts,
                         ScopeCollectionLimits, LastSeenIdsWithUUID, _),
              #{read_consistency => quorum})
    end.

update_txn(Bucket, Operation, OtherBucketCounts, ScopeCollectionLimits,
           {LastSeenIds, UUID}, Snapshot) ->
    case Operation =/= bump_epoch andalso
        maps:is_key(chronicle_master:failover_opaque_key(), Snapshot) of
        true ->
            {abort, {error, unfinished_failover}};
        false ->
            case UUID =:= no_check orelse
                ns_bucket:uuid(Bucket, Snapshot) =:= UUID of
                true ->
                    case get_manifest(Bucket, Snapshot) of
                        undefined ->
                            {abort, {error, not_found}};
                        Manifest ->
                            do_update_with_manifest(
                              Bucket, Manifest, Operation, OtherBucketCounts,
                              ScopeCollectionLimits, LastSeenIds)
                    end;
                false ->
                    {abort, {error, not_found}}
            end
    end.

do_update_with_manifest(Bucket, Manifest, Operation, OtherBucketCounts,
                        ScopeCollectionLimits, LastSeenIds) ->
    ?log_debug("Perform operation ~p on manifest ~p of bucket ~p",
               [Operation, get_uid(Manifest), Bucket]),
    CompiledOperation = compile_operation(Operation, Bucket, Manifest),
    case ns_bucket:get_bucket(Bucket) of
        {ok, BucketConf} ->
            case perform_operations(Manifest, CompiledOperation,
                                    BucketConf) of
                {ok, Manifest} ->
                    {abort, {not_changed, uid(Manifest)}};
                {ok, NewManifest} ->
                    case check_limits(NewManifest, OtherBucketCounts,
                                      ScopeCollectionLimits) of
                        ok ->
                            FinalManifest = advance_manifest_id(Operation,
                                                                NewManifest),
                            case check_ids_limit(FinalManifest, LastSeenIds) of
                                [] ->
                                    {commit,
                                     [{set, key(Bucket), FinalManifest}],
                                     {uid(FinalManifest), CompiledOperation}};
                                BehindNodes ->
                                    {abort,
                                        {error,
                                            {nodes_are_behind,
                                             [N || {N, _} <- BehindNodes]}}}
                            end;
                        Error ->
                            {abort, {error, Error}}
                    end;
                Error ->
                    {abort, {error, Error}}
            end;
        not_present ->
            {abort, {error, bucket_not_found, Bucket}}
    end.

advance_manifest_id(bump_epoch, Manifest) ->
    Manifest;
advance_manifest_id(_Operation, Manifest) ->
    bump_id(lists:keyreplace(uid, 1, Manifest,
                             {uid, proplists:get_value(next_uid, Manifest)}),
            next_uid).

perform_operations(_Manifest, {error, Error}, _BucketConf) ->
    Error;
perform_operations(Manifest, [], _BucketConf) ->
    {ok, Manifest};
perform_operations(Manifest, [Operation | Rest], BucketConf) ->
    case verify_oper(Operation, Manifest) of
        ok ->
            perform_operations(handle_oper(Operation, Manifest, BucketConf),
                               Rest, BucketConf);
        Error ->
            ?log_debug("Operation ~p failed with error ~p", [Operation, Error]),
            Error
    end.

check_ids_limit(_Manifest, no_check) ->
    [];
check_ids_limit(Manifest, LastSeenIds) ->
    IdsFromManifest = get_next_uids(Manifest),
    lists:filter(
      fun ({_, SeenByNode}) ->
              lists:any(fun ({A, B}) -> A - B >= ?EPOCH end,
                        lists:zip(IdsFromManifest, SeenByNode))
      end, LastSeenIds).

bump_id(Manifest, ID, Increment) ->
    misc:key_update(ID, Manifest, _ + Increment).

bump_id(Manifest, ID) ->
    bump_id(Manifest, ID, 1).

other_bucket_counts(Bucket) ->
    Snapshot = ns_bucket:get_snapshot(all, [collections]),
    Buckets = ns_bucket:get_bucket_names(Snapshot),
    lists:foldl(
      fun (B, {AccS, AccC} = Acc) ->
              case get_manifest(B, Snapshot) of
                  undefined ->
                      Acc;
                  Manifest ->
                      {AccS + get_counter(Manifest, num_scopes),
                       AccC + get_counter(Manifest, num_collections)}
              end
      end, {0, 0}, lists:delete(Bucket, Buckets)).

check_limits(NewManifest, {OtherScopeTotal, OtherCollectionTotal},
             {MaxScopesPerBucket, MaxCollectionsPerBucket}) ->
    NumScopes = get_counter(NewManifest, num_scopes),
    NumCollections = get_counter(NewManifest, num_collections),
    TotalScopes = NumScopes + OtherScopeTotal,
    TotalCollections = NumCollections + OtherCollectionTotal,

    case check_bucket_limit(num_scopes, NumScopes, MaxScopesPerBucket) of
        ok ->
            case check_bucket_limit(num_collections, NumCollections,
                                    MaxCollectionsPerBucket) of
                ok ->
                    case check_cluster_limit(num_scopes, TotalScopes) of
                        ok ->
                            check_cluster_limit(num_collections,
                                                TotalCollections);
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

check_bucket_limit(Counter, Number, Max) ->
    case Number > Max of
        false ->
            ok;
        true ->
            {bucket_limit, max_number_exceeded, Counter, Max}
    end.

check_cluster_limit(Counter, TotalInCluster) ->
    case TotalInCluster > get_max_supported(Counter) of
        false ->
            ok;
        true ->
            {max_number_exceeded, Counter}
    end.

remove_defaults(Props) ->
    Props -- default_collection_props().

get_operations(Fun, Current, Required) ->
    MapCurrent = maps:from_list(Current),
    MapRequired = maps:from_list(Required),
    FoldFun = ?cut([Fun(_) | _]),

    Deletes = maps:without(maps:keys(MapRequired), MapCurrent),
    DeleteOpers = maps:fold(?cut(FoldFun({delete, _, _}, _)), [], Deletes),

    lists:flatten(
      maps:fold(
        fun (Key, Value, Acc) ->
                case maps:find(Key, MapCurrent) of
                    {ok, CurrentValue} ->
                        FoldFun({modify, Key, Value, CurrentValue}, Acc);
                    error ->
                        FoldFun({add, Key, Value}, Acc)
                end
        end, DeleteOpers, MapRequired)).

get_operations(CurrentScopes, RequiredScopes) ->
    get_operations(
      fun ({delete, ScopeName, _}) ->
              {drop_scope, ScopeName};
          ({add, ScopeName, ScopeProps}) ->
              [{create_scope, ScopeName} |
               [{create_collection, ScopeName, CollectionName,
                 CollectionProps} ||
                   {CollectionName, CollectionProps}
                       <- get_collections(ScopeProps)]];
          ({modify, ScopeName, ScopeProps, CurrentScopeProps}) ->
              get_operations(
                fun ({delete, CollectionName, _}) ->
                        {drop_collection, ScopeName, CollectionName};
                    ({add, CollectionName, CollectionProps}) ->
                        {create_collection, ScopeName, CollectionName,
                         CollectionProps};
                    ({modify, CollectionName, CollectionProps,
                      CurrentCollectionProps}) ->
                        case lists:sort(CollectionProps) =:=
                             lists:sort(lists:keydelete(
                                          uid, 1, CurrentCollectionProps)) of
                            false ->
                                {modify_collection, ScopeName, CollectionName,
                                 CollectionProps};
                            true ->
                                []
                        end
                end, get_collections(CurrentScopeProps),
                get_collections(ScopeProps))
      end, CurrentScopes, RequiredScopes).

diff_scopes(CurrentScopes, RequiredScopes) ->
    get_operations(
      fun ({delete, ScopeName, ScopeProps}) ->
              {deleted_scope, ScopeName, ScopeProps};
          ({add, ScopeName, ScopeProps}) ->
              {new_scope, ScopeName, ScopeProps};
          ({modify, ScopeName, ScopeProps, CurrentScopeProps}) ->
              case get_uid(CurrentScopeProps) =:= get_uid(ScopeProps) of
                  true ->
                      diff_collections(ScopeName, CurrentScopeProps,
                                       ScopeProps);
                  false ->
                      [{deleted_scope, ScopeName, CurrentScopeProps},
                       {new_scope, ScopeName, ScopeProps}]
              end
      end, CurrentScopes, RequiredScopes).

diff_collections(ScopeName, CurrentScopeProps, ScopeProps) ->
    get_operations(
      fun ({delete, CollectionName, Props}) ->
              {deleted_collection, ScopeName, CollectionName, Props};
          ({add, CollectionName, CollectionProps}) ->
              {new_collection, ScopeName, CollectionName, CollectionProps};
          ({modify, CollectionName, CollectionProps, CurrentCollectionProps}) ->
              case lists:sort(CollectionProps) =:=
                  lists:sort(CurrentCollectionProps) of
                  false ->
                      [{deleted_collection, ScopeName, CollectionName,
                        CurrentCollectionProps},
                       {new_collection, ScopeName, CollectionName}];
                  true ->
                      []
              end
      end, get_collections(CurrentScopeProps),
      get_collections(ScopeProps)).

diff_manifests(NewManifest, OldManifest) ->
    NewScopes = get_scopes(NewManifest),
    OldScopes = get_scopes(OldManifest),
    lists:keyreplace(scopes, 1, NewManifest,
                     {scopes_diff, diff_scopes(OldScopes, NewScopes)}).

compile_operation({set_manifest, Roles, RequiredScopes0, CheckUid},
                  Bucket, Manifest) ->
    RequiredScopes = filter_system_scopes(RequiredScopes0),
    case filter_scopes_with_roles(Bucket, RequiredScopes, Roles) of
        RequiredScopes ->
            FilteredCurScopes = filter_scopes_with_roles(
                                  Bucket,
                                  filter_system_scopes(get_scopes(Manifest)),
                                  Roles),
            %% scope admin can delete it's own scope.
            [{check_uid, CheckUid} |
             get_operations(FilteredCurScopes, RequiredScopes)];
        _ ->
            %% Trying to create/delete scopes we don't have permissions to.
            {error, forbidden}
    end;
compile_operation(Oper, _Bucket, _Manifest) ->
    [Oper].

verify_oper({check_uid, CheckUid}, Manifest) ->
    ManifestUid = proplists:get_value(uid, Manifest),
    case CheckUid =:= ManifestUid orelse CheckUid =:= undefined of
        true ->
            ok;
        false ->
            uid_mismatch
    end;
verify_oper({create_scope, Name}, Manifest) ->
    Scopes = get_scopes(Manifest),
    case find_scope(Name, Scopes) of
        undefined ->
            ok;
        _ ->
            {scope_already_exists, Name}
    end;
verify_oper({drop_scope, "_default"}, _Manifest) ->
    cannot_drop_default_scope;
verify_oper({drop_scope, ?SYSTEM_SCOPE_NAME}, _Manifest) ->
    cannot_drop_system_scope;
verify_oper({drop_scope, Name}, Manifest) ->
    with_scope(fun (_) -> ok end, Name, Manifest);
verify_oper({create_collection, ScopeName, "_default", _}, _Manifest) ->
    {cannot_create_default_collection, ScopeName};
verify_oper({create_collection, ?SYSTEM_SCOPE_NAME, _Name, _},
            _Manifest) ->
    {cannot_create_collection_in_system_scope};
verify_oper({create_collection, ScopeName, Name, _}, Manifest) ->
    with_scope(
      fun (Scope) ->
              Collections = get_collections(Scope),
              case find_collection(Name, Collections) of
                  undefined ->
                      ok;
                  _ ->
                      {collection_already_exists, ScopeName, Name}
              end
      end, ScopeName, Manifest);
verify_oper({drop_collection, ?SYSTEM_SCOPE_NAME, "_" ++ _ = CollectionName},
            _Manifest) ->
    {cannot_drop_system_collection, ?SYSTEM_SCOPE_NAME, CollectionName};
verify_oper({drop_collection, ScopeName, Name}, Manifest) ->
    with_collection(fun (_) -> ok end, ScopeName, Name, Manifest);
verify_oper({modify_collection, ScopeName, Name, SuppliedProps},
            Manifest) ->
    %% We are only allowed to change history for a collection at the moment.
    AllowedCollectionPropChanges = [{history}],
    with_collection(
        fun (ExistingProps) ->
            %% When we store collections we strip them of their properties of
            %% default values for... reasons. To check whether or not we can
            %% ignore the modification of a collection property we must put the
            %% defaults back into the existing props
            AllExistingProps =
                lists:keymerge(1,
                    lists:keysort(1, ExistingProps),
                    lists:keysort(1, default_collection_props())),
            InvalidProps =
                lists:filter(
                    fun({Prop, Value}) ->
                        %% We allow the "modification" of properties with the
                        %% same value so that the set manifest path can specify
                        %% properties even if they do not change
                        ExistingPropValueEqual =
                            case proplists:get_value(Prop, AllExistingProps) of
                                Value -> true;
                                _ -> false
                            end,

                        not proplists:is_defined(Prop,
                                                 AllowedCollectionPropChanges)
                            andalso not ExistingPropValueEqual
                    end, SuppliedProps),
            case InvalidProps of
                [] -> ok;
                _ ->
                    {cannot_modify_properties, Name, InvalidProps}
            end
        end, ScopeName, Name, Manifest);
verify_oper(bump_epoch, _Manifest) ->
    ok.

handle_oper({check_uid, _CheckUid}, Manifest, _BucketConf) ->
    Manifest;
handle_oper({create_scope, Name}, Manifest, _BucketConf) ->
    functools:chain(
      Manifest,
      [add_scope(_, Name),
       bump_id(_, next_scope_uid),
       update_counter(_, num_scopes, 1)]);
handle_oper({drop_scope, Name}, Manifest, _BucketConf) ->
    NumCollections = length(get_collections(get_scope(Name, Manifest))),
    functools:chain(
      Manifest,
      [delete_scope(_, Name),
       update_counter(_, num_scopes, -1),
       update_counter(_, num_collections, -NumCollections)]);
handle_oper({create_collection, Scope, Name, Props}, Manifest, BucketConf) ->
    functools:chain(
      Manifest,
      [add_collection(_, Name, Scope, Props, BucketConf),
       bump_id(_, next_coll_uid),
       update_counter(_, num_collections, 1)]);
handle_oper({modify_collection, Scope, Name, Props}, Manifest, _BucketConf) ->
    modify_collection_props(Manifest, Name, Scope, Props);
handle_oper({drop_collection, Scope, Name}, Manifest, _BucketConf) ->
    NumCollections = case Name of
                         "_default" -> 0;
                         _ -> 1
                     end,
    functools:chain(
      Manifest,
      [delete_collection(_, Name, Scope),
       update_counter(_, num_collections, -NumCollections)]);
handle_oper(bump_epoch, Manifest, _BucketConf) ->
    functools:chain(
      Manifest,
      [bump_id(_, next_scope_uid, ?EPOCH),
       bump_id(_, next_coll_uid, ?EPOCH),
       bump_id(_, next_uid, ?EPOCH)]).

get_counter(Manifest, Counter) ->
    proplists:get_value(Counter, Manifest).

update_counter(Manifest, Counter, Amount) ->
    lists:keystore(Counter, 1, Manifest,
                   {Counter, get_counter(Manifest, Counter) + Amount}).

get_manifest(Bucket, Snapshot) ->
    get_manifest(Bucket, Snapshot, undefined).

get_manifest(Bucket, direct, Default) ->
    case chronicle_kv:get(kv, key(Bucket), #{}) of
        {ok, {M, _R}} ->
            M;
        {error, not_found} ->
            Default
    end;
get_manifest(Bucket, Snapshot, Default) ->
    case maps:find(key(Bucket), Snapshot) of
        {ok, {M, _}} ->
            M;
        error ->
            Default
    end.

get_scope(Name, Manifest) ->
    find_scope(Name, get_scopes(Manifest)).

get_scopes(Manifest) ->
    proplists:get_value(scopes, Manifest).

find_scope(Name, Scopes) ->
    proplists:get_value(Name, Scopes).

add_scope(Manifest, Name) ->
    Uid = proplists:get_value(next_scope_uid, Manifest),
    on_scopes([{Name, [{uid, Uid}, {collections, []}]} | _], Manifest).

delete_scope(Manifest, Name) ->
    on_scopes(lists:keydelete(Name, 1, _), Manifest).

update_scopes(Scopes, Manifest) ->
    lists:keystore(scopes, 1, Manifest, {scopes, Scopes}).

on_scopes(Fun, Manifest) ->
    Scopes = get_scopes(Manifest),
    NewScopes = Fun(Scopes),
    update_scopes(NewScopes, Manifest).

get_collections(Scope) ->
    proplists:get_value(collections, Scope, []).

get_collection(Name, Scope) ->
    find_collection(Name, get_collections(Scope)).

find_collection(Name, Collections) ->
    proplists:get_value(Name, Collections).

add_collection(Manifest, Name, ScopeName, SuppliedProps, BucketConf) ->
    Uid = proplists:get_value(next_coll_uid, Manifest),
    Props = case proplists:get_value(history, SuppliedProps) of
        undefined ->
            % History defined by our default value
            SuppliedProps ++
                [{history,
                  ns_bucket:history_retention_collection_default(BucketConf)}];
        _ ->
            % History defined by the user
            SuppliedProps
    end,
    SanitizedProps = remove_defaults(Props),
    on_collections([{Name, [{uid, Uid} | SanitizedProps]} | _], ScopeName,
                   Manifest).

modify_collection_props(Manifest, Name, ScopeName, DesiredProps) ->
    on_collections(
        fun (Collections) ->
            % Merge DesiredProps into CurrentProps, and remove any defaults to
            % sanitize the manifest as we can't remove them earlier in case we
            % are setting a value to the default.
            {Name, CurrentProps} = lists:keyfind(Name, 1, Collections),
            NewProps = remove_defaults(misc:update_proplist(CurrentProps,
                                                            DesiredProps)),
            lists:keyreplace(Name, 1, Collections, {Name, NewProps})
        end, ScopeName, Manifest).

delete_collection(Manifest, Name, ScopeName) ->
    on_collections(lists:keydelete(Name, 1, _), ScopeName, Manifest).

update_collections(Collections, Scope) ->
    lists:keystore(collections, 1, Scope, {collections, Collections}).

on_collections(Fun, ScopeName, Manifest) ->
    on_scopes(
      fun (Scopes) ->
              Scope = find_scope(ScopeName, Scopes),
              Collections = get_collections(Scope),
              NewCollections = Fun(Collections),
              NewScope = update_collections(NewCollections, Scope),
              lists:keystore(ScopeName, 1, Scopes, {ScopeName, NewScope})
      end, Manifest).

wait_for_manifest_uid(Bucket, BucketUuid, Uid, Timeout) ->
    case async:run_with_timeout(
           ?cut(wait_for_manifest_uid(Bucket, BucketUuid, Uid)), Timeout) of
        {ok, R} ->
            R;
        {error, timeout} ->
            timeout
    end.

wait_for_manifest_uid(Bucket, BucketUuid, Uid) ->
    Ref = erlang:make_ref(),
    Parent = self(),
    Subscription =
        ns_pubsub:subscribe_link(
          buckets_events,
          fun ({set_collections_manifest, B, U}) when U >= Uid,
                                                      B =:= BucketUuid ->
                  Parent ! {Ref, ok};
              ({stopped, B}) when B =:= Bucket ->
                  Parent ! {Ref, stopped};
              ({loaded, B}) when B =:= Bucket ->
                  Parent ! {Ref, loaded};
              (_) ->
                  ok
          end),
    try wait_for_manifest_uid_loop(Bucket, Ref, Uid)
    after
        (catch ns_pubsub:unsubscribe(Subscription))
    end.

wait_for_manifest_uid_loop(Bucket, Ref, Uid) ->
    case ns_memcached:get_collections_uid(Bucket) of
        {ok, U} when U >= Uid ->
            ok;
        {error, bucket_not_found} ->
            receive
                {Ref, loaded} ->
                    wait_for_manifest_uid_loop(Bucket, Ref, Uid)
            end;
        _ ->
            receive
                {Ref, Ret} when Ret =/= loaded ->
                    Ret
            end
    end.

wait_for_manifest_uid(Nodes, Bucket, BucketUuid, Uid, Timeout) ->
    {Ret, [], BadNodes} =
        misc:rpc_multicall_with_plist_result(
          Nodes, ?MODULE, wait_for_manifest_uid,
          [Bucket, BucketUuid, Uid, Timeout], Timeout),
    case BadNodes of
        [] ->
            case lists:all(fun ({_, ok}) -> true; (_) -> false end, Ret) of
                true ->
                    ok;
                false ->
                    check_for_stopped_bucket(Ret)
            end;
        _ ->
            check_for_stopped_bucket(Ret)
    end.

check_for_stopped_bucket(Ret) ->
    case lists:any(fun ({_, stopped}) -> true; (_) -> false end, Ret) of
        true ->
            stopped;
        false ->
            timeout
    end.

extract_name(Props) ->
    {value, {name, Name}, NewProps} = lists:keytake(name, 1, Props),
    {Name, NewProps}.

convert_manifest_uid(undefined) ->
    undefined;
convert_manifest_uid(Uid) ->
    try
        convert_uid_from_memcached(Uid)
    catch
        _:_ ->
            invalid_uid
    end.

set_manifest(Bucket, AuthnRes, RequiredScopes, RequestedUid) ->
    case convert_manifest_uid(RequestedUid) of
        invalid_uid ->
            invalid_uid;
        Uid ->
            Roles = menelaus_roles:get_compiled_roles(AuthnRes),
            Scopes =
                [{proplists:get_value(name, Scope),
                  [{collections, [extract_name(Props) ||
                                     {Props} <- get_collections(Scope)]}]} ||
                    {Scope} <- RequiredScopes],
            update(Bucket, {set_manifest, Roles, Scopes, Uid})
    end.

last_seen_ids_key(Node, Bucket) ->
    {node, Node, {Bucket, last_seen_collection_ids}}.

get_next_uids(Manifest) ->
    [proplists:get_value(next_uid, Manifest),
     proplists:get_value(next_scope_uid, Manifest),
     proplists:get_value(next_coll_uid, Manifest)].

get_last_seen_uids(_Bucket, bump_epoch) ->
    {no_check, no_check};
get_last_seen_uids(Bucket, _Operation) ->
    {ok, {RV, _}} =
        chronicle_kv:ro_txn(
          kv,
          fun (Txn) ->
                  {ok, {Nodes, _}} =
                      chronicle_kv:txn_get(nodes_wanted, Txn),
                  case chronicle_kv:txn_get(ns_bucket:uuid_key(Bucket), Txn) of
                      {ok, {UUID, _}} ->
                          RVs =
                              [{N, chronicle_kv:txn_get(
                                     last_seen_ids_key(N, Bucket), Txn)} ||
                                  N <- Nodes],
                          Ids = [{N, V} || {N, {ok, {V, _}}} <- RVs],
                          case length(RVs) =:= length(Ids) of
                              true ->
                                  {Ids, UUID};
                              false ->
                                  not_found
                          end;
                      {error, not_found} ->
                          not_found
                  end
          end),
    RV.

update_last_seen_ids(Bucket) ->
    Node = node(),
    Key = last_seen_ids_key(Node, Bucket),
    {ok, {Snapshot, _}} =
        chronicle_kv:get_snapshot(kv, [Key, key(Bucket)]),
    case maps:find(Key, Snapshot) of
        error ->
            ok;
        {ok, {_V, Rev}} ->
            update_last_seen_ids(Key, get_manifest(Bucket, Snapshot), Rev)
    end.

update_last_seen_ids(_Key, undefined, _Rev) ->
    ok;
update_last_seen_ids(Key, Manifest, Rev) ->
    RV =
        chronicle_kv:transaction(
          kv, [Key],
          fun (Snapshot) ->
                  Ids = get_next_uids(Manifest),
                  case maps:find(Key, Snapshot) of
                      {ok, {V, Rev}} when V =/= Ids ->
                          {commit, [{set, Key, Ids}]};
                      _ ->
                          {abort, skip}
                  end
          end),
    case RV of
        {ok, _} ->
            ok;
        skip ->
            ok
    end.

update_last_seen_ids() ->
    case enabled() of
        true ->
            [update_last_seen_ids(Bucket) ||
                Bucket <- ns_bucket:get_bucket_names()];
        false ->
            ok
    end.

last_seen_ids_set(Node, Bucket, Manifest) ->
    {set, last_seen_ids_key(Node, Bucket), get_next_uids(Manifest)}.

chronicle_upgrade_to_72(Bucket, ChronicleTxn) ->
    PropsKey = ns_bucket:sub_key(Bucket, props),
    {ok, BucketConfig} = chronicle_upgrade:get_key(PropsKey, ChronicleTxn),
    case ns_bucket:history_retention_collection_default(BucketConfig) of
        %% Nothing to do
        false -> ChronicleTxn;
        %% Upgrade should add the history prop to each collection
        true ->
            %% We're going to generate a new manifest by modifying each
            %% collection. When we modify a collection we need both the Scope
            %% and the Collection name. We don't have that in a convenient
            %% format, so we'll have to extract it from the manifest.
            {ok, Manifest} = chronicle_upgrade:get_key(key(Bucket),
                                                       ChronicleTxn),
            AllCollections =
                lists:flatmap(
                  fun({ScopeName, ScopeProps}) ->
                          Collections = get_collections(ScopeProps),
                          [{ScopeName, CollectionName} ||
                              {CollectionName, _} <- Collections]
                  end, get_scopes(Manifest)),

            NewManifest1 =
                lists:foldl(
                  fun({Scope, Collection}, Acc) ->
                          modify_collection_props(Acc, Collection, Scope,
                                                  [{history, true}])
                  end,
                  Manifest,
                  AllCollections),

            %% We must bump the manifest uid too or KV won't treat this as a new
            %% manifest.
            NewManifest2 = advance_manifest_id(upgrade, NewManifest1),

            chronicle_upgrade:set_key(key(Bucket), NewManifest2, ChronicleTxn)
    end.

-ifdef(TEST).
manifest_test_set_history_default(Val) ->
    meck:expect(ns_bucket,
                get_bucket,
                fun("bucket") ->
                    {ok, [{history_retention_collection_default, Val},
                          {history_retention_seconds, 1},
                          {storage_mode, magma},
                          {type, membase}]}
                end).

update_manifest_test_setup() ->
    meck:new(ns_config, [passthrough]),
    meck:new(cluster_compat_mode, [passthrough]),
    meck:new(ns_bucket, [passthrough]),

    meck:expect(cluster_compat_mode, is_cluster_70, fun () -> true end),
    meck:expect(cluster_compat_mode, is_cluster_72, fun () -> true end),

    % Return some scope/collection values high enough for us to not worry about
    % it while testing.
    meck:expect(
        ns_config, search,
        fun (max_scopes_count) -> {ok, 1000};
            (max_collections_count) -> {ok, 1000}
        end),

    %% We're not testing auth here (although perhaps we should test that we do
    %% auth at some point in the future) so just allow everything
    meck:new(menelaus_roles, [passthrough]),
    meck:expect(menelaus_roles,
                is_allowed,
                fun (_,_) ->
                    true
                end),

    manifest_test_set_history_default(true).

update_manifest_test_teardown() ->
    meck:unload(ns_config),
    meck:unload(cluster_compat_mode),
    meck:unload(ns_bucket).

update_with_manifest(Manifest, Operation) ->
    Bucket = "bucket",
    OtherBucketCounts = {0,0},
    LastSeenIds = [{check, [0,0,0]}],
    ScopeCollectionLimits = {max_scopes_per_bucket(),
                             max_collections_per_bucket()},
    do_update_with_manifest(Bucket, Manifest, Operation, OtherBucketCounts,
                            ScopeCollectionLimits, LastSeenIds).

update_manifest_test_create_collection(Manifest, Scope, Name, Props) ->
    update_with_manifest(Manifest, {create_collection, Scope, Name, Props}).

update_manifest_test_update_collection(Manifest, Scope, Name, Props) ->
    update_with_manifest(Manifest, {modify_collection, Scope, Name, Props}).

update_manifest_test_drop_collection(Manifest, Scope, Name) ->
    update_with_manifest(Manifest, {drop_collection, Scope, Name}).

update_manifest_test_create_scope(Manifest, Name) ->
    update_with_manifest(Manifest, {create_scope, Name}).

update_manifest_test_drop_scope(Manifest, Name) ->
    update_with_manifest(Manifest, {drop_scope, Name}).

update_manifest_test_set_manifest(Manifest, NewScopes) ->
    %% We're not trying to test auth here so can supply anything for Roles
    Roles = [],

    %% Don't care much about ValidOnUid either, pick a value that will always
    %% be valid.
    ValidOnUid = get_uid(Manifest),

    update_with_manifest(Manifest,
                         {set_manifest, Roles, NewScopes, ValidOnUid}).

create_collection_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_collection(default_manifest(BucketConf),
                                               "_default", "c1", []),
    ?assertEqual([{uid, 8}, {history, true}],
                 get_collection("c1", get_scope("_default", Manifest1))),

    % Can't create collection with same name
    ?assertEqual(
        {abort, {error, {collection_already_exists, "_default", "c1"}}},
        update_manifest_test_create_collection(Manifest1, "_default", "c1", [])),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_create_collection(Manifest1, "_default", "c2", []),
    ?assertEqual([{uid, 9}, {history, true}],
                 get_collection("c2", get_scope("_default", Manifest2))).

drop_collection_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_collection(default_manifest(BucketConf),
                                               "_default", "c1", []),
    ?assertEqual([{uid, 8}, {history, true}],
                 get_collection("c1", get_scope("_default", Manifest1))),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_drop_collection(Manifest1, "_default", "c1"),
    ?assertEqual(undefined,
                 get_collection("c1", get_scope("_default", Manifest2))),

    % Can't drop collection that does not exist
    ?assertEqual(
        {abort, {error, {collection_not_found, "_default","c1"}}},
        update_manifest_test_drop_collection(Manifest2, "_default", "c1")).

create_scope_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_scope(default_manifest(BucketConf), "s1"),
    ?assertEqual([{uid, 8}, {collections, []}],
                 proplists:get_value("s1", get_scopes(Manifest1))),

    % Can't create scope with same name
    ?assertEqual({abort, {error, {scope_already_exists, "s1"}}},
                  update_manifest_test_create_scope(Manifest1, "s1")),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_create_scope(Manifest1, "s2"),
    ?assertEqual([{uid, 9}, {collections, []}],
                 proplists:get_value("s2", get_scopes(Manifest2))).

drop_scope_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_scope(default_manifest(BucketConf), "s1"),
    ?assertEqual([{uid, 8}, {collections, []}],
                 proplists:get_value("s1", get_scopes(Manifest1))),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_drop_scope(Manifest1, "s1"),
    ?assertEqual(undefined,
                 proplists:get_value("s1", get_scopes(Manifest2))),

    % Can't drop scope that does not exist
    ?assertEqual({abort, {error, {scope_not_found, "s1"}}},
                  update_manifest_test_drop_scope(Manifest2, "s1")).

manifest_uid_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_scope(default_manifest(BucketConf), "s1"),
    ?assertEqual(2, proplists:get_value(uid, Manifest1)),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_create_collection(Manifest1, "s1", "c1", []),
    ?assertEqual(3, proplists:get_value(uid, Manifest2)),

    {commit, [{_, _, Manifest3}], _} =
        update_manifest_test_update_collection(Manifest2, "s1", "c1",
                                               [{history, true}]),
    ?assertEqual(4, proplists:get_value(uid, Manifest3)),

    {commit, [{_, _, Manifest4}], _} =
        update_manifest_test_drop_collection(Manifest3, "s1", "c1"),
    ?assertEqual(5, proplists:get_value(uid, Manifest4)),

    {commit, [{_, _, Manifest5}], _} =
        update_manifest_test_drop_scope(Manifest4, "s1"),
    ?assertEqual(6, proplists:get_value(uid, Manifest5)).

scope_uid_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_scope(default_manifest(BucketConf), "s1"),
    ?assertEqual(8, get_uid(get_scope("s1", Manifest1))),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_create_scope(Manifest1, "s2"),
    ?assertEqual(9, get_uid(get_scope("s2", Manifest2))),

    % Recreate of same scope should use new id
    {commit, [{_, _, Manifest3}], _} =
        update_manifest_test_drop_scope(Manifest2, "s1"),
    {commit, [{_, _, Manifest4}], _} =
        update_manifest_test_create_scope(Manifest3, "s1"),
    ?assertEqual(10, get_uid(get_scope("s1", Manifest4))).

collection_uid_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_collection(default_manifest(BucketConf),
                                               "_default", "c1", []),
    ?assertEqual(8,
                 get_uid(get_collection("c1",
                                        get_scope("_default", Manifest1)))),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_create_collection(Manifest1, "_default", "c2", []),
    ?assertEqual(9,
                 get_uid(get_collection("c2",
                                        get_scope("_default", Manifest2)))),

    % Recreate of same collection should use new id
    {commit, [{_, _, Manifest3}], _} =
        update_manifest_test_drop_collection(Manifest2, "_default", "c1"),
    {commit, [{_, _, Manifest4}], _} =
        update_manifest_test_create_collection(Manifest3, "_default", "c1", []),
    ?assertEqual(10,
                 get_uid(get_collection("c1",
                                        get_scope("_default", Manifest4)))),

    % Collections in other scopes should not share ids
    {commit, [{_, _, Manifest5}], _} =
        update_manifest_test_create_scope(Manifest4, "s1"),
    {commit, [{_, _, Manifest6}], _} =
        update_manifest_test_create_collection(Manifest5, "s1", "s1c1", []),
    ?assertEqual(11,
                 get_uid(get_collection("s1c1",
                                         get_scope("s1", Manifest6)))).

modify_collection_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    Manifest = default_manifest(BucketConf),

    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_collection(Manifest, "_default", "c1", []),
    ?assert(proplists:get_value(history,
                                get_collection("c1",
                                               get_scope("_default",
                                                         Manifest1)))),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_update_collection(Manifest1, "_default", "c1",
                                               [{history, false}]),
    ?assertEqual(undefined,
                 proplists:get_value(history,
                                     get_collection("c1",
                                                    get_scope("_default",
                                                              Manifest2)))),

    {commit, [{_, _, Manifest3}], _} =
        update_manifest_test_update_collection(Manifest2, "_default", "c1",
                                               [{history, true}]),
    ?assert(proplists:get_value(history,
                                get_collection("c1",
                                               get_scope("_default",
                                                         Manifest3)))),

    %% Cannot set maxTTL from undefined
    ?assertEqual(
        {abort, {error, {cannot_modify_properties, "c1", [{maxTTL, 9}]}}},
        update_manifest_test_update_collection(Manifest3, "_default", "c1",
                                               [{maxTTL, 9}])),

    {commit, [{_, _, Manifest4}], _} =
        update_manifest_test_create_collection(Manifest3, "_default", "c2",
                                               [{maxTTL, 10}]),
    ?assertEqual(10,
                 proplists:get_value(maxTTL,
                                     get_collection("c2",
                                                    get_scope("_default",
                                                              Manifest4)))),

    %% Cannot change maxTTL value
    ?assertEqual(
        {abort, {error, {cannot_modify_properties, "c2", [{maxTTL, 11}]}}},
        update_manifest_test_update_collection(Manifest4, "_default", "c2",
                                               [{maxTTL, 11}])),

    %% Allowed to specify collection props to the same value.
    {commit, [{_,_, Manifest5}], _} =
        update_manifest_test_update_collection(Manifest4, "_default", "c2",
                                               [{maxTTL, 10}]),

    %% No change as maxTTL was initially 10, can't check the whole manifest as
    %% uid moves on.
    ?assertEqual(
        lists:sort(get_collection("c2", get_scope("_default", Manifest4))),
        lists:sort(get_collection("c2", get_scope("_default", Manifest5)))),

    %% Cannot modify uid
    ?assertEqual(
        {abort, {error, {cannot_modify_properties, "c1", [{uid, 999}]}}},
        update_manifest_test_update_collection(Manifest2, "_default", "c1",
                                               [{uid, 999}])).

history_default_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),

    %% Default collection history field should inherit the default
    DefaultMan = default_manifest(BucketConf),
    ?assert(proplists:get_value(history,
                                get_collection("_default",
                                               get_scope("_default",
                                                         DefaultMan)))),

    % history_default is true, it should set history for the collection
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_create_collection(default_manifest(BucketConf),
                                               "_default", "c1", []),
    ?assertEqual(undefined,
                 proplists:get_value(history_default, Manifest1)),
    ?assert(proplists:get_value(history,
                                get_collection("c1",
                                               get_scope("_default",
                                                         Manifest1)))),

    % Set history_default to false and a new collection should not have history
    manifest_test_set_history_default(false),
    {ok, BucketConf1} = ns_bucket:get_bucket("bucket"),

    %% And the default collections history field should not be present
    DefaultMan1 = default_manifest(BucketConf1),
    ?assertEqual(undefined,
                 proplists:get_value(history,
                                     get_collection("_default",
                                                    get_scope("_default",
                                                              DefaultMan1)))),

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_create_collection(Manifest1, "_default", "c3", []),
    ?assertEqual(undefined,
                 proplists:get_value(history,
                                     get_collection("c3",
                                                    get_scope("_default",
                                                              Manifest2)))),

    % And set history_default back to true and test again
    manifest_test_set_history_default(true),

    % History should be true now
    {commit, [{_, _, Manifest3}], _} =
        update_manifest_test_create_collection(Manifest2, "_default", "c2", []),
    ?assert(proplists:get_value(history,
                                get_collection("c2",
                                               get_scope("_default",
                                                         Manifest3)))).

set_manifest_t() ->
    {ok, BucketConf} = ns_bucket:get_bucket("bucket"),
    %% Cannot drop default scope
    {abort, {error, cannot_drop_default_scope}} =
        update_manifest_test_set_manifest(default_manifest(BucketConf),
                                          [{"s1", []}]),

    %% Cannot modify default collection with invalid args
    ?assertEqual(
        {abort, {error, {cannot_modify_properties, "_default", [{maxTTL, 9}]}}},
        update_manifest_test_set_manifest(default_manifest(BucketConf),
            [{"_default", [{collections, [{"_default", [{maxTTL, 9}]}]}]}])),

    %% We'll build some manifests to test that the bulk API can correctly modify
    %% collections. All of the manifests will use these counters
    ManifestCounters = [{uid, 0},
                        {next_uid, 1},
                        {next_scope_uid, 100},
                        {next_coll_uid, 100},
                        {num_scopes, 0},
                        {num_collections, 0}],

    %% We should never really see an empty manifest as we can't drop the default
    %% scope normally, but it does make testing simpler as we don't need to
    %% consider dropping any collections.
    EmptyManifest = ManifestCounters ++ [{scopes, []}],

    %% Create scopes and collections from empty manifest
    {commit, [{_, _, Manifest1}], _} =
        update_manifest_test_set_manifest(
            EmptyManifest,
            [{"s1", [{collections, [{"c1", []},
                                    {"c2", [{maxTTL, 8}]},
                                    {"c3", [{history, false}]},
                                    {"c4", [{history, true}]}]}]}]),
    ?assertEqual(
        [{"s1",
            [{uid,100},
             {collections, [{"c4", [{uid, 103}, {history, true}]},
                            {"c3", [{uid, 102}]},
                            {"c2", [{uid, 101}, {maxTTL, 8}, {history, true}]},
                            {"c1", [{uid, 100}, {history, true}]}]}]}],
        get_scopes(Manifest1)),

    %% Drop and create collections
    ExistingManifest1 =
        ManifestCounters ++
        [{scopes,
            [{"_default",
                [{uid, 8},
                 {collections, [{"_default", []}]}]},
             {"s1",
                 [{uid, 9},
                  {collections, [{"c1", [{uid, 8}]}]}]},
             {"s2",
                 [{uid, 10},
                  {collections, [{"c1", [{uid, 9}]},
                                 {"c2", [{uid, 10}]}]}]}]}],

    {commit, [{_, _, Manifest2}], _} =
        update_manifest_test_set_manifest(
            ExistingManifest1,
            [{"_default", [{collections, []}]},
             {"s1", [{collections, [{"c2", []}]}]},
             {"s2", [{collections, [{"c1", []},
                                    {"c2", []},
                                    {"c3", []}]}]}]),

    ?assertEqual(
        [{"_default",
            [{uid, 8}, {collections, []}]},
         {"s1",
             [{uid, 9},
              {collections,
                  [{"c2", [{uid, 101}, {history, true}]}]}]},
         {"s2",
             [{uid, 10},
              {collections, [{"c3",[{uid, 100}, {history, true}]},
                             {"c1",[{uid, 9}]},
                             {"c2",[{uid, 10}]}]}]}],
        get_scopes(Manifest2)),


    %% Modify collection
    ExistingManifest2 =
        ManifestCounters ++
        [{scopes,
            [{"s1",
                [{uid, 8},
                 {collections, [{"c1", [{uid, 8}]}]}]},
             {"s2",
                 [{uid, 9},
                  {collections, [{"c1", [{uid, 9}]},
                                 {"c2", [{uid, 10}]}]}]},
             {"s3",
                 [{uid, 10},
                  {collections, [{"ic1", [{uid, 11}]},
                                 {"ic2", [{uid, 12}, {maxTTL, 0}]},
                                 {"ic3", [{uid, 13}]},
                                 {"ic4", [{uid, 14}]},
                                 {"ic5", [{uid, 15}, {history, false}]},
                                 {"ic6", [{uid, 16}, {history, true}]}]}]}]}],
    {commit, [{_, _, Manifest3}], _} =
        update_manifest_test_set_manifest(
            ExistingManifest2,
            [{"s1",
                [{collections, [{"c1", []},
                                {"c2", []}]}]},
             {"s3", [{collections, [{"ic1", []},
                                    {"ic2", [{maxTTL, 0}]},
                                    {"ic3", [{history, false}]},
                                    {"ic4", [{history, true}]},
                                    {"ic5", [{history, true}]},
                                    {"ic6", [{history, false}]}]}]}]),
    ?assertEqual(
        [{"s1",
            [{uid, 8},
             {collections, [{"c2", [{uid, 100}, {history, true}]},
                            {"c1", [{uid, 8}]}]}]},
         {"s3",
            [{uid, 10},
             {collections, [{"ic1", [{uid, 11}]},
                            {"ic2", [{uid, 12}, {maxTTL, 0}]},
                            {"ic3", [{uid, 13}]},
                            {"ic4", [{history, true}, {uid, 14}]},
                            {"ic5", [{history, true}, {uid, 15}]},
                            {"ic6", [{uid, 16}]}]}]}],
        get_scopes(Manifest3)),

    %% Cannot add maxTTL
    ExistingManifest3 =
        ManifestCounters ++
        [{scopes,
            [{"s1",
                [{uid, 8},
                 {collections, [{"c1", [{uid, 8}]}]}]}]}],
    ?assertEqual(
        {abort,{error,{cannot_modify_properties,"c1",[{maxTTL,10}]}}},
        update_manifest_test_set_manifest(
            ExistingManifest3,
            [{"s1",
                [{collections, [{"c1", [{maxTTL, 10}]}]}]}])),

    %% maxTTL=undefined and maxTTL=0 are equivalent due to the default values,
    %% we should not attempt to change anything here.
    ?assertEqual(
        {abort,{not_changed,<<"0">>}},
        update_manifest_test_set_manifest(
            ExistingManifest3,
            [{"s1",
                [{collections, [{"c1", [{maxTTL, 0}]}]}]}])),

    %% Cannot modify TTL
    ExistingManifest4 =
        ManifestCounters ++
        [{scopes,
            [{"s1",
                [{uid, 8},
                    {collections, [{"c1", [{uid, 8}, {maxTTL, 8}]}]}]}]}],
    ?assertEqual(
        {abort,{error,{cannot_modify_properties,"c1",[{maxTTL,10}]}}},
        update_manifest_test_set_manifest(
            ExistingManifest4,
            [{"s1",
                [{collections, [{"c1", [{maxTTL, 10}]}]}]}])),

    %% Setting to the same value is ignored if there are no other changes
    ?assertEqual(
        {abort,{not_changed,<<"0">>}},
        update_manifest_test_set_manifest(
            ExistingManifest4,
            [{"s1",
                [{collections, [{"c1", [{maxTTL, 8}]}]}]}])),

    %% Allowed to set to same value when there are other changes

    {commit, [{_, _, Manifest4}], _} =
        update_manifest_test_set_manifest(
        ExistingManifest4,
        [{"s1",
            [{collections, [{"c1", [{maxTTL, 8}]},
                {"c2", []}]}]}]),
    ?assertEqual([{uid, 8}, {maxTTL, 8}],
        get_collection("c1", get_scope("s1", Manifest4))).

upgrade_to_72_t() ->
    CollectionsKey = key("bucket"),

    %% To test the upgrade we need to create a 7.1 (or older) manifest. To do
    %% do that we must set history_retention_collection_default to false in the
    %% BucketConfig that we're using. Whilst we can do that explicitly,
    %% particularly in this test via calling
    %% "manifest_test_set_history_default(false)", we can more idiomatically
    %% just pretend this is a pre-7.2.0 cluster via cluster_compat_mode which we
    %% must check to ensure that we don't create collections with history=true
    %% in mixed mode clusters when using the default history value.
    meck:expect(cluster_compat_mode, is_cluster_72, fun() -> false end),

    {ok, BucketConf71} = ns_bucket:get_bucket("bucket"),
    Manifest71 = default_manifest(BucketConf71),
    ?assertEqual(undefined,
                 proplists:get_value(history,
                                     get_collection("_default",
                                                    get_scope("_default",
                                                              Manifest71)))),
    ?assertEqual(0, proplists:get_value(uid, Manifest71)),

    meck:expect(cluster_compat_mode, is_cluster_72, fun() -> true end),

    %% collections:chronicle_upgrade_to_72/2 requires that we upgrade the
    %% BucketConfig /before/ we call it to perform the upgrade successfully,
    %% namely we must set history_retention_collection_default to true. We're
    %% going to "upgrade" the BucketConfig that we pass into the Snapshot here
    %% to accomplish that.
    manifest_test_set_history_default(true),
    {ok, BucketConf72} = ns_bucket:get_bucket("bucket"),
    Snapshot1 = maps:put({bucket, "bucket", props}, BucketConf72, maps:new()),
    Snapshot71 = maps:put(CollectionsKey, Manifest71, Snapshot1),
    Txn = {Snapshot71, undefined},

    {Snapshot72, _Txn} = chronicle_upgrade_to_72("bucket", Txn),

    %% Time to test the result of the upgrade
    Manifest72 = maps:get(CollectionsKey, Snapshot72),
    ?assert(proplists:get_value(history,
                                get_collection("_default",
                                               get_scope("_default",
                                                         Manifest72)))),

    ?assertEqual(1, proplists:get_value(uid, Manifest72)).

% Bunch of fairly simple collections tests that update the manifest and expect
% various results.
basic_collections_manifest_test_() ->
    % We can re-use (setup) the test environment that we setup/teardown here
    % for each test rather than create a new one (foreach) to save time.
    {setup,
        fun() ->
            update_manifest_test_setup()
        end,
        fun(_) ->
            update_manifest_test_teardown()
        end,
        [{"create collection test", fun () -> create_collection_t() end},
         {"drop collection test", fun () -> drop_collection_t() end},
         {"create scope test", fun () -> create_scope_t() end},
         {"drop scope test", fun() -> drop_scope_t() end},
         {"manifest uid test", fun() -> manifest_uid_t() end},
         {"scope uid test", fun() -> scope_uid_t() end},
         {"collection uid test", fun() -> collection_uid_t() end},
         {"modify collection test", fun() -> modify_collection_t() end},
         {"history default test", fun() -> history_default_t() end},
         {"set manifest test", fun() -> set_manifest_t() end},
         {"upgrade to 72 test", fun() -> upgrade_to_72_t() end}]}.

-endif.
