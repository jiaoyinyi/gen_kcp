%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_tcp_proc).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Socket) ->
    gen_server:start_link(?MODULE, [Socket], []).

init([Socket]) ->
    process_flag(trap_exit, true),
    {ok, #state{socket = Socket}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(init, State) ->
    self() ! recv,
    {noreply, State};

handle_info(recv, State = #state{socket = Socket}) ->
    {ok, _Ref} = prim_inet:async_recv(Socket, 4, -1),
    {noreply, State};

handle_info({inet_async, _S, _Ref, {ok, <<Len:32>>}}, State = #state{socket = Socket}) ->
    {ok, _} = prim_inet:async_recv(Socket, Len, -1),
    {noreply, State};

handle_info({inet_async, _S, _Ref, {ok, Data}}, State = #state{socket = Socket}) ->
    Packet = <<(byte_size(Data)):32, Data/binary>>,
    ok = gen_tcp:send(Socket, Packet),
    self() ! recv,
    {noreply, State};

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
