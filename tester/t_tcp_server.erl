%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(t_tcp_server).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {lsocket}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(TcpOpts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [TcpOpts], []).

init([TcpOpts]) ->
    {ok, LSocket} = gen_tcp:listen(40001, [{ip, {127, 0, 0, 1}}, {active, false}, binary, {packet, 0}, {reuseaddr, true} | TcpOpts]),
    self() ! accept,
    {ok, #state{lsocket = LSocket}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(accept, State = #state{lsocket = LSocket}) ->
    {ok, _Ref} = prim_inet:async_accept(LSocket, -1),
    {noreply, State};

handle_info({inet_async, _L, _Ref, {ok, Socket}}, State = #state{lsocket = LSocket}) ->
    {ok, Mod} = inet_db:lookup_socket(LSocket),
    inet_db:register_socket(Socket, Mod),
    {ok, Pid} = t_tcp_proc:start(Socket),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! init,
    self() ! accept,
    {noreply, State};

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{lsocket = LSocket}) ->
    gen_tcp:close(LSocket),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
