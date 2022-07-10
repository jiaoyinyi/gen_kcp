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
    test/3
    , test_kcp/3
    , test_tcp/3
]).

test(Total, Num, Time) ->
    spawn(
        fun() ->
            test_kcp(Total, Num, Time),
            test_tcp(Total, Num, Time)
        end
    ).

test_kcp(Total, Num, Time) ->
    io:format("kcp测试：~n"),
%%    io:format("小数据：~n"),
%%    Data = list_to_binary(string:chars($a, 10)),
%%    test_kcp([], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}], Data, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], Data, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], Data, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}], Data, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 8}], Data, Num),
%%    test_kcp(1, [{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 10}], Data, Total, Num, Time),
%%    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], Data, Num),
%%    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 2}], Data, Total, Num, Time),

    io:format("中数据：~n"),
    MidData = list_to_binary(string:chars($a, 100)),
%%    test_kcp([], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}], MidData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], MidData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], MidData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}], MidData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 8}], MidData, Num),
    test_kcp(2, [{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], MidData, Total, Num, Time),
%%    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], MidData, Num),
%%    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 2}], MidData, Total, Num, Time),

%%    io:format("大数据：~n"),
%%    BigData = list_to_binary(string:chars($a, 3000)),
%%    test_kcp([], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}], BigData, Num),
%%    test_kcp([{snd_wnd, 256}, {rcv_wnd, 256}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], BigData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}], BigData, Num),
%%    test_kcp([{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}], BigData, Num),
%%    test_kcp(1, [{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 8}], BigData, Total, Num, Time),
%%    test_kcp(3, [{snd_wnd, 512}, {rcv_wnd, 512}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 10}], BigData, Total, Num, Time),
%%    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}], BigData, Num),
%%    test_kcp([{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 2}], BigData, Total, Num, Time),
    ok.

test_kcp(Conv, KcpOpts, Data, Total, Num, Time) ->
%%    eprof:start(),
    Fun =
        fun() ->
            {ok, SPid} = t_kcp_server:start(Conv, KcpOpts),
            {ok, CPid} = t_kcp_client:start(Conv, KcpOpts, Data, Total, Num, Time),
            io:format("server pid:~w, client pid:~w~n", [SPid, CPid]),
            receive
                finish ->
                    gen_server:stop(SPid),
                    gen_server:stop(CPid)
            end
        end,
    Fun().
%%    eprof:profile(Fun),
%%    eprof:analyze(),
%%    eprof:stop().

test_tcp(Total, Num, Time) ->
    io:format("tcp测试：~n"),
%%    io:format("小数据：~n"),
%%    Data = list_to_binary(string:chars($a, 10)),
%%    test_tcp([], Data, Num),
%%    test_tcp([{nodelay, true}, {nodelay, true}], Data, Num),
%%    test_tcp([{nodelay, false}, {delay_send, true}], Data, Num),
%%    test_tcp([{nodelay, true}, {delay_send, false}], Data, Total, Num, Time),

    io:format("中数据：~n"),
    MidData = list_to_binary(string:chars($a, 100)),
%%    test_tcp([], MidData, Num),
%%    test_tcp([{nodelay, true}, {nodelay, true}], MidData, Num),
%%    test_tcp([{nodelay, false}, {delay_send, true}], MidData, Num),
    test_tcp([{nodelay, true}, {delay_send, false}], MidData, Total, Num, Time),
%%
%%    io:format("大数据：~n"),
%%    BigData = list_to_binary(string:chars($a, 3000)),
%%    test_tcp([], BigData, Num),
%%    test_tcp([{nodelay, true}, {nodelay, true}], BigData, Num),
%%    test_tcp([{nodelay, false}, {delay_send, true}], BigData, Num),
%%    test_tcp([{nodelay, true}, {delay_send, false}], BigData, Total, Num, Time),
    ok.

test_tcp(TcpOpts, Data, Total, Num, Time) ->
%%    eprof:start(),
    Fun =
        fun() ->
            {ok, SPid} = t_tcp_server:start(TcpOpts),
            {ok, CPid} = t_tcp_client:start(TcpOpts, Data, Total, Num, Time),
            io:format("server pid:~w, client pid:~w~n", [SPid, CPid]),
            receive
                finish ->
                    gen_server:stop(SPid),
                    gen_server:stop(CPid)
            end
        end,
    Fun().
%%    eprof:profile(Fun),
%%    eprof:analyze(),
%%    eprof:stop().
