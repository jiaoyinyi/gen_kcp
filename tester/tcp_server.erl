%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(tcp_server).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {lsocket}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    {ok, LSocket} = gen_tcp:listen(40001, [{ip, {127,0,0,1}}, {active, false}, binary, {packet, 0}]),
    self() ! accept,
    {ok, #state{lsocket = LSocket}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(accept, State = #state{lsocket = LSocket}) ->
    case gen_tcp:accept(LSocket) of
        {ok, Socket} ->
            {ok, Pid} = tcp_proc:start(Socket),
            ok = gen_tcp:controlling_process(Socket, Pid),
            self() ! accept,
            {noreply, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;

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
