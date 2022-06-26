%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_tcp_client).

-behaviour(gen_server).

-export([start/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket, data, num, latencies}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(TcpOpts, Data, Num) ->
    gen_server:start(?MODULE, [TcpOpts, Data, Num], []).

init([TcpOpts, Data, Num]) ->
    {ok, Socket} = gen_tcp:connect({192, 168, 31, 235}, 40001, [{active, false}, binary, {packet, 0} | TcpOpts]),
    self() ! send,
    {ok, #state{socket = Socket, data = Data, num = Num, latencies = []}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(send, State = #state{socket = Socket, data = Data, num = Num}) ->
    lists:foreach(
        fun(_) ->
            Packet = <<(byte_size(Data) + 8):32, (timestamp()):64, Data/binary>>,
            ok = gen_tcp:send(Socket, Packet)
        end, lists:seq(1, Num)
    ),
%%    io:format("发送数据~n"),
    self() ! recv,
    {noreply, State};

handle_info(recv, State = #state{socket = Socket, num = Num}) when Num > 0 ->
    {ok, _Ref} = prim_inet:async_recv(Socket, 4, -1),
    {noreply, State};
handle_info(recv, State = #state{socket = Socket, data = Data, latencies = Latencies}) ->
    Total = length(Latencies),
    Size = 8 + byte_size(Data),
    AvgLatency = lists:sum(Latencies) / Total,
    {ok, Opts} = inet:getopts(Socket, [sndbuf, recbuf, buffer, nodelay, delay_send]),
    io:format("发包数量：~w，包大小：~wBytes，Latency：~w，参数：~w~n", [Total, Size, AvgLatency, Opts]),
    gen:get_parent() ! finish,
    {noreply, State};

handle_info({inet_async, _S, _Ref, {ok, <<Len:32>>}}, State = #state{socket = Socket}) ->
    {ok, _} = prim_inet:async_recv(Socket, Len, -1),
    {noreply, State};

handle_info({inet_async, _S, _Ref, {ok, <<SendTime:64, _Packet/binary>>}}, State = #state{num = Num, latencies = Latencies}) ->
    RecvTime = timestamp(),
    Latency = RecvTime - SendTime,
    self() ! recv,
    {noreply, State#state{num = Num - 1, latencies = [Latency | Latencies]}};

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