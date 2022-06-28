%%%-------------------------------------------------------------------
%%% @author jiaoyinyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc kcp process
%%% @end
%%%-------------------------------------------------------------------
-module(gen_kcp).
-author("jiaoyinyi").

-behaviour(gen_server).

%% API
-export([
    open/2, open/4
    , close/1
    , connect/3
    , send/2
    , async_send/2
    , recv/1, recv/2
    , async_recv/1, async_recv/2
    , getopts/2
    , setopts/2
    , get_socket/1
]).
-export([start_link/4, output/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-include("kcp.hrl").

-define(_IS_TIMEOUT(Timeout), (Timeout =:= infinity orelse is_integer(Timeout) andalso Timeout >= 0)).

-type option() :: waitsnd | nodelay | interval | fastresend | nocwnd | snd_wnd | rcv_wnd | mtu | minrto | output.

-export_type([option/0]).


%% @doc 创建kcp socket
-spec open(pos_integer(), pos_integer()) -> {ok, pid()} | {error, term()}.
open(Port, Conv) ->
    open(Port, Conv, [], []).

%% @doc 创建kcp socket
-spec open(pos_integer(), pos_integer(), list(), list()) -> {ok, pid()} | {error, term()}.
open(Port, Conv, UdpOpts, KcpOpts) ->
    start_link(Port, Conv, UdpOpts, KcpOpts).

%% @doc 关闭kcp socket
-spec close(pid()) -> ok | {error, term()}.
close(Pid) ->
    call(Pid, close).

%% @doc 连接，与对端ip、端口绑定
-spec connect(pid(), inet:ip_address(), inet:port_number()) -> ok | {error, term()}.
connect(Pid, Ip, Port) ->
    call(Pid, {connect, Ip, Port}).

%% @doc 阻塞式发送数据
-spec send(pid(), binary()) -> ok | {error, term()}.
send(Pid, Packet) ->
    case async_send(Pid, Packet) of
        {ok, Ref} ->
            receive
                {kcp_reply, Pid, Ref, Status} ->
                    Status;
                {'EXIT', Pid, _Reason} ->
                    {error, closed}
            end;
        Error ->
            Error
    end.

%% @doc 非阻塞式发送数据 异步消息 {kcp_reply, pid(), reference(), ok | {error, reason()}}
-spec async_send(pid(), binary()) -> {ok, reference()} | {error, term()}.
async_send(Pid, Packet) ->
    call(Pid, {async_send, Packet}, infinity).

%% @doc 阻塞式接收数据
-spec recv(pid()) -> {ok, binary()} | {error, term()}.
recv(Pid) ->
    recv(Pid, infinity).
-spec recv(pid(), timeout()) -> {ok, binary()} | {error, term()}.
recv(Pid, Timeout) when ?_IS_TIMEOUT(Timeout) ->
    case async_recv(Pid, Timeout) of
        {ok, Ref} ->
            receive
                {kcp, Pid, Ref, Status} ->
                    Status;
                {'EXIT', Pid, _Reason} ->
                    {error, closed}
            end;
        Error ->
            Error
    end.

%% @doc 非阻塞式接收数据 异步消息 {kcp, pid(), reference(), {ok, binary()} | {error, reason()}}
-spec async_recv(pid()) -> {ok, reference()} | {error, term()}.
async_recv(Pid) ->
    async_recv(Pid, infinity).
-spec async_recv(pid(), timeout()) -> {ok, reference()} | {error, term()}.
async_recv(Pid, Timeout) when ?_IS_TIMEOUT(Timeout) ->
    call(Pid, {async_recv, Timeout}, infinity).

%% @doc 获取kcp参数
-spec getopts(pid(), [Opt]) -> {ok, [{Opt, Val}]} | {error, term()} when
    Opt :: option(),
    Val :: term().
getopts(Pid, Opts) ->
    call(Pid, {getopts, Opts}).

%% @doc 设置kcp参数
-spec setopts(pid(), [{Opt, Val}]) -> ok | {error, term()} when
    Opt :: option(),
    Val :: term().
setopts(Pid, Opts) ->
    call(Pid, {setopts, Opts}).

%% @doc 获取socket
-spec get_socket(pid()) -> {ok, port()} | {error, term()}.
get_socket(Pid) ->
    call(Pid, get_socket).

call(Pid, Call) ->
    call(Pid, Call, 10000).
call(Pid, Call, Timeout) ->
    case catch gen_server:call(Pid, Call, Timeout) of
        {'EXIT', {timeout, _Err}} ->
            {error, timeout};
        {'EXIT', {{nodedown, Node}, _Err}} ->
            {error, {nodedown, Node}};
        {'EXIT', {noproc, _Err}} ->
            {error, noproc};
        {'EXIT', _Err} ->
            {error, _Err};
        Res ->
            Res
    end.

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link(Port, Conv, UdpOpts, KcpOpts) ->
    gen_server:start_link(?MODULE, [Port, Conv, UdpOpts, KcpOpts], []).

init([Port, Conv, UdpOpts, KcpOpts]) ->
    process_flag(trap_exit, true),
    case gen_udp:open(Port, get_udp_opts(UdpOpts)) of
        {ok, Socket} ->
            Kcp = prim_kcp:create(Conv, Socket, {?MODULE, output, [false]}),
            case prim_kcp:setopts(Kcp, KcpOpts) of
                {ok, NewKcp} ->
                    State = #gen_kcp{socket = Socket, kcp = NewKcp, is_connected = false, next_ref = 1},
                    self() ! kcp_update,
                    put(print_log_time, 0),
                    {ok, State};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 关闭socket
handle_call(close, _From, State = #gen_kcp{socket = Socket}) ->
    gen_udp:close(Socket),
    {stop, normal, ok, State};

%% 连接，与对端ip、端口绑定
handle_call({connect, Ip, Port}, _From, State = #gen_kcp{socket = Socket, kcp = Kcp}) ->
    case gen_udp:connect(Socket, Ip, Port) of
        ok ->
            {ok, NewKcp} = prim_kcp:setopt(Kcp, {output, {?MODULE, output, [true]}}),
            NewState = State#gen_kcp{kcp = NewKcp, is_connected = true},
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% 异步发送数据
handle_call({async_send, _Packet}, _From, State = #gen_kcp{is_connected = false}) ->
    {reply, {error, disconnect}, State};
handle_call({async_send, Packet}, _From, State) when not is_binary(Packet) ->
    {reply, {error, bad_packet}, State};
handle_call({async_send, Packet}, From = {Pid, _}, State = #gen_kcp{kcp = Kcp, next_ref = Ref}) ->
    gen_server:reply(From, {ok, Ref}),
    case prim_kcp:send(Kcp, Packet) of %% TODO 发送数据限制
        {ok, NewKcp0} ->
            Pid ! {kcp_reply, self(), Ref, ok},
            NewKcp = prim_kcp:flush(NewKcp0),
            NewState = State#gen_kcp{kcp = NewKcp, next_ref = Ref + 1},
            {noreply, NewState};
        {error, Reason} ->
            Pid ! {kcp_reply, self(), Ref, {error, Reason}},
            NewState = State#gen_kcp{next_ref = Ref + 1},
            {noreply, NewState}
    end;

%% 异步接收数据
handle_call({async_recv, _Timeout}, _From, State = #gen_kcp{is_connected = false}) ->
    {reply, {error, disconnect}, State};
handle_call({async_recv, _Timeout}, _From, State = #gen_kcp{recv_ref = RecvRef}) when RecvRef =/= undefined ->
    {reply, {error, ealready}, State};
handle_call({async_recv, Timeout}, From = {Pid, _}, State = #gen_kcp{kcp = Kcp, next_ref = Ref}) ->
    gen_server:reply(From, {ok, Ref}),
    case prim_kcp:recv(Kcp) of
        {ok, NewKcp, Packet} ->
            Pid ! {kcp, self(), Ref, {ok, Packet}},
            NewState = State#gen_kcp{kcp = NewKcp, next_ref = Ref + 1},
            {noreply, NewState};
        _ ->
            Mref = erlang:monitor(process, Pid),
            TimerRef = start_timer(Timeout, recv_timeout),
            RecvRef = #gen_kcp_ref{pid = Pid, ref = Ref, mref = Mref, timer_ref = TimerRef},
            NewState = State#gen_kcp{next_ref = Ref + 1, recv_ref = RecvRef},
            {noreply, NewState}
    end;

%% 获取kcp参数
handle_call({getopts, Opts}, _From, State = #gen_kcp{kcp = Kcp}) ->
    Ret = prim_kcp:getopts(Kcp, Opts),
    {reply, Ret, State};

%% 设置kcp参数
handle_call({setopts, Opts}, _From, State = #gen_kcp{kcp = Kcp}) ->
    case prim_kcp:setopts(Kcp, Opts) of
        {ok, NewKcp} ->
            NewState = State#gen_kcp{kcp = NewKcp},
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% 获取socket
handle_call(get_socket, _From, State = #gen_kcp{socket = Socket}) ->
    {reply, {ok, Socket}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% kcp更新
handle_info(kcp_update, State = #gen_kcp{kcp = Kcp}) ->
    NewKcp = prim_kcp:update(Kcp, timestamp()),
    CheckTime = prim_kcp:check(NewKcp, timestamp()),
    erlang:send_after(CheckTime, self(), kcp_update),
    {noreply, State#gen_kcp{kcp = NewKcp}};

%% 接收udp协议报
handle_info({udp, Socket, _Host, _Port, Packet}, State = #gen_kcp{socket = Socket, kcp = Kcp}) ->
    case prim_kcp:input(Kcp, Packet) of
        {ok, NewKcp} ->
            NewState0 = State#gen_kcp{kcp = NewKcp},
            NewState = recv_reply(NewState0),
            {noreply, NewState};
        {error, _Reason} ->
            {noreply, State}
    end;

%% 接收数据超时
handle_info({timeout, TimerRef, recv_timeout}, State = #gen_kcp{recv_ref = #gen_kcp_ref{pid = Pid, ref = Ref, mref = Mref, timer_ref = TimerRef}}) ->
    Pid ! {kcp, self(), Ref, {error, timeout}},
    erlang:demonitor(Mref, [flush]),
    NewState = State#gen_kcp{recv_ref = undefined},
    {noreply, NewState};

%% 监控的进程挂了
handle_info({'DOWN', Mref, _, _, _Reason}, State = #gen_kcp{recv_ref = #gen_kcp_ref{mref = Mref, timer_ref = TimerRef}}) ->
    cancel_timer(TimerRef),
    NewState = State#gen_kcp{recv_ref = undefined},
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State = #gen_kcp{socket = Socket}) ->
    gen_udp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% kcp output 回调方法
output(Socket, Data, true) ->
    gen_udp:send(Socket, Data);
output(_Socket, _Data, _IsConnected) ->
    {error, disconnect}.

%% 获取处理后的udp参数
get_udp_opts(Opts) ->
    get_udp_opts(Opts, [{active, true}, binary]).
get_udp_opts([], AccOpts) ->
    AccOpts;
get_udp_opts([{active, _} | Opts], AccOpts) ->
    get_udp_opts(Opts, AccOpts);
get_udp_opts([{mode, _} | Opts], AccOpts) ->
    get_udp_opts(Opts, AccOpts);
get_udp_opts([binary | Opts], AccOpts) ->
    get_udp_opts(Opts, AccOpts);
get_udp_opts([list | Opts], AccOpts) ->
    get_udp_opts(Opts, AccOpts);
get_udp_opts([Opt | Opts], AccOpts) ->
    get_udp_opts(Opts, [Opt | AccOpts]).

%% 接收数据回复
recv_reply(State = #gen_kcp{kcp = Kcp, recv_ref = #gen_kcp_ref{pid = Pid, ref = Ref, mref = Mref, timer_ref = TimerRef}}) ->
    case prim_kcp:recv(Kcp) of
        {ok, NewKcp, Packet} ->
            Pid ! {kcp, self(), Ref, {ok, Packet}},
            erlang:demonitor(Mref, [flush]),
            cancel_timer(TimerRef),
            State#gen_kcp{kcp = NewKcp, recv_ref = undefined};
        _ ->
            State
    end;
recv_reply(State) ->
    State.

timestamp() ->
    {S1, S2, S3} = os:timestamp(),
    trunc(S1 * 1000000000 + S2 * 1000 + S3 / 1000).

start_timer(infinity, Msg) ->
    erlang:start_timer(16#ffffffff, self(), Msg);
start_timer(Time, Msg) ->
    erlang:start_timer(Time, self(), Msg).

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _Msg} ->
                0
            after 0 ->
                false
            end;
        Time ->
            Time
    end.