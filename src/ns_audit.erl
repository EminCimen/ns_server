%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc commands for audit logging
%%
-module(ns_audit).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([login_success/1,
         login_failure/1,
         session_expired/2,
         logout/1,
         delete_user/2,
         password_change/2,
         set_user/6,
         add_node/7,
         remove_node/2,
         failover_nodes/3,
         enter_node_recovery/3,
         rebalance_initiated/4,
         create_bucket/4,
         modify_bucket/4,
         delete_bucket/2,
         flush_bucket/2,
         create_scope/4,
         drop_scope/4,
         create_collection/5,
         modify_collection/5,
         drop_collection/5,
         set_manifest/5,
         start_loading_sample/2,
         disk_storage_conf/3,
         rename_node/3,
         setup_node_services/3,
         cluster_settings/3,
         add_group/2,
         delete_group/2,
         update_group/2,
         enable_auto_failover/4,
         disable_auto_failover/1,
         reset_auto_failover_count/1,
         modify_retry_rebalance/2,
         alerts/2,
         alert_email_sent/4,
         modify_compaction_settings/2,
         regenerate_certificate/2,
         setup_saslauthd/2,
         settings/3,
         upload_cluster_ca/3,
         reload_node_certificate/3,
         delete_cluster_ca/2,
         modify_index_storage_mode/2,
         master_password_change/2,
         data_key_rotation/2,
         password_policy/2,
         client_cert_auth/2,
         start_log_collection/4,
         modify_log_redaction_settings/2,
         modify_audit_settings/3,
         read_doc/3,
         mutate_doc/4,
         set_user_group/6,
         delete_user_group/2,
         ldap_settings/2,
         set_user_profile/3,
         delete_user_profile/2,
         enable_auto_reprovision/2,
         disable_auto_reprovision/1,
         auth_failure/1,
         rbac_info_retrieved/2,
         admin_password_reset/1
        ]).

-export([start_link/0, stats/0]).

%% gen_server callbacks
-export([init/1, handle_cast/2, handle_call/3,
         handle_info/2, terminate/2, code_change/3]).

-import(json_builder,
        [to_binary/1,
         prepare_list/1]).

%% Maximum number of tries to log to memcached before dropping the event.
-define(MAX_RETRIES, ?get_param(audit_max_retries, 5)).

-record(state, {queue, retries}).

backup_path() ->
    filename:join(path_config:component_path(data, "config"), "audit.bak").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:process_flag(trap_exit, true),
    {ok, #state{queue = maybe_restore_backup(), retries = 0}}.

terminate(_Reason, #state{queue = Queue}) ->
    maybe_backup(Queue).

code_change(_OldVsn, State, _) -> {ok, State}.

obscure_sessionid(Body) ->
    misc:rewrite_tuples(
      fun do_obscure_session_id/1, Body).

do_obscure_session_id({sessionid, SessionId}) ->
    %% The sessionid is obscured in a manner which maintains supportability
    %% as it allows tracking all the actions related to the sessionid. This
    %% wouldn't be possible if it were obscured using something like "******".
    Salt = scram_sha:get_fallback_salt(),
    ObscuredId = crypto:mac(hmac, sha, Salt, SessionId),

    {stop, {sessionid, misc:hexify(ObscuredId)}};
do_obscure_session_id(_Other) ->
    continue.

handle_call({log, Code, Body, IsSync}, From, #state{queue = Queue} = State) ->
    CleanedQueue =
        case queue:len(Queue) > ns_config:read_key_fast(max_audit_queue_length, 1000) of
            true ->
                ?log_error("Audit queue is too large. Dropping audit records to info log"),
                print_audit_records(Queue),
                queue:new();
            false ->
                Queue
        end,
    %% The record logged to the audit log shouldn't contain the sessionid
    %% as it could be used to obtain unauthorized access.
    ObscuredBody = obscure_sessionid(Body),

    %% The info logged to other logs (e.g. debug.log) should have additional
    %% information hidden.
    ?log_debug("Audit ~p: ~p", [Code,
                                ns_config_log:tag_user_data(ObscuredBody)]),

    %% While the above debug log is very useful when triaging issues (to
    %% see which audited operations are occurring), we should save cycles
    %% if audit logging is disabled by not sending it to memcached (which
    %% will just throw it away).
    AuditEnabled = ns_audit_cfg:is_enabled(),
    NewQueue =
        case AuditEnabled of
            false ->
                CleanedQueue;
            true ->
                EncodedBody = ejson:encode({ObscuredBody}),
                Continuation =
                    case IsSync of
                        true ->
                            {true, From};
                        false ->
                            false
                    end,
                self() ! send,
                queue:in({Code, EncodedBody, Continuation}, CleanedQueue)
        end,

    %% For synchronous audits, if the audit wasn't queued then we send the
    %% response now as there's no deferred "Continuation".
    case IsSync andalso AuditEnabled of
        true -> {noreply, State#state{queue = NewQueue}};
        false -> {reply, ok, State#state{queue = NewQueue}}
    end;

handle_call(stats, _From, #state{queue = Queue, retries = Retries} = State) ->
    {reply, [{queue_length, queue:len(Queue)},
             {unsuccessful_retries, Retries}], State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(send, #state{queue = Queue, retries = Retries} = State) ->
    misc:flush(send),
    MaxRetries = ?MAX_RETRIES,
    {Res, NewQueue0} = send_to_memcached(Queue),
    {NewRetries, NewQueue} =
        case Res of
            ok ->
                {0, NewQueue0};
            error when Retries < MaxRetries ->
                erlang:send_after(1000, self(), send),
                {Retries + 1, NewQueue0};
            error ->
                {{value, {_, _, IsSync} = V}, NewQueue1} = queue:out(NewQueue0),
                ?log_error("Dropping audit entry ~p after ~p retries.",
                           [V, ?MAX_RETRIES]),
                maybe_reply(IsSync, {error, dropped}),
                {0, NewQueue1}
        end,
    {noreply, State#state{queue = NewQueue, retries = NewRetries}};
handle_info({'EXIT', From, Reason}, State) ->
    ?log_debug("Received exit from ~p with reason ~p. Exiting.", [From, Reason]),
    {stop, Reason, State}.

maybe_backup(Queue) ->
    case queue:is_empty(Queue) of
        false ->
            ?log_warning("Backup non empty audit queue"),
            case misc:write_file(backup_path(),
                                 term_to_binary(
                                   convert_to_async_response(Queue))) of
                ok ->
                    ok;
                Error ->
                    ?log_error("Error backing up audit queue: ~p", [Error])
            end;
        true ->
            ok
    end.

convert_to_async_response(Queue) ->
    queue:fold(
      %% "_Fun" is invalid if it has been saved to disk. It can contain either
      %% a closure (before 7.1.2) or {true, From} | false (after 7.1.2).
      %% "From" is never saved to disk and all synchronous ({true, From})
      %% calls are converted to "false" because pids() also cannot be safely
      %% saved and loaded from disk.
      fun ({Code, Body, _Fun}, Acc) ->
              queue:in({Code, Body, false}, Acc)
      end,
      queue:new(), Queue).

restore_backup(Binary) ->
    try binary_to_term(Binary, [safe]) of
        Queue ->
            case queue:is_queue(Queue) of
                true ->
                    ?log_info("Audit queue was restored from the backup"),
                    self() ! send,
                    convert_to_async_response(Queue);
                false ->
                    ?log_error("Backup content is not a proper queue"),
                    error
            end
    catch
        T:E ->
            ?log_error("Backup is malformed ~p", [{T,E}]),
            error
    end.

maybe_restore_backup() ->
    case file:read_file(backup_path()) of
        {ok, Binary} ->
            Queue =
                case restore_backup(Binary) of
                    error ->
                        queue:new();
                    Q ->
                        Q
                end,
            case file:delete(backup_path()) of
                ok ->
                    ok;
                Error ->
                    ?log_error("Unable to delete backup file: ~p", [Error])
            end,
            Queue;
        {error, enoent} ->
            queue:new();
        Other ->
            ?log_error("Unexpected error when reading backup: ~p", [Other]),
            queue:new()
    end.

code(login_success) ->
    8192;
code(login_failure) ->
    8193;
code(delete_user) ->
    8194;
code(password_change) ->
    8195;
code(add_node) ->
    8196;
code(remove_node) ->
    8197;
code(failover_nodes) ->
    8198;
code(enter_node_recovery) ->
    8199;
code(rebalance_initiated) ->
    8200;
code(create_bucket) ->
    8201;
code(modify_bucket) ->
    8202;
code(delete_bucket) ->
    8203;
code(flush_bucket) ->
    8204;
code(start_loading_sample) ->
    8205;
code(disk_storage_conf) ->
    8206;
code(rename_node) ->
    8207;
code(setup_node_services) ->
    8208;
code(cluster_settings) ->
    8209;
code(add_group) ->
    8210;
code(delete_group) ->
    8211;
code(update_group) ->
    8212;
code(enable_auto_failover) ->
    8220;
code(disable_auto_failover) ->
    8221;
code(reset_auto_failover_count) ->
    8222;
code(enable_cluster_alerts) ->
    8223;
code(disable_cluster_alerts) ->
    8224;
code(modify_compaction_settings) ->
    8225;
code(regenerate_certificate) ->
    8226;
code(setup_saslauthd) ->
    8227;
code(internal_settings) ->
    8228;
code(upload_cluster_ca) ->
    8229;
code(reload_node_certificate) ->
    8230;
code(modify_index_storage_mode) ->
    8231;
code(set_user) ->
    8232;
code(master_password_change) ->
    8233;
code(data_key_rotation) ->
    8234;
code(password_policy) ->
    8235;
code(client_cert_auth) ->
    8236;
code(security_settings) ->
    8237;
code(start_log_collection) ->
    8238;
code(modify_log_redaction_settings) ->
    8239;
code(modify_audit_settings) ->
    8240;
code(modify_index_settings) ->
    8241;
code(modify_query_settings) ->
    8242;
code(mutate_doc) ->
    8243;
code(set_user_group) ->
    8244;
code(delete_user_group) ->
    8245;
code(ldap_settings) ->
    8246;
code(developer_preview_settings) ->
    8247;
code(license_settings) ->
    8248;
code(set_user_profile) ->
    8249;
code(delete_user_profile) ->
    8250;
code(modify_retry_rebalance) ->
    8251;
code(enable_auto_reprovision) ->
    8252;
code(disable_auto_reprovision) ->
    8253;
code(failover_settings) ->
    8254;
code(read_doc) ->
    8255;
code(logout) ->
    8256;
code(alert_email_sent) ->
    8257;
code(session_expired) ->
    8258;
code(create_scope) ->
    8259;
code(drop_scope) ->
    8260;
code(create_collection) ->
    8261;
code(drop_collection) ->
    8262;
code(set_manifest) ->
    8263;
code(auth_failure) ->
    8264;
code(rbac_info_retrieved) ->
    8265;
code(admin_password_reset) ->
    8266;
code(modify_analytics_settings) ->
    8267;
%% 8268 (update_scope) removed in 7.5
code(delete_cluster_ca) ->
    8269;
code(modify_collection) ->
    8270;
code(serverless_settings) ->
    8271.


now_to_iso8601(Now = {_, _, Microsecs}) ->
    LocalNow = calendar:now_to_local_time(Now),

    UTCSec = calendar:datetime_to_gregorian_seconds(calendar:now_to_universal_time(Now)),
    LocSec = calendar:datetime_to_gregorian_seconds(LocalNow),
    Offset =
        case (LocSec - UTCSec) div 60 of
            0 ->
                "Z";
            OffsetTotalMins ->
                OffsetHrs = OffsetTotalMins div 60,
                OffsetMin = abs(OffsetTotalMins rem 60),
                OffsetSign = case OffsetHrs < 0 of
                                 true ->
                                     "-";
                                 false ->
                                     "+"
                             end,
                io_lib:format("~s~2.2.0w:~2.2.0w", [OffsetSign, abs(OffsetHrs), OffsetMin])
        end,
    format_iso8601(LocalNow, Microsecs, Offset).

format_iso8601({{YYYY, MM, DD}, {Hour, Min, Sec}}, Microsecs, Offset) ->
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0wT~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0w",
                  [YYYY, MM, DD, Hour, Min, Sec, Microsecs div 1000]) ++ Offset.

convert_domain(admin) ->
    builtin;
convert_domain(ro_admin) ->
    builtin;
convert_domain(D) ->
    D.

get_identity(undefined) ->
    undefined;
get_identity({User, Domain}) ->
    {[{domain, convert_domain(Domain)}, {user, to_binary(User)}]}.

get_socket_name(Req, SockNameGetter) ->
    Socket = mochiweb_request:get(socket, Req),
    {ok, {Host, Port}} = SockNameGetter(Socket),
    {[{ip, to_binary(inet_parse:ntoa(Host))},
      {port, Port}]}.

get_remote(Req) ->
    get_socket_name(Req, fun mochiweb_socket:peername/1).

get_local(Req) ->
    get_socket_name(Req, fun network:sockname/1).

prepare(Req, Params) ->
    IdentityProps = case Req of
                        undefined ->
                            [{real_userid, undefined},
                             {sessionid, undefined},
                             {remote, undefined},
                             {local, undefined}];
                        _ ->
                            [{real_userid,
                              get_identity(menelaus_auth:get_identity(Req))},
                             {sessionid, menelaus_auth:get_token(Req)},
                             {remote, get_remote(Req)},
                             {local, get_local(Req)}]
                    end,

    %% Any params specified by the caller have precedence.
    Body = misc:update_proplist(
             [{timestamp, now_to_iso8601(os:timestamp())} | IdentityProps],
             Params),

    prepare_list(Body).

put(Code, Req, Params) ->
    Body = prepare(Req, Params),
    ok = gen_server:call(?MODULE, {log, Code, Body, false}).

sync_put(Code, Req, Params) ->
    Body = prepare(Req, Params),
    ok = gen_server:call(?MODULE, {log, Code, Body, true}).

maybe_reply({true, From}, Response) ->
    gen_server:reply(From, Response);
maybe_reply(false, _Response) ->
    ok.

send_to_memcached(Queue) ->
    case queue:out(Queue) of
        {empty, Queue} ->
            {ok, Queue};
        {{value, {Code, EncodedBody, IsSync}}, NewQueue} ->
            case (catch ns_memcached_sockets_pool:executing_on_socket(
                          fun (Sock) ->
                                  mc_client_binary:audit_put(Sock, code(Code), EncodedBody)
                          end)) of
                ok ->
                    maybe_reply(IsSync, ok),
                    send_to_memcached(NewQueue);
                {memcached_error, einval, Error} ->
                    ?log_error("Audit put call ~p with body ~p failed with "
                               "error ~p. Dropping audit event.",
                               [Code, EncodedBody, Error]),
                    maybe_reply(IsSync, {error, dropped}),
                    {ok, NewQueue};
                Error ->
                    ?log_debug("Audit put call ~p with body ~p failed with "
                               "error ~p.",
                               [Code, EncodedBody, Error]),
                    {error, Queue}
            end
    end.

stats() ->
    {ok, gen_server:call(?MODULE, stats)}.

login_success(Req) ->
    Identity = menelaus_auth:get_identity(Req),
    Roles = menelaus_roles:get_roles(Identity),
    put(login_success, Req,
        [{roles, {list, [menelaus_web_rbac:role_to_string(Role) || Role <- Roles]}}]).

login_failure(Req) ->
    put(login_failure, Req, []).

%% This audit event doesn't have a "Req" because it's not caused by an HTTP
%% request.
session_expired(Identity, Token) ->
    put(session_expired, undefined,
        [{real_userid, get_identity(Identity)}, {sessionid, Token}]).

logout(Req) ->
    put(logout, Req, []).

delete_user(Req, Identity) ->
    put(delete_user, Req, [{identity, get_identity(Identity)}]).

password_change(Req, Identity) ->
    put(password_change, Req, [{identity, get_identity(Identity)}]).

set_user(Req, Identity, Roles, Name, Groups, Reason) ->
    put(set_user, Req, [{identity, get_identity(Identity)},
                        {roles, {list, [menelaus_web_rbac:role_to_string(Role) ||
                                        Role <- Roles]}},
                        {full_name, Name},
                        {groups, {list, [G || Groups =/= undefined,
                                              G <- Groups]}},
                        {reason, Reason}]).

add_node(Req, Hostname, Port, User, GroupUUID, Services, Node) ->
    put(add_node, Req, [{node, Node},
                        {groupUUID, GroupUUID},
                        {hostname, Hostname},
                        {port, Port},
                        {services, {list, Services}},
                        {user, User}]).

remove_node(Req, Node) ->
    put(remove_node, Req, [{node, Node}]).

failover_nodes(Req, Nodes, Type) ->
    put(failover_nodes, Req, [{nodes, {list, Nodes}}, {type, Type}]).

enter_node_recovery(Req, Node, Type) ->
    put(enter_node_recovery, Req, [{node, Node}, {type, Type}]).

rebalance_initiated(Req, KnownNodes, EjectedNodes, DeltaRecoveryBuckets) ->
    Buckets = case DeltaRecoveryBuckets of
                  all ->
                      all;
                  _ ->
                      {list, DeltaRecoveryBuckets}
              end,
    put(rebalance_initiated, Req,
        [{known_nodes, {list, KnownNodes}},
         {ejected_nodes, {list, EjectedNodes}},
         {delta_recovery_buckets, Buckets}]).

create_bucket(Req, Name, Type, Props) ->
    put(create_bucket, Req,
        [{bucket_name, Name},
         {type, Type},
         {props, {ns_bucket:build_bucket_props_json(Props)}}]).

modify_bucket(Req, Name, Type, Props) ->
    put(modify_bucket, Req,
        [{bucket_name, Name},
         {type, Type},
         {props, {ns_bucket:build_bucket_props_json(Props)}}]).

delete_bucket(Req, Name) ->
    put(delete_bucket, Req, [{bucket_name, Name}]).

flush_bucket(Req, Name) ->
    put(flush_bucket, Req, [{bucket_name, Name}]).

start_loading_sample(Req, Name) ->
    put(start_loading_sample, Req, [{bucket_name, Name}]).

disk_storage_conf(Req, Node, Params) ->
    DbPath = proplists:get_value("path", Params),
    IxPath = proplists:get_value("index_path", Params),
    CbasPaths = proplists:get_all_values("cbas_path", Params),
    JavaHome = proplists:get_value("java_home", Params),
    EvPath = proplists:get_value("eventing_path", Params),

    put(disk_storage_conf, Req,
        [{node, Node}] ++
        [{db_path, DbPath} || DbPath =/= undefined] ++
        [{index_path, IxPath} || IxPath =/= undefined] ++
        [{java_home, JavaHome} || JavaHome =/= undefined] ++
        [{eventing_path, EvPath} || EvPath =/= undefined] ++
        [{cbas_dirs, {list, CbasPaths}} || CbasPaths =/= []]).

rename_node(Req, Node, Hostname) ->
    put(rename_node, Req, [{node, Node},
                           {hostname, Hostname}]).

setup_node_services(Req, Node, Services) ->
    put(setup_node_services, Req, [{node, Node},
                                   {services, {list, Services}}]).

cluster_settings(Req, Quotas, ClusterName) ->
    put(cluster_settings, Req, [{quotas, {propset, Quotas}},
                                {cluster_name, ClusterName}]).

add_group(Req, Group) ->
    put(add_group, Req, [{group_name, proplists:get_value(name, Group)},
                         {uuid, proplists:get_value(uuid, Group)}]).

delete_group(Req, Group) ->
    put(delete_group, Req, [{group_name, proplists:get_value(name, Group)},
                            {uuid, proplists:get_value(uuid, Group)}]).

update_group(Req, Group) ->
    put(update_group, Req, [{group_name, proplists:get_value(name, Group)},
                            {uuid, proplists:get_value(uuid, Group)},
                            {nodes, {list, proplists:get_value(nodes, Group, [])}}]).

build_auto_failover_extras(Extras) ->
    lists:foldl(
      fun ({failover_on_data_disk_issues, V}, Acc) ->
              [{failover_on_data_disk_issues, {prepare_list(V)}} | Acc];
          ({failover_server_group, _} = T, Acc) ->
              [T | Acc];
          ({can_abort_rebalance, _} = T, Acc) ->
              [T | Acc];
          ({disable_max_count, _} = T, Acc) ->
              [T | Acc];
          (_, Acc) ->
              Acc
      end, [], Extras).

enable_auto_failover(Req, Timeout, MaxNodes, Extras) ->
    Params = [{timeout, Timeout}, {max_nodes, MaxNodes}] ++
        build_auto_failover_extras(Extras),
    put(enable_auto_failover, Req, Params).

disable_auto_failover(Req) ->
    put(disable_auto_failover, Req, []).

reset_auto_failover_count(Req) ->
    put(reset_auto_failover_count, Req, []).

modify_retry_rebalance(Req, New) ->
    put(modify_retry_rebalance, Req, New).

enable_auto_reprovision(Req, MaxNodes) ->
    put(enable_auto_reprovision, Req, [{max_nodes, MaxNodes}]).

disable_auto_reprovision(Req) ->
    put(disable_auto_reprovision, Req, []).

alerts(Req, Settings) ->
    case misc:expect_prop_value(enabled, Settings) of
        false ->
            put(disable_cluster_alerts, Req, []);
        true ->
            EmailServer = misc:expect_prop_value(email_server, Settings),
            EmailServer1 = proplists:delete(pass, EmailServer),
            put(enable_cluster_alerts, Req,
                [{sender, misc:expect_prop_value(sender, Settings)},
                 {recipients, {list, misc:expect_prop_value(recipients, Settings)}},
                 {alerts, {list, misc:expect_prop_value(alerts, Settings)}},
                 {email_server, {prepare_list(EmailServer1)}}])
    end.

alert_email_sent(Sender, Recipients, Subject, Body) ->
    put(alert_email_sent, undefined,
        [{sender, Sender}, {recipients, {list, Recipients}},
         {subject, Subject}, {message, Body}]).

modify_compaction_settings(Req, Settings) ->
    Data = ns_bucket:build_compaction_settings_json(Settings),
    put(modify_compaction_settings, Req, Data).

regenerate_certificate(Req, Params) ->
    put(regenerate_certificate, Req, Params).

build_saslauthd_users(asterisk) ->
    default;
build_saslauthd_users(List) ->
    {list, List}.

setup_saslauthd(Req, Props) ->
    put(setup_saslauthd, Req,
        [{enabled, misc:expect_prop_value(enabled, Props)},
         {admins, build_saslauthd_users(misc:expect_prop_value(admins, Props))},
         {ro_admins, build_saslauthd_users(misc:expect_prop_value(roAdmins, Props))}]).

upload_cluster_ca(Req, Subject, Expires) ->
    ExpiresDateTime = calendar:gregorian_seconds_to_datetime(Expires),
    put(upload_cluster_ca, Req, [{subject, Subject},
                                 {expires, format_iso8601(ExpiresDateTime, 0, "Z")}]).

delete_cluster_ca(Req, Subject) ->
    put(delete_cluster_ca, Req, [{subject, Subject}]).

reload_node_certificate(Req, Subject, Expires) ->
    ExpiresDateTime = calendar:gregorian_seconds_to_datetime(Expires),
    put(reload_node_certificate, Req, [{subject, Subject},
                                       {expires, format_iso8601(ExpiresDateTime, 0, "Z")}]).

modify_index_storage_mode(Req, StorageMode) ->
    put(modify_index_storage_mode, Req, [{storageMode, StorageMode}]).

master_password_change(Req, undefined) ->
    put(master_password_change, Req, []);
master_password_change(Req, Error) ->
    put(master_password_change, Req, [{error, Error}]).

data_key_rotation(Req, undefined) ->
    put(data_key_rotation, Req, []);
data_key_rotation(Req, Error) ->
    put(data_key_rotation, Req, [{error, Error}]).

password_policy(Req, Policy) ->
    PreparedPolicy =
        lists:keystore(must_present, 1, Policy,
                       {must_present, {list, proplists:get_value(must_present, Policy)}}),
    put(password_policy, Req, PreparedPolicy).

client_cert_auth(Req, ClientCertAuth) ->
    State = lists:keyfind(state, 1, ClientCertAuth),
    {PrefixesKey, Triples} = lists:keyfind(prefixes, 1, ClientCertAuth),
    NewTriples = [{propset, T} || T <- Triples],
    Val = [State, {PrefixesKey, {list, NewTriples}}],
    put(client_cert_auth, Req, Val).

settings(Req, Key, Settings) ->
    Settings1 = case Settings of
                    {json, S} ->
                        S;
                    _ ->
                        prepare_list(Settings)
                end,
    Settings2 =
        lists:map(fun ({{K, SubK}, V}) when K =:= Key ->
                          {SubK, V};
                      (KV) ->
                          KV
                  end, Settings1),
    AuditKey = list_to_atom(atom_to_list(Key) ++ "_settings"),
    put(AuditKey, Req, [{settings, {Settings2}}]).

start_log_collection(Req, Nodes, BaseURL, Options) ->
    put(start_log_collection, Req,
        [{nodes, {list, Nodes}}, {base_url, BaseURL}] ++
            Options).

modify_log_redaction_settings(Req, Settings) ->
    put(modify_log_redaction_settings, Req,
        [{log_redaction_default_cfg, {prepare_list(Settings)}}]).

jsonify_audit_settings(Settings0) ->
    Settings = lists:keysort(1, Settings0),
    lists:foldr(fun ({K, V}, Acc) ->
                        case K of
                            log_path ->
                                [{K, list_to_binary(V)} | Acc];
                            enabled ->
                                [{enabled_audit_ids, V} | Acc];
                            disabled ->
                                Acc;
                            auditd_enabled ->
                                Acc;
                            _ ->
                                [{K, V} | Acc]
                        end
                end, [], Settings).

get_new_audit_settings(OldSettings, NewKVs) ->
    misc:update_proplist(OldSettings, NewKVs).

maybe_add_event_log(Settings, Settings) ->
   ok;
maybe_add_event_log(OldSettings, NewSettings) ->
    TransformFun = fun (Settings) ->
                           jsonify_audit_settings(
                             event_log:redact_keys(Settings, [disabled_users]))
                   end,
    OldSettingsJSON = [{old_settings, {TransformFun(OldSettings)}}],
    NewSettingsJSON = [{new_settings, {TransformFun(NewSettings)}}],

    case {proplists:get_bool(auditd_enabled, NewSettings),
          proplists:get_bool(auditd_enabled, OldSettings)} of
        {Same, Same} ->
            event_log:add_log(audit_cfg_changed,
                              OldSettingsJSON ++ NewSettingsJSON);
        {true, false} ->
            event_log:add_log(audit_enabled,
                              NewSettingsJSON);
        {false, true} ->
            event_log:add_log(audit_disabled,
                              OldSettingsJSON)
    end.

modify_audit_settings(Req, NewKVs, OldSettings) ->
    NewSettings = get_new_audit_settings(OldSettings, NewKVs),
    case proplists:get_bool(auditd_enabled, NewSettings) of
        false ->
            sync_put(modify_audit_settings, Req, [{auditd_enabled, false}]);
        true ->
            put(modify_audit_settings, Req,
                [prepare_audit_setting(S) || S <- NewKVs])
    end,
    maybe_add_event_log(lists:keysort(1, OldSettings),
                        lists:keysort(1, NewSettings)).

prepare_audit_setting({enabled, List}) ->
    {enabled, {list, List}};
prepare_audit_setting({disabled, List}) ->
    {disabled, {list, List}};
prepare_audit_setting({disabled_users, Users}) ->
    {disabled_userids, {list, [get_identity(U) || U <- Users]}};
prepare_audit_setting(Setting) ->
    Setting.

print_audit_records(Queue) ->
    case queue:out(Queue) of
        {empty, _} ->
            ok;
        {{value, {_, _, IsSync} = V}, NewQueue} ->
            ?log_info("Dropped audit entry: ~p", [V]),
            maybe_reply(IsSync, {error, dropped}),
            print_audit_records(NewQueue)
    end.

read_doc(Req, BucketName, DocId) ->
    put(read_doc, Req, [{bucket_name, BucketName},
                        {doc_id, DocId}]).

mutate_doc(Req, Oper, BucketName, DocId) ->
    put(mutate_doc, Req, [{bucket_name, BucketName},
                          {doc_id, DocId},
                          {operation, Oper}]).

set_user_group(Req, Id, Roles, Description, LDAPGroup, Reason) ->
    put(set_user_group, Req,
        [{group_name, Id},
         {roles, {list, [menelaus_web_rbac:role_to_string(Role)
                         || Role <- Roles]}},
         {ldap_group_ref, LDAPGroup},
         {description, Description},
         {reason, Reason}]).

delete_user_group(Req, Id) ->
    put(delete_user_group, Req, [{group_name, Id}]).

ldap_settings(Req, Settings) ->
    put(ldap_settings, Req, [prepare_ldap_setting(S) || S <- Settings]).

prepare_ldap_setting({hosts, List}) -> {hosts, {list, List}};
prepare_ldap_setting({userDNMapping = K, JSON}) -> {K, ejson:encode(JSON)};
prepare_ldap_setting(Default) -> Default.

set_user_profile(Req, Identity, Json) ->
    put(set_user_profile, Req,
        [{identity, get_identity(Identity)},
         {profile, {json, Json}}]).

delete_user_profile(Req, Identity) ->
    put(delete_user_profile, Req, [{identity, get_identity(Identity)}]).

create_scope(Req, BucketName, ScopeName, Uid) ->
    put(create_scope, Req,
        [{bucket_name, BucketName}, {scope_name, ScopeName},
         {new_manifest_uid, Uid}]).

drop_scope(Req, BucketName, ScopeName, Uid) ->
    put(drop_scope, Req,
        [{bucket_name, BucketName}, {scope_name, ScopeName},
         {new_manifest_uid, Uid}]).

create_collection(Req, BucketName, ScopeName, CollectionName,  Uid) ->
    put(create_collection, Req,
        [{bucket_name, BucketName}, {scope_name, ScopeName},
         {collection_name, CollectionName},
         {new_manifest_uid, Uid}]).

modify_collection(Req, BucketName, ScopeName, CollectionName,  Uid) ->
    put(modify_collection, Req,
        [{bucket_name, BucketName}, {scope_name, ScopeName},
         {collection_name, CollectionName},
         {new_manifest_uid, Uid}]).

drop_collection(Req, BucketName, ScopeName, CollectionName, Uid) ->
    put(drop_collection, Req,
        [{bucket_name, BucketName}, {scope_name, ScopeName},
         {collection_name, CollectionName}, {new_manifest_uid, Uid}]).

set_manifest(Req, BucketName, InputManifest, ValidOnUid, Uid) ->
    put(set_manifest, Req,
        [{bucket_name, BucketName}, {input_manifest, InputManifest},
         {valid_on_uid, ValidOnUid}, {new_manifest_uid, Uid}]).

auth_failure(Req0) ->
    Req =
        case menelaus_auth:get_identity(Req0) of
            {[], anonymous} ->
                %% This handles the case where an authentication failure has
                %% occurred because the request didn't have authorization
                %% information. This  leads to ns_server adding arbitrary
                %% identity, including the 'anonymous' domain, in order to
                %% check permissions for the request.
                %% memcached doesn't allow the 'anonymous' domain and since
                %% the identity was arbitrarily added it is now removed.
                case testconditions:get(keep_invalid_domain) of
                    false ->
                        menelaus_auth:delete_headers(Req0,
                                                     ["menelaus-auth-user",
                                                      "menelaus-auth-domain"]);
                    true ->
                        %% For test purposes leave content in the audit event
                        %% that memcached will reject. This allows testing of
                        %% ns_server's handing of errors from memcached.
                        Req0
                end;
            _ ->
                Req0
        end,

    RawPath = mochiweb_request:get(raw_path, Req),
    put(auth_failure, Req, [{raw_url, RawPath}]).

rbac_info_retrieved(Req, Type) ->
    RawPath = mochiweb_request:get(raw_path, Req),
    put(rbac_info_retrieved, Req, [{raw_url, RawPath},
                                   {type, Type}]).

admin_password_reset(Req) ->
    put(admin_password_reset, Req, []).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Had to reimplement some aspects of the backup logic to get a functioning,
%% isolated test. Otherwise there were issues with paths from the test context.
maybe_backup_test() ->
    TestFile = "test_audit.bak",
    try
        L = [{X, Y, fun (_Resp) ->
                            error("this should never be called")
                    end}
             || {X, Y} <- [{code1, "1"}, {code2, "2"}, {code3, "3"}]],
        case misc:write_file(TestFile, term_to_binary(queue:from_list(L))) of
            ok ->
                ok;
            Error ->
                WriteErr = io_lib:format("Failed to write backup: ~p", [Error]),
                exit(WriteErr)
        end,
        Q2 = case file:read_file(TestFile) of
                 {ok, Binary} ->
                     Resp = restore_backup(Binary),
                     ?assertEqual(process_info(self(), message_queue_len),
                                  {message_queue_len, 1}),
                     ?flush(send),
                     ?assertEqual(process_info(self(), message_queue_len),
                                  {message_queue_len, 0}),
                     Resp;
                 X ->
                     ReadErr = io_lib:format("Failed to restore backup: ~p", [X]),
                     exit(ReadErr)
             end,

        %% make sure that we have successfully replaced all anonymous functions
        %% with 'false'. This effectively converted all the synchronous requests
        %% to asynchronous requests.
        lists:foreach(fun ({_, _, Val}) -> ?assertEqual(Val, false) end,
                      queue:to_list(Q2))
    after
        case file:delete(TestFile) of
            ok ->
                ok;
            Err ->
                DeleteErr = io_lib:format("Unable to delete backup: ~p", [Err]),
                exit(DeleteErr)
        end
    end.

-endif.
