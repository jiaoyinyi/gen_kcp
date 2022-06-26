%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. 6月 2022 下午7:37
%%%-------------------------------------------------------------------
-module(t_latency).
-author("huangzaoyi").

%% API
-export([
    test_kcp/1
    , test_tcp/1
]).

test_kcp(Num) ->
    io:format("小数据：~n"),
    Data = list_to_binary(string:chars($a, 10)),
%%    test_kcp([], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], Data, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], Data, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}], Data, Num),
    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 8}], Data, Num),
    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], Data, Num),
    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], Data, Num),
    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 2}], Data, Num),

    io:format("中数据：~n"),
    MidData = list_to_binary(string:chars($a, 512)),
%%    test_kcp([], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], MidData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], MidData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}], MidData, Num),
    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 8}], MidData, Num),
    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], MidData, Num),
    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], MidData, Num),
    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 2}], MidData, Num),

    io:format("大数据：~n"),
    BigData = list_to_binary(string:chars($a, 1700)),
%%    test_kcp([], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], BigData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], BigData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}], BigData, Num),
    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 8}], BigData, Num),
    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], BigData, Num),
    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], BigData, Num),
    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 2}], BigData, Num).

test_kcp(KcpOpts, Data, Num) ->
    {ok, SPid} = t_kcp_server:start(KcpOpts),
    {ok, CPid} = t_kcp_client:start(KcpOpts, Data, Num),
    receive
        finish ->
            gen_server:stop(SPid),
            gen_server:stop(CPid)
    end.

test_tcp(Num) ->
    io:format("小数据：~n"),
    Data = list_to_binary(string:chars($a, 10)),
    test_tcp([], Data, Num),
    test_tcp([{nodelay, true}, {nodelay, true}], Data, Num),
    test_tcp([{nodelay, false}, {delay_send, true}], Data, Num),
    test_tcp([{nodelay, false}, {delay_send, false}], Data, Num),

    io:format("中数据：~n"),
    MidData = list_to_binary(string:chars($a, 512)),
    test_tcp([], MidData, Num),
    test_tcp([{nodelay, true}, {nodelay, true}], MidData, Num),
    test_tcp([{nodelay, false}, {delay_send, true}], MidData, Num),
    test_tcp([{nodelay, false}, {delay_send, false}], MidData, Num),

    io:format("大数据：~n"),
    BigData = list_to_binary(string:chars($a, 1700)),
    test_tcp([], BigData, Num),
    test_tcp([{nodelay, true}, {nodelay, true}], BigData, Num),
    test_tcp([{nodelay, false}, {delay_send, true}], BigData, Num),
    test_tcp([{nodelay, false}, {delay_send, false}], BigData, Num).

test_tcp(TcpOpts, Data, Num) ->
    {ok, SPid} = t_tcp_server:start(TcpOpts),
    {ok, CPid} = t_tcp_client:start(TcpOpts, Data, Num),
    receive
        finish ->
            gen_server:stop(SPid),
            gen_server:stop(CPid)
    end.

