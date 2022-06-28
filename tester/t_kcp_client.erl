%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_kcp_client).

-behaviour(gen_server).

-export([start/6]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket, data, total, num, time, idx, latencies}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Conv, KcpOpts, Data, Total, Num, Time) ->
    gen_server:start(?MODULE, [Conv, KcpOpts, Data, Total, Num, Time], []).

init([Conv, KcpOpts, Data, Total, Num, Time]) ->
    {ok, Socket} = gen_kcp:open(30002, Conv, [{ip, {127, 0, 0, 1}}], KcpOpts),
    ok = gen_kcp:connect(Socket, {127, 0, 0, 1}, 30001),
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
            Packet = <<(timestamp()):64, Data/binary>>,
            ok = gen_kcp:send(Socket, Packet)
        end, lists:seq(1, Num)
    ),
    erlang:send_after(Time, self(), send),
    {noreply, State#state{total = Total - Num, idx = Idx + Num}};
handle_info(send, State = #state{}) ->
    {noreply, State};

handle_info(recv, State = #state{socket = Socket, total = Total, idx = Idx}) when Total > 0 orelse Idx > 0 ->
    {ok, _Ref} = gen_kcp:async_recv(Socket),
    {noreply, State};
handle_info(recv, State = #state{socket = Socket, data = Data, latencies = Latencies}) ->
    Total = length(Latencies),
    Size = 8 + byte_size(Data),
    AvgLatency = lists:sum(Latencies) / Total,
    MaxLatency = lists:max(Latencies),
    MinLatency = lists:min(Latencies),
    {ok, Opts} = gen_kcp:getopts(Socket, [snd_wnd, rcv_wnd, nodelay, fastresend, nocwnd, minrto, interval]),
    io:format("发包数量：~w，包大小：~wBytes，Avg Latency：~w，Max Latency：~w，Min Latency：~w，参数：~w~n", [Total, Size, AvgLatency, MaxLatency, MinLatency, Opts]),
    gen:get_parent() ! finish,
    {noreply, State};

handle_info({kcp, _S, _Ref, {ok, <<SendTime:64, _Packet/binary>>}}, State = #state{idx = Idx, latencies = Latencies}) ->
    RecvTime = timestamp(),
    Latency = RecvTime - SendTime,
    self() ! recv,
    {noreply, State#state{idx = Idx - 1, latencies = [Latency | Latencies]}};

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