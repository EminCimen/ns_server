%% @author Couchbase <info@couchbase.com>
%% @copyright 2018-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(chronicle_master).

-behaviour(gen_server2).

-include("ns_common.hrl").
-include("ns_config.hrl").
-include("cut.hrl").

-define(SERVER, {via, leader_registry, ?MODULE}).

%% genserver callbacks
-export([init/1,
         handle_call/3,
         handle_info/2]).

-export([start_link/0,
         add_replica/3,
         remove_peer/1,
         activate_nodes/1,
         deactivate_nodes/1,
         start_failover/2,
         complete_failover/2,
         get_prev_failover_nodes/1,
         fetch_snapshot/1,
         failover_opaque_key/0]).

-define(CALL_TIMEOUT, ?get_timeout(call, 60000)).
-define(JANITOR_TIMEOUT, ?get_timeout(janitor, 60000)).

-record(state, {self_ref, janitor_timer_ref}).

start_link() ->
    misc:start_singleton(gen_server2, start_link, [?SERVER, ?MODULE, [], []]).

wait_for_server_start() ->
    misc:wait_for_global_name(?MODULE).

add_replica(Node, GroupUUID, Services) ->
    call({add_replica, Node, GroupUUID, Services}).

activate_nodes(Nodes) ->
    call({activate_nodes, Nodes}).

deactivate_nodes(Nodes) ->
    call({deactivate_nodes, Nodes}).

remove_peer(Node) ->
    call({remove_peer, Node}).

start_failover(Nodes, Ref) when Nodes =/= [] ->
    wait_for_server_start(),
    gen_server2:call(?SERVER, {start_failover, Nodes, Ref}, ?CALL_TIMEOUT).

complete_failover(Nodes, Ref) when Nodes =/= [] ->
    wait_for_server_start(),
    gen_server2:call(?SERVER, {complete_failover, Nodes, Ref}, ?CALL_TIMEOUT).

fetch_snapshot(Txn) ->
    chronicle_compat:txn_get_many([failover_opaque_key()], Txn).

call(Oper) ->
    ?log_debug("Calling chronicle_master with ~p", [Oper]),
    call(Oper, 3).

call(_Oper, 0) ->
    exit(chronicle_master_call_failed);
call(Oper, Tries) ->
    wait_for_server_start(),
    try gen_server2:call(?SERVER, Oper, ?CALL_TIMEOUT) of
        RV -> RV
    catch
        exit:Error ->
            ?log_debug("Retry due to error: ~p", [Error]),
            timer:sleep(200),
            call(Oper, Tries - 1)
    end.

%% -------------------------------------
%% genserver callbacks.
%% -------------------------------------
init([]) ->
    case is_cluster_node() of
        true ->
            do_init();
        false ->
            %% We expect to be taking down soon anyway.
            ignore
    end.

handle_call(Call, From, State) ->
    true = is_cluster_node(),
    do_handle_call(Call, From, State).

handle_info(Msg, State) ->
    true = is_cluster_node(),
    do_handle_info(Msg, State).
%% -------------------------------------

is_cluster_node() ->
    lists:member(node(), ns_cluster_membership:nodes_wanted()).

do_init() ->
    erlang:process_flag(trap_exit, true),
    Self = self(),
    SelfRef = erlang:make_ref(),
    ?log_debug("Starting with SelfRef = ~p", [SelfRef]),
    subscribe_to_chronicle_events(SelfRef),

    State = #state{self_ref = SelfRef},
    case is_delegated_operation() of
        true ->
            %% If we have a delegated operation run janitor immediately.
            Self ! janitor,
            {ok, State};
        false ->
            {ok, arm_janitor_timer(State)}
    end.

do_handle_call({start_failover, Nodes, Ref}, _From, State) ->
    PreviousFailoverNodes = get_prev_failover_nodes(direct),

    case PreviousFailoverNodes -- Nodes of
        [] ->
            Opaque = {Ref, Nodes},
            NodesToKeep = ns_cluster_membership:nodes_wanted() -- Nodes,

            ?log_info("Starting quorum failover with opaque ~p, "
                      "keeping nodes ~p", [Opaque, NodesToKeep]),
            RV = case chronicle:failover(NodesToKeep, Opaque) of
                     ok ->
                         ok;
                     {error, Error} = E ->
                         ?log_error("Unsuccesfull quorum loss failover. (~p).",
                                    [Error]),
                         E
                 end,
            {reply, RV, State};
        _ ->
            ?log_warning("Requested failover of ~p is incompatibe with "
                         "unfinished failover of ~p",
                         [Nodes, PreviousFailoverNodes]),
            {reply, {incompatible_with_previous, PreviousFailoverNodes}, State}
    end;

do_handle_call({complete_failover, Nodes, Ref}, _From, State) ->
    ?log_info("Completing quorum loss failover with ref = ~p "
              "removing nodes ~p", [Ref, Nodes]),
    {ok, _} =
        ns_cluster_membership:remove_nodes(
          Nodes,
          transaction_with_key_remove(
            failover_opaque_key(), fun ({ORef, _}) -> ORef =:= Ref end, _)),
    NewState = cancel_janitor_timer(State),
    self() ! janitor,
    {reply, ok, NewState};

do_handle_call(Oper, _From, #state{self_ref = SelfRef} = State) ->
    NewState = cancel_janitor_timer(State),
    RV = case acquire_lock() of
             {ok, Lock} ->
                 handle_oper(Oper, Lock, SelfRef);
             cannot_acquire_lock ->
                 cannot_acquire_lock
         end,
    {reply, RV, NewState}.

do_handle_info(arm_janitor_timer, State) ->
    {noreply, arm_janitor_timer(State)};

do_handle_info(janitor, #state{self_ref = SelfRef} = State) ->
    CleanState = cancel_janitor_timer(State),
    NewState =
        case acquire_lock() of
            {ok, Lock} ->
                case transaction(undefined, Lock, SelfRef,
                                 fun (_) -> {abort, clean} end) of
                    {ok, _, {need_recovery, RecoveryOper}} ->
                        ?log_debug("Janitor found that recovery is needed for "
                                   "operation ~p", [RecoveryOper]),
                        ok = handle_oper(RecoveryOper, Lock, SelfRef);
                    unfinished_failover ->
                        ?log_debug("Skip janitor due to unfinished failover.");
                    clean ->
                        ok
                end,
                CleanState;
            cannot_acquire_lock ->
                ?log_debug("Cannot acquire lock. Try janitor later."),
                arm_janitor_timer(CleanState)
        end,
    {noreply, NewState};

do_handle_info({'EXIT', From, Reason}, State) ->
    ?log_debug("Received exit from ~p with reason ~p. Exiting.",
               [From, Reason]),
    {stop, Reason, State}.

acquire_lock() ->
    try chronicle:acquire_lock() of
        {ok, Lock} ->
            {ok, Lock}
    catch Type:What ->
            ?log_debug("Cannot acquire lock due to ~p:~p.", [Type, What]),
            cannot_acquire_lock
    end.

set_peer_roles(_Lock, [], _Role) ->
    ok;
set_peer_roles(Lock, Nodes, Role) ->
    ok = chronicle:set_peer_roles(Lock, [{N, Role} || N <- Nodes]).

failover_opaque_key() ->
    '$failover_opaque'.

operation_key() ->
    unfinished_topology_operation.

delegate_operation({remove_peer, Node}) when Node =:= node() ->
    true;
delegate_operation(_) ->
    false.

operation_key_set(Oper, Lock, SelfRef) ->
    case delegate_operation(Oper) of
        true ->
            {set, operation_key(), {delegated, Oper, Lock, SelfRef}};
        false ->
            {set, operation_key(), {regular, Oper, Lock, SelfRef}}
    end.

is_delegated_operation() ->
    case chronicle_compat:get(operation_key(), #{}) of
        {ok, {delegated, _, _, _}} -> true;
        _ -> false
    end.

get_prev_failover_nodes(Snapshot) ->
    case chronicle_compat:get(Snapshot, failover_opaque_key(), #{}) of
        {ok, {_, Nodes}} ->
            Nodes;
        {error, not_found} ->
            []
    end.

transaction(Oper, Lock, SelfRef, Fun) ->
    chronicle_compat:txn(
      fun (Txn) ->
              Snapshot = chronicle_compat:txn_get_many(
                           [operation_key(), failover_opaque_key()], Txn),
              case maps:find(failover_opaque_key(), Snapshot) of
                  {ok, {V, _Rev}} ->
                      ?log_info("Unfinished failover ~p is detected.", [V]),
                      {abort, unfinished_failover};
                  _ ->
                      case maps:find(operation_key(), Snapshot) of
                          {ok, {{_, AnotherOper, _Lock, _SelfRef}, _Rev}}
                            when AnotherOper =/= Oper ->
                              RecoveryOper = recovery_oper(AnotherOper),
                              {commit, [operation_key_set(
                                          RecoveryOper, Lock, SelfRef)],
                               {need_recovery, RecoveryOper}};
                          _ ->
                              case Fun(Txn) of
                                  {commit, Sets} ->
                                      {commit,
                                       [operation_key_set(Oper, Lock, SelfRef)
                                        | Sets]};
                                  {abort, Error} ->
                                      {abort, Error}
                              end
                      end
              end
      end, #{read_consistency => quorum}).

transaction_with_key_remove(Key, Verify, Do) ->
    chronicle_compat:txn(
      fun (Txn) ->
              Value = case chronicle_compat:txn_get(Key, Txn) of
                          {ok, {V, _}} ->
                              V;
                          {error, not_found} ->
                              undefined
                      end,
              case Verify(Value) of
                  true ->
                      case Do(Txn) of
                          {commit, Sets} ->
                              {commit, [{delete, Key} | Sets]};
                          {abort, Error} ->
                              {abort, Error}
                      end;
                  false ->
                      ?log_warning("Incompatible value for key ~p found: ~p",
                                   [Key, Value]),
                      {abort, {incompatible_key_value, Key, Value}}
              end
      end).

remove_oper_key(Lock) ->
    ?log_debug("Removing operation key with lock ~p", [Lock]),
    {ok, _} =
        transaction_with_key_remove(
          operation_key(), fun({_, _, L, _}) -> L =:= Lock end,
          fun (_) -> {commit, []} end).

handle_kv_oper({add_replica, Node, GroupUUID, Services}, Transaction) ->
    ns_cluster_membership:add_node(Node, GroupUUID, Services, Transaction);
handle_kv_oper({remove_peer, Node}, Transaction) ->
    ns_cluster_membership:remove_nodes([Node], Transaction);
handle_kv_oper({activate_nodes, Nodes}, Transaction) ->
    ns_cluster_membership:activate(Nodes, Transaction);
handle_kv_oper({deactivate_nodes, Nodes}, Transaction) ->
    ns_cluster_membership:deactivate(Nodes, Transaction).

handle_topology_oper({add_replica, Node, _, _}, Lock) ->
    case chronicle:add_replica(Lock, Node) of
        {error, {already_member, Node, replica}} ->
            ?log_debug("Node ~p is already a member.", [Node]);
        ok ->
            ok
    end,
    ClusterInfo = chronicle:get_cluster_info(),
    ?log_debug("Cluster info: ~p", [ClusterInfo]),
    {ok, ClusterInfo};
handle_topology_oper({remove_peer, Node}, Lock) ->
    ok = chronicle:remove_peer(Lock, Node);
handle_topology_oper({activate_nodes, Nodes}, Lock) ->
    set_peer_roles(Lock, Nodes, voter);
handle_topology_oper({deactivate_nodes, Nodes}, Lock) ->
    set_peer_roles(Lock, Nodes, replica).

handle_oper(Oper, Lock, SelfRef) ->
    ?log_debug("Starting kv operation ~p with lock ~p", [Oper, Lock]),
    case handle_kv_oper(Oper, transaction(Oper, Lock, SelfRef, _)) of
        {ok, _} ->
            ?log_debug("Starting topology operation ~p with lock ~p",
                       [Oper, Lock]),
            RV = handle_topology_oper(Oper, Lock),
            case delegate_operation(Oper) of
                true ->
                    %% nodes_wanted should have been updated to not include
                    %% current master node(i.e., this node). New master will
                    %% takover and redo the operation.
                    ?log_debug("Will surrender mastership"),
                    delegated_operation;
                false ->
                    remove_oper_key(Lock),
                    RV
            end;
        {ok, _, {need_recovery, RecoveryOper}} ->
            ?log_debug("Recovery is needed for operation ~p", [RecoveryOper]),
            ok = handle_oper(RecoveryOper, Lock, SelfRef),
            handle_oper(Oper, Lock, SelfRef);
        Error ->
            Error
    end.

recovery_oper({add_replica, Node, _, _}) ->
    {remove_peer, Node};
recovery_oper(Oper) ->
    Oper.

cancel_janitor_timer(#state{janitor_timer_ref = Ref} = State) ->
    Ref =/= undefined andalso erlang:cancel_timer(Ref),
    misc:flush(janitor),
    misc:flush(arm_janitor_timer),
    State#state{janitor_timer_ref = undefined}.

arm_janitor_timer(State) ->
    NewState = cancel_janitor_timer(State),
    NewRef = erlang:send_after(?JANITOR_TIMEOUT, self(), janitor),
    NewState#state{janitor_timer_ref = NewRef}.

subscribe_to_chronicle_events(SelfRef) ->
    Self = self(),
    OperationKey = operation_key(),
    ns_pubsub:subscribe_link(
      chronicle_kv:event_manager(kv),
      fun ({{key, Key}, _, {updated, {delegated, _, _, Ref}}} = Evt)
            when Key =:= OperationKey,
                 Ref =/= SelfRef ->
              ?log_debug("Detected delegated operation: ~p. "
                         "Running janitor immediately.", [Evt]),
              Self ! janitor;
          ({{key, Key}, _, {updated, {_, _, _, Ref}}} = Evt)
            when Key =:= OperationKey,
                 Ref =/= SelfRef ->
              ?log_debug("Detected update on operation key: ~p. "
                         "Scheduling janitor.", [Evt]),
              Self ! arm_janitor_timer;
          (_) ->
              ok
      end).
