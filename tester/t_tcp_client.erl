%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_tcp_client).

-behaviour(gen_server).

-export([start/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket, data, total, num, time, idx, latencies}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(TcpOpts, Data, Total, Num, Time) ->
    gen_server:start(?MODULE, [TcpOpts, Data, Total, Num, Time], []).

init([TcpOpts, Data, Total, Num, Time]) ->
    {ok, Socket} = gen_tcp:connect({192, 168, 31, 235}, 40001, [{active, false}, binary, {packet, 0} | TcpOpts]),
    self() ! send,
    self() ! recv,
    {ok, #state{socket = Socket, data = Data, total = Total, num = Num, time = Time, idx = 0, latencies = []}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(send, State = #state{socket = Socket, data = Data, total = Total, num = Num, time = Time, idx = Idx}) when Total > 0 ->
    lists:foreach(
        fun(_) ->
            Packet = <<(byte_size(Data) + 8):32, (timestamp()):64, Data/binary>>,
            ok = gen_tcp:send(Socket, Packet)
        end, lists:seq(1, Num)
    ),
    erlang:send_after(Time, self(), send),
    {noreply, State#state{total = Total - Num, idx = Idx + Num}};
handle_info(send, State = #state{}) ->
    {noreply, State};

handle_info(recv, State = #state{socket = Socket, total = Total, idx = Idx}) when Total > 0 orelse Idx > 0 ->
    {ok, _Ref} = prim_inet:async_recv(Socket, 4, -1),
    {noreply, State};
handle_info(recv, State = #state{socket = Socket, data = Data, latencies = Latencies}) ->
    Total = length(Latencies),
    Size = 8 + byte_size(Data),
    AvgLatency = lists:sum(Latencies) / Total,
    MaxLatency = lists:max(Latencies),
    MinLatency = lists:min(Latencies),
    {ok, Opts} = inet:getopts(Socket, [sndbuf, recbuf, buffer, nodelay, delay_send]),
    io:format("发包数量：~w，包大小：~wBytes，Avg Latency：~w，Max Latency：~w，Min Latency：~w，参数：~w~n", [Total, Size, AvgLatency, MaxLatency, MinLatency, Opts]),
    gen:get_parent() ! finish,
    {noreply, State};

handle_info({inet_async, _S, _Ref, {ok, <<Len:32>>}}, State = #state{socket = Socket}) ->
    {ok, _} = prim_inet:async_recv(Socket, Len, -1),
    {noreply, State};

handle_info({inet_async, _S, _Ref, {ok, <<SendTime:64, _Packet/binary>>}}, State = #state{idx = Idx, latencies = Latencies}) ->
    RecvTime = timestamp(),
    Latency = RecvTime - SendTime,
    self() ! recv,
    {noreply, State#state{idx = Idx - 1, latencies = [Latency | Latencies]}};

handle_info(_Info, State = #state{}) ->
    io:format("进程[~w]收到消息：~w~n", [self(), _Info]),
    {noreply, State}.

terminate(_Reason, _State = #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
timestamp() ->
    {S1, S2, S3} = os:timestamp(),
    trunc(S1 * 1000000000 + S2 * 1000 + S3 / 1000).