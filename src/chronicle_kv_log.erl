%% @author Couchbase <info@couchbase.com>
%% @copyright 2021-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included
%% in the file licenses/BSL-Couchbase.txt.  As of the Change Date specified
%% in that file, in accordance with the Business Source License, use of this
%% software will be governed by the Apache License, Version 2.0, included in
%% the file licenses/APL2.txt.
%%
-module(chronicle_kv_log).

-behaviour(gen_server2).

-export([start_link/0, init/1, handle_info/2]).

-include("ns_common.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Self = self(),
    ns_pubsub:subscribe_link(chronicle_kv:event_manager(kv),
                             fun ({_, _, _} = Evt) ->
                                     Self ! Evt;
                                 (_) ->
                                     ok
                             end),
    {ok, #{}}.

handle_info({{key, K}, R, {updated, V}}, State) ->
    NewState = log(K, V, R, State),
    {noreply, NewState, hibernate};
handle_info({{key, K}, R, deleted}, State) ->
    ?log_debug("delete (key: ~p, rev: ~p)", [K, R]),
    {noreply, maps:remove(K, State), hibernate};
handle_info(Info, State) ->
    ?log_warning("Unexpected message(~p, ~p)", [Info, State]),
    {noreply, State, hibernate}.

log(K, V, R, State) ->
    {NewV, NewState} =
        case ns_bucket:sub_key_match(K) of
            {true, _Bucket, props} ->
                {case maps:find(K, State) of
                     {ok, Old} ->
                         ns_config_log:compute_bucket_diff(V, Old);
                     error ->
                         V
                 end, maps:put(K, V, State)};
            _ ->
                {V, State}
        end,
    VB = list_to_binary(io_lib:print(NewV, 0, 80, 100)),
    ?log_debug("update (key: ~p, rev: ~p)~n~s", [K, R, VB]),
    NewState.