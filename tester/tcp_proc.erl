%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(tcp_proc).

-behaviour(gen_server).

-export([
    async_recv/3
    , async_send/2
]).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {socket}).

async_recv(Pid, Len, Timeout) ->
    gen_server:call(Pid, {async_recv, Len, Timeout}).

async_send(Pid, Packet) ->
    gen_server:call(Pid, {async_send, Packet}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Socket) ->
    gen_server:start(?MODULE, [Socket], []).

init([Socket]) ->
    process_flag(trap_exit, true),
    inet:setopts(Socket, [{active, false}, binary, {packet, 0}]),
    {ok, #state{socket = Socket}}.

handle_call({async_recv, Len, Timeout}, _From, State = #state{socket = Socket}) ->
    Ret = prim_inet:async_recv(Socket, Len, Timeout),
    {reply, Ret, State};

handle_call({async_send, Packet}, _From, State = #state{socket = Socket}) ->
    Ret =
        try
            erlang:port_command(Socket, Packet, [])
        of
            false -> % Port busy and nosuspend option passed
                {error, busy};
            true ->
                ok
        catch
            error:_Error ->
                {error, einval}
        end,
    {reply, Ret, State};

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

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
