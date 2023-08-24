%% @author Couchbase <info@couchbase.com>
%% @copyright 2020-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc helpers for backward compatible calls to chronicle/ns_config
%%

-module(chronicle_compat).

-include("ns_common.hrl").
-include("ns_config.hrl").
-include("cut.hrl").

-export([backend/0,
         get/2,
         get/3,
         set/2,
         set_multiple/1,
         transaction/2,
         txn/1,
         txn/2,
         txn/3,
         ro_txn/2,
         txn_get/2,
         txn_get_many/2,
         get_snapshot/1,
         get_snapshot/2,
         get_snapshot_with_revision/2,
         pull/0,
         pull/1,
         remote_pull/2,
         config_sync/2,
         config_sync/3,
         node_keys/2,
         service_keys/1]).

%% RPC from another nodes
-export([do_pull/1]).

backend() ->
    %% so dialyzer doesn't scream at me
    ns_config:read_key_fast(chronicle_backend, chronicle).

get(Key, Opts) ->
    get(ns_config:latest(), Key, Opts).

get(direct, Key, Opts) ->
    get(ns_config:latest(), Key, Opts);
get(Config, Key, #{required := true}) ->
    {ok, Value} = get(Config, Key, #{}),
    Value;
get(Config, Key, #{default := Default}) ->
    case get(Config, Key, #{}) of
        {error, not_found} ->
            Default;
        {ok, Value} ->
            Value
    end;
get(Snapshot, Key, #{}) when is_map(Snapshot) ->
    case maps:find(Key, Snapshot) of
        {ok, {V, _R}} ->
            {ok, V};
        error ->
            {error, not_found}
    end;
get(Config, Key, #{}) ->
    case backend() of
        chronicle ->
            case ns_node_disco:couchdb_node() =:= node() of
                true ->
                    case ns_couchdb_chronicle_dup:lookup(Key) of
                        [{Key, {Value, _Rev}}] ->
                            {ok, Value};
                        [] ->
                            {error, not_found}
                    end;
                false ->
                    case chronicle_kv:get(kv, Key, #{}) of
                        {ok, {V, _R}} ->
                            {ok, V};
                        Error ->
                            Error
                    end
            end;
        ns_config ->
            case ns_config:search(Config, Key) of
                {value, Value} ->
                    {ok, Value};
                false ->
                    {error, not_found}
            end
    end.

set(Key, Value) ->
    case backend() of
        chronicle ->
            case chronicle_kv:set(kv, Key, Value) of
                {ok, _} ->
                    ok;
                Error ->
                    Error
            end;
        ns_config ->
            ns_config:set(Key, Value),
            ok
    end.

set_multiple([]) ->
    ok;
set_multiple(List) ->
    case backend() of
        chronicle ->
            Fun = fun (_) -> {commit, [{set, K, V} || {K, V} <- List]} end,
            case chronicle_kv:transaction(kv, [], Fun, #{}) of
                {ok, _} ->
                    ok;
                Error ->
                    Error
            end;
        ns_config ->
            ns_config:set(List)
    end.

transaction(Keys, Fun) ->
    transaction(backend(), Keys, Fun).

transaction(Type, Keys, Fun) ->
    txn(Type, ?cut(Fun(txn_get_many(Keys, _))), #{}).

txn(Fun) ->
    txn(Fun, #{}).

txn(Fun, Opts) ->
    txn(backend(), Fun, Opts).

txn(chronicle, Fun, Opts) ->
    chronicle_kv:txn(kv, ?cut(Fun({chronicle, _})), Opts);
txn(ns_config, Fun, _Opts) ->
    TXNRV =
        ns_config:run_txn(
          fun (Cfg, SetFn) ->
                  BuildCommit =
                      lists:foldl(
                        fun ({set, K, V}, Acc) -> SetFn(K, V, Acc) end,
                        Cfg, _),
                  case Fun({ns_config, Cfg}) of
                      {abort, _} = Abort ->
                          Abort;
                      {commit, Sets, Extra} ->
                          {commit, BuildCommit(Sets), Extra};
                      {commit, Sets} ->
                          {commit, BuildCommit(Sets)}
                  end
          end),
    case TXNRV of
        {commit, _} ->
            {ok, no_rev};
        {commit, _, Extra} ->
            {ok, no_rev, Extra};
        {abort, Error} ->
            Error;
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

ro_txn(Body, Opts) ->
    Type =
        case {backend(), ns_node_disco:couchdb_node() == node()} of
            {chronicle, true} ->
                couchdb;
            {Backend, _} ->
                Backend
        end,
    ro_txn(Type, Body, Opts).

ro_txn(chronicle, Body, Opts) ->
    chronicle_kv:ro_txn(kv, ?cut(Body({chronicle, _})), Opts);
ro_txn(ns_config, Body, #{ns_config := Config}) ->
    {ok, {Body({ns_config, Config}), no_rev}};
ro_txn(ns_config, Body, _Opts) ->
    {ok, {Body({ns_config, ns_config:get()}), no_rev}};
ro_txn(couchdb, Body, #{}) ->
    {ok, {ns_couchdb_chronicle_dup:ro_txn(?cut(Body({couchdb, _}))), no_rev}}.

txn_get(K, {chronicle, Txn}) ->
    chronicle_kv:txn_get(K, Txn);
txn_get(K, {ns_config, Config}) ->
    case ns_config:search(Config, K) of
        {value, V} ->
            {ok, {V, no_rev}};
        false ->
            {error, not_found}
    end;
txn_get(K, {couchdb, TxnGet}) ->
    TxnGet(K).

txn_get_many(Keys, {chronicle, Txn}) ->
    chronicle_kv:txn_get_many(Keys, Txn);
txn_get_many(Keys, Txn) ->
    lists:foldl(
      fun (K, Acc) ->
              case txn_get(K, Txn) of
                  {ok, {V, R}} ->
                      maps:put(K, {V, R}, Acc);
                  {error, not_found} ->
                      Acc
              end
      end, #{}, Keys).

get_snapshot(Fetchers) ->
    get_snapshot(Fetchers, #{}).

get_snapshot(Fetchers, Opts) ->
    {Snapshot, _} = get_snapshot_with_revision(Fetchers, Opts),
    Snapshot.

get_snapshot_with_revision(Fetchers, Opts) ->
    {ok, SnapshotWithRev} =
        ro_txn(
          fun (Txn) ->
                  lists:foldl(
                    fun (Fetcher, Acc) ->
                            maps:merge(Fetcher(Txn), Acc)
                    end, #{}, Fetchers)
          end, Opts),
    SnapshotWithRev.

pull() ->
    pull(ns_config_rep:get_timeout(pull)).

pull(Timeout) ->
    case backend() of
        ns_config ->
            ok;
        chronicle ->
            do_pull(Timeout)
    end.

do_pull(Timeout) ->
    ok = chronicle_kv:sync(kv, Timeout).

remote_pull(Nodes, Timeout) ->
    {_, BadRPC, BadNodes} =
        misc:rpc_multicall_with_plist_result(Nodes, ?MODULE, do_pull, [Timeout],
                                             Timeout),
    case BadNodes =:= [] andalso BadRPC =:= [] of
        true ->
            ok;
        false ->
            Error = {remote_pull_failed, BadRPC ++
                         [{N, bad_node} || N <- BadNodes]},
            ?log_warning("Failed to push chronicle config ~p", [Error]),
            {error, Error}
    end.

config_sync(Type, Nodes) ->
    config_sync(Type, Nodes, ns_config_rep:get_timeout(Type)).

config_sync(pull, Nodes, Timeout) ->
    case backend() of
        ns_config ->
            ns_config_rep:pull_remotes(Nodes, Timeout);
        chronicle ->
            do_pull(Timeout)
    end;
config_sync(push, Nodes, Timeout) ->
    case backend() of
        ns_config ->
            ns_config_rep:ensure_config_seen_by_nodes(Nodes, Timeout);
        chronicle ->
            case remote_pull(Nodes, Timeout) of
                ok ->
                    ok;
                {error, {remote_pull_failed, BadResults}} ->
                    {error, BadResults}
            end
    end.

node_keys(Node, Buckets) ->
    [{node, Node, membership},
     {node, Node, services},
     {node, Node, recovery_type},
     {node, Node, failover_vbuckets},
     {node, Node, buckets_with_data} |
     [collections:last_seen_ids_key(Node, Bucket) || Bucket <- Buckets]].

service_keys(Service) ->
    [{service_map, Service},
     {service_failover_pending, Service}].
