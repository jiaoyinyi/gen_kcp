%%%-------------------------------------------------------------------
%%% @author Administrator
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(kcp_client).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).
-export([
    send/1
    , recv/0
]).

-define(SERVER, ?MODULE).

-include("gen_kcp.hrl").

send(Bin) ->
    gen_server:call(?SERVER, {send, Bin}).

recv() ->
    gen_server:call(?SERVER, recv).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Conv) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [Conv], []).

init([Conv]) ->
    {ok, Socket} = gen_udp:open(30001, [{ip, {127, 0, 0, 1}}, {active, true}, binary]),
    ok = gen_udp:connect(Socket, {127, 0, 0, 1}, 30000),
    Kcp = prim_kcp:create(Conv, Socket),
    io:format("kcp client 创建！~n"),
    self() ! kcp_update,
    self() ! loop,
    {ok, Kcp}.

%% 发送
handle_call({send, Bin}, _From, Kcp = #kcp{}) ->
    case prim_kcp:send(Kcp, Bin) of
        {ok, NewKcp} ->
            io:format("kcp 发送数据成功！~n"),
            {reply, ok, NewKcp};
        {error, Reason} ->
            io:format("kcp send方法处理错误，原因：~w~n", [Reason]),
            {reply, {error, Reason}, Kcp}
    end;

%% 接收
handle_call(recv, _From, Kcp = #kcp{}) ->
    case prim_kcp:recv(Kcp) of
        {ok, NewKcp, Bin} ->
            io:format("kcp 接收数据成功！~n"),
            {reply, {ok, Bin}, NewKcp};
        {error, Reason} ->
            io:format("kcp recv方法处理错误，原因：~w~n", [Reason]),
            {reply, {error, Reason}, Kcp}
    end;

handle_call(_Request, _From, Kcp = #kcp{}) ->
    {reply, ok, Kcp}.

handle_cast(_Request, Kcp = #kcp{}) ->
    {noreply, Kcp}.

%% kcp更新
handle_info(kcp_update, Kcp = #kcp{}) ->
    NewKcp = prim_kcp:update(Kcp, timestamp()),
    Now = timestamp(),
    LoopTime = prim_kcp:check(NewKcp, Now),
    erlang:send_after(LoopTime, self(), kcp_update),
    {noreply, NewKcp};

%% 接收到udp协议数据
handle_info({udp, _Socket, _Host, _Port, Bin}, Kcp) ->
    case prim_kcp:input(Kcp, Bin) of
        {ok, NewKcp} ->
            {noreply, NewKcp};
        {error, _Reason} ->
            io:format("kcp input方法处理错误，原因：~w~n", [_Reason]),
            {noreply, Kcp}
    end;

%% 循环测试
handle_info(loop, Kcp) ->
    NewKcp =
        case rand:uniform(2) of
            1 -> %% 发送
                Bin =
                    case rand:uniform(3) of
                        1 ->
                            <<"hello">>;
                        2 ->
                            <<"hihihihihihihihihihihihihihihihihihihihihihihi">>;
                        3 ->
                            <<"hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world">>
                    end,
                case prim_kcp:send(Kcp, Bin) of
                    {ok, NewKcp0} ->
                        NewKcp0;
                    {error, Reason} ->
                        io:format("kcp send方法处理错误，原因：~w~n", [Reason]),
                        Kcp
                end;
            2 -> %% 接收
                case prim_kcp:recv(Kcp) of
                    {ok, NewKcp0, _Bin} ->
                        NewKcp0;
                    {error, Reason} ->
                        case Reason =/= kcp_packet_empty of
                            true ->
                                io:format("kcp recv方法处理错误，原因：~w~n", [Reason]);
                            _ ->
                                skip
                        end,
                        Kcp
                end
        end,
    erlang:send_after(rand:uniform(5000), self(), loop),
    {noreply, NewKcp};

handle_info(_Info, Kcp) ->
    io:format("未处理消息：~w~n", [_Info]),
    {noreply, Kcp}.

terminate(_Reason, #kcp{socket = Socket}) ->
    catch gen_udp:close(Socket),
    ok.

code_change(_OldVsn, State = #kcp{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

timestamp() ->
    {S1, S2, S3} = os:timestamp(),
    trunc(S1 * 1000000000 + S2 * 1000 + S3 / 1000).