%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_kcp_client).

-behaviour(gen_server).

-export([start/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket, data, num, latencies}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(KcpOpts, Data, Num) ->
    gen_server:start(?MODULE, [KcpOpts, Data, Num], []).

init([KcpOpts, Data, Num]) ->
    {ok, Socket} = gen_kcp:open(30002, 1, [{ip, {192, 168, 31, 235}}], KcpOpts),
    ok = gen_kcp:connect(Socket, {192, 168, 31, 235}, 30001),
    self() ! send,
    {ok, #state{socket = Socket, data = Data, num = Num, latencies = []}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(send, State = #state{socket = Socket, data = Data, num = Num}) ->
    lists:foreach(
        fun(_) ->
            Packet = <<(timestamp()):64, Data/binary>>,
            ok = gen_kcp:send(Socket, Packet)
        end, lists:seq(1, Num)
    ),
%%    io:format("发送数据~n"),
    self() ! recv,
    {noreply, State};

handle_info(recv, State = #state{socket = Socket, num = Num}) when Num > 0 ->
    {ok, _Ref} = gen_kcp:async_recv(Socket),
    {noreply, State};
handle_info(recv, State = #state{socket = Socket, data = Data, latencies = Latencies}) ->
    Total = length(Latencies),
    Size = 8 + byte_size(Data),
    AvgLatency = lists:sum(Latencies) / Total,
    {ok, Opts} = gen_kcp:getopts(Socket, [snd_wnd, rcv_wnd, nodelay, fastresend, nocwnd, minrto, interval]),
    io:format("发包数量：~w，包大小：~wBytes，Latency：~w，参数：~w~n", [Total, Size, AvgLatency, Opts]),
    gen:get_parent() ! finish,
    {noreply, State};

handle_info({kcp, _S, _Ref, {ok, <<SendTime:64, _Packet/binary>>}}, State = #state{num = Num, latencies = Latencies}) ->
%%    io:format("接收数据~n"),
    RecvTime = timestamp(),
    Latency = RecvTime - SendTime,
    self() ! recv,
    {noreply, State#state{num = Num - 1, latencies = [Latency | Latencies]}};

handle_info(_Info, State = #state{}) ->
    io:format("接收到其他消息：~w~n", [_Info]),
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
timestamp() ->
    {S1, S2, S3} = os:timestamp(),
    trunc(S1 * 1000000000 + S2 * 1000 + S3 / 1000).