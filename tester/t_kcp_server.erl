%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_kcp_server).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(KcpOpts) ->
    gen_server:start(?MODULE, [KcpOpts], []).

init([KcpOpts]) ->
    {ok, Socket} = gen_kcp:open(30001, 1, [{ip, {192, 168, 31, 235}}], KcpOpts),
    ok = gen_kcp:connect(Socket, {192, 168, 31, 235}, 30002),
    self() ! recv,
    {ok, #state{socket = Socket}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(recv, State = #state{socket = Socket}) ->
    {ok, _Ref} = gen_kcp:async_recv(Socket),
    {noreply, State};

handle_info({kcp, _S, _Ref, {ok, Packet}}, State = #state{socket = Socket}) ->
    ok = gen_kcp:send(Socket, Packet),
    self() ! recv,
    {noreply, State};

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