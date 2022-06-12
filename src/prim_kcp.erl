%%%-------------------------------------------------------------------
%%% @author jiaoyinyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc primitive kcp interface
%%%
%%% @end
%%% Created : 10. 5月 2022 12:22 上午
%%%-------------------------------------------------------------------
-module(prim_kcp).
-author("jiaoyinyi").

%% API
-export([
    create/2
    , send/2
    , recv/1
    , update/2
    , check/2
    , getopts/2
    , setopts/2
    , output/2
    , input/2
]).

-include("kcp.hrl").

%% @doc 创建kcp
-spec create(pos_integer(), inet:socket()) -> #kcp{}.
create(Conv, Socket) ->
    #kcp{
        conv = Conv
        , snd_una = 0
        , snd_nxt = 0
        , rcv_nxt = 0
        , ts_recent = 0
        , ts_lastack = 0
        , ts_probe = 0
        , probe_wait = 0
        , snd_wnd = ?KCP_WND_SND
        , rcv_wnd = ?KCP_WND_RCV
        , rmt_wnd = ?KCP_WND_RCV
        , cwnd = 0
        , incr = 0
        , probe = 0
        , mtu = ?KCP_MTU_DEF
        , mss = ?KCP_MTU_DEF - ?KCP_OVERHEAD

        , snd_queue = queue:new()
        , rcv_queue = queue:new()
        , snd_buf = queue:new()
        , rcv_buf = queue:new()
        , nrcv_que = 0
        , nsnd_que = 0
        , nrcv_buf = 0
        , nsnd_buf = 0
        , state = 0
        , acklist = queue:new()
        , rx_srtt = 0
        , rx_rttval = 0
        , rx_rto = ?KCP_RTO_DEF
        , rx_minrto = ?KCP_RTO_MIN
        , current = 0
        , interval = ?KCP_INTERVAL
        , ts_flush = ?KCP_INTERVAL
        , nodelay = 0
        , updated = 0
        , ssthresh = ?KCP_THRESH_INIT
        , fastresend = 0
        , fastlimit = ?KCP_FASTACK_LIMIT
        , nocwnd = 0
        , xmit = 0
        , dead_link = ?KCP_DEADLINK
        , socket = Socket
    }.

%% @doc kcp发送数据
-spec send(#kcp{}, binary()) -> {ok, #kcp{}} | {error, term()}.
send(Kcp = #kcp{mss = Mss}, Data) when is_binary(Data) ->
    %% 计算分片数量
    Size = byte_size(Data),
    Count = ?_IF_TRUE(Size =< Mss, 1, erlang:ceil(Size / Mss)),
    case Count >= ?KCP_WND_RCV of
        true ->
            {error, data_oversize}; %% 数据包太大了
        _ ->
            NewKcp = send_add_seg(Kcp, 1, Count, Data),
            {ok, NewKcp}
    end.

%% 发送数据时添加分片
send_add_seg(Kcp = #kcp{conv = Conv, mss = Mss, snd_queue = SndQueue, nsnd_que = NSndQue}, Idx, Count, Bin) when Idx < Count ->
    <<Data:Mss/binary, RestBin/binary>> = Bin,
    KcpSeg = #kcpseg{conv = Conv, frg = Count - Idx, len = Mss, data = Data},
    NewKcp = Kcp#kcp{snd_queue = queue:in(KcpSeg, SndQueue), nsnd_que = NSndQue + 1},
    send_add_seg(NewKcp, Idx + 1, Count, RestBin);
send_add_seg(Kcp = #kcp{conv = Conv, snd_queue = SndQueue, nsnd_que = NSndQue}, Idx, Count, Data) when Idx =:= Count ->
    KcpSeg = #kcpseg{conv = Conv, frg = Count - Idx, len = byte_size(Data), data = Data},
    NewKcp = Kcp#kcp{snd_queue = queue:in(KcpSeg, SndQueue), nsnd_que = NSndQue + 1},
    NewKcp.

%% @doc kcp接收数据
-spec recv(#kcp{}) -> {ok, #kcp{}, binary()} | {error, term()}.
recv(Kcp = #kcp{nrcv_que = NRcvQue, rcv_wnd = RcvWnd}) ->
    PeekSize = peeksize(Kcp),
    case PeekSize < 0 of
        true ->
            {error, kcp_packet_empty}; %% kcp协议报为空
        _ ->
            Recover = ?_IF_TRUE(NRcvQue >= RcvWnd, 1, 0),
            {NewKcp0, Bin} = merge_fragment(Kcp, <<>>),
            case byte_size(Bin) =/= PeekSize of
                true ->
                    {error, kcp_fragment_err}; %% kcp协议段整合错误
                _ ->
                    NewKcp1 = #kcp{nrcv_que = NewNRcvQue, rcv_wnd = NewRcvWnd, probe = Probe} = move_to_rcv_queue(NewKcp0),
                    NewProbe = ?_IF_TRUE(NewNRcvQue < NewRcvWnd andalso Recover =:= 1, Probe bor ?KCP_ASK_TELL, Probe),
                    NewKcp = NewKcp1#kcp{probe = NewProbe},
                    {ok, NewKcp, Bin}
            end
    end.

%% 计算完整数据包数据大小
peeksize(#kcp{rcv_queue = RcvQueue, nrcv_que = NRcvQue}) ->
    case queue:out(RcvQueue) of
        {empty, _} ->
            -1;
        {{value, #kcpseg{frg = 0, len = Len}}, _} ->
            Len;
        {{value, #kcpseg{frg = Frg}}, _} ->
            case NRcvQue < Frg + 1 of
                true ->
                    -1;
                _ ->
                    do_peeksize(RcvQueue, 0)
            end
    end.

do_peeksize(RcvQueue, Size) ->
    case queue:out(RcvQueue) of
        {{value, #kcpseg{frg = 0, len = Len}}, _} ->
            Size + Len;
        {{value, #kcpseg{len = Len}}, NewRcvQueue} ->
            do_peeksize(NewRcvQueue, Size + Len);
        {empty, _} -> %% 正常不会走到这里
            -1
    end.

%% 整合分段
merge_fragment(Kcp = #kcp{rcv_queue = RcvQueue, nrcv_que = NRcvQue}, Buffer) ->
    case queue:out(RcvQueue) of
        {{value, #kcpseg{frg = 0, data = Data}}, NewRcvQueue} ->
            NewKcp = Kcp#kcp{rcv_queue = NewRcvQueue, nrcv_que = NRcvQue - 1},
            NewBuffer = <<Buffer/binary, Data/binary>>,
            {NewKcp, NewBuffer};
        {{value, #kcpseg{data = Data}}, NewRcvQueue} ->
            NewKcp = Kcp#kcp{rcv_queue = NewRcvQueue, nrcv_que = NRcvQue - 1},
            NewBuffer = <<Buffer/binary, Data/binary>>,
            merge_fragment(NewKcp, NewBuffer);
        {empty, _} ->
            {Kcp, Buffer}
    end.

%% @doc 获取参数
-spec getopts(#kcp{}, list()) -> {ok, [{atom(), term()}]} | {error, term()}.
getopts(Kcp, Opts) ->
    do_getopts(Kcp, Opts, []).

do_getopts(_Kcp, [], Rets) ->
    {ok, Rets};
do_getopts(Kcp, [Opt | Opts], Rets) ->
    case do_getopts(Kcp, Opt) of
        {ok, Val} ->
            do_getopts(Kcp, Opts, [{Opt, Val} | Rets]);
        {error, Reason} ->
            {error, Reason}
    end.
do_getopts(#kcp{nsnd_buf = NSndBuf, nsnd_que = NsndQue}, waitsnd) -> %% 待发送数据长度
    WaitSnd = NSndBuf + NsndQue,
    {ok, WaitSnd};
do_getopts(#kcp{nodelay = NoDelay}, nodelay) -> %% 是否启用 nodelay模式
    {ok, NoDelay};
do_getopts(#kcp{interval = Interval}, interval) -> %% 协议内部工作的 interval
    {ok, Interval};
do_getopts(#kcp{fastresend = FastResend}, fastresend) -> %% 快速重传模式
    {ok, FastResend};
do_getopts(#kcp{nocwnd = NoCWnd}, nocwnd) -> %% 是否关闭流控
    {ok, NoCWnd};
do_getopts(#kcp{snd_wnd = SndWnd}, snd_wnd) -> %% 最大发送窗口
    {ok, SndWnd};
do_getopts(#kcp{rcv_wnd = RcvWnd}, rcv_wnd) -> %% 最大接收窗口
    {ok, RcvWnd};
do_getopts(#kcp{mtu = Mtu}, mtu) -> %% MTU
    {ok, Mtu};
do_getopts(#kcp{rx_minrto = RxMinRto}, minrto) -> %% 最小rto
    {ok, RxMinRto};
do_getopts(_Kcp, Opt) ->
    {error, {unknown_opt, Opt}}.

%% @doc 设置参数
-spec setopts(#kcp{}, [{atom(), term()}]) -> ok | {error, term()}.
setopts(Kcp, []) ->
    {ok, Kcp};
setopts(Kcp, [Opt | Opts]) ->
    case setopts(Kcp, Opt) of
        {ok, NewKcp} ->
            setopts(NewKcp, Opts);
        {error, Reason} ->
            {error, Reason}
    end;
setopts(Kcp, {nodelay, NoDelay}) when is_integer(NoDelay) andalso NoDelay >= 0 -> %% 是否启用 nodelay模式，0不启用；1启用。
    RxMinRto = ?_IF_TRUE(NoDelay > 0, ?KCP_RTO_NDL, ?KCP_RTO_MIN),
    NewKcp = Kcp#kcp{nodelay = NoDelay, rx_minrto = RxMinRto},
    {ok, NewKcp};
setopts(Kcp, {interval, Interval}) when is_integer(Interval) andalso Interval >= 0 -> %% 协议内部工作的 interval，单位毫秒。
    NewInterval = min(max(5, Interval), 5000),
    NewKcp = Kcp#kcp{interval = NewInterval},
    {ok, NewKcp};
setopts(Kcp, {fastresend, FastResend}) when is_integer(FastResend) andalso FastResend >= 0 -> %% 快速重传模式，默认0关闭，可以设置2（2次ACK跨越将会直接重传）。
    NewKcp = Kcp#kcp{fastresend = FastResend},
    {ok, NewKcp};
setopts(Kcp, {nocwnd, NoCWnd}) when is_integer(NoCWnd) andalso NoCWnd >= 0 -> %% 是否关闭流控，默认是0代表不关闭，1代表关闭。
    NewKcp = Kcp#kcp{nocwnd = NoCWnd},
    {ok, NewKcp};
setopts(Kcp, {snd_wnd, SndWnd}) when is_integer(SndWnd) andalso SndWnd > 0 -> %% 最大发送窗口，默认为32，单位是包。
    NewKcp = Kcp#kcp{snd_wnd = SndWnd},
    {ok, NewKcp};
setopts(Kcp, {rcv_wnd, RcvWnd}) when is_integer(RcvWnd) andalso RcvWnd > 0 -> %% 最大接收窗口，默认为32，单位是包。
    NewKcp = Kcp#kcp{rcv_wnd = max(RcvWnd, ?KCP_WND_RCV)},
    {ok, NewKcp};
setopts(Kcp, {mtu, Mtu}) when is_integer(Mtu) andalso Mtu > 0 -> %% 默认 mtu是1400字节，该值将会影响数据包归并及分片时候的最大传输单元。
    NewMtu = max(50, min(Mtu, ?KCP_MTU_DEF)),
    NewKcp = Kcp#kcp{mtu = NewMtu, mss = NewMtu - ?KCP_OVERHEAD},
    {ok, NewKcp};
setopts(Kcp, {minrto, MinRto}) when is_integer(MinRto) andalso MinRto > 0 -> %% 最小 RTO的限制
    NewMinRto = max(10, min(MinRto, ?KCP_RTO_MAX)),
    NewKcp = Kcp#kcp{rx_minrto = NewMinRto},
    {ok, NewKcp};
setopts(_Kcp, Opt) ->
    {error, {unknown_opt, Opt}}.


%% @doc 底层协议发送数据
-spec output(#kcp{}, binary()) -> ok | {error, term()}.
output(_Kcp, <<>>) ->
    ok;
output(#kcp{socket = Socket}, Data) ->
    gen_udp:send(Socket, Data).

%% @doc 底层协议接收数据
-spec input(#kcp{}, binary()) -> {ok, #kcp{}} | {error, term()}.
input(_Kcp, <<>>) ->
    {error, kcp_data_empty}; %% 下层协议输入的数据是空的
input(_Kcp, Bin) when byte_size(Bin) < ?KCP_OVERHEAD ->
    {error, kcp_data_err}; %% 下层协议输入的数据小于kcp协议报头大小
input(Kcp = #kcp{snd_una = PrevUna}, Bin) ->
    input_unpack(Kcp, Bin, PrevUna, 0, 0, 0).

input_unpack(Kcp, Bin, PrevUna, AckFlag, MaxAck, LastestTs) when byte_size(Bin) < ?KCP_OVERHEAD ->
    NewKcp0 = ?_IF_TRUE(AckFlag =:= 1, parse_fastack(Kcp, MaxAck, LastestTs), Kcp),
    NewKcp = update_cwnd(NewKcp0, PrevUna),
    {ok, NewKcp};
input_unpack(Kcp = #kcp{conv = Conv, probe = Probe, rcv_nxt = RcvNxt, rcv_wnd = RcvWnd}, Bin, PrevUna, AckFlag, MaxAck, LastestTs) ->
    case bin_to_seg(Bin) of
        {ok, KcpSeg = #kcpseg{conv = Conv, cmd = Cmd, wnd = Wnd, sn = Sn, ts = Ts, una = Una}, RestBin} ->
            case Cmd =/= ?KCP_CMD_ACK andalso Cmd =/= ?KCP_CMD_PUSH andalso Cmd =/= ?KCP_CMD_WASK andalso Cmd =/= ?KCP_CMD_WINS of
                true ->
                    {error, {kcp_cmd_err, Cmd}};
                _ ->
                    NewKcp0 = Kcp#kcp{rmt_wnd = Wnd},
                    NewKcp1 = parse_una(NewKcp0, Una),
                    NewKcp2 = shrink_buf(NewKcp1),
                    {NewKcp, NewAckFlag, NewMaxAck, NewLastestTs} =
                        case Cmd of
                            ?KCP_CMD_ACK ->
                                {NewKcp3, NewAckFlag0, NewMaxAck0, NewLastestTs0} = input_ack(NewKcp2, KcpSeg, AckFlag, MaxAck, LastestTs),
                                {NewKcp3, NewAckFlag0, NewMaxAck0, NewLastestTs0};
                            ?KCP_CMD_PUSH ->
                                NewKcp5 =
                                    case time_diff(Sn, RcvNxt + RcvWnd) < 0 of
                                        true ->
                                            NewKcp3 = ack_push(NewKcp2, Sn, Ts),
                                            NewKcp4 = parse_data(NewKcp3, KcpSeg),
                                            NewKcp4;
                                        _ ->
                                            NewKcp2
                                    end,
                                {NewKcp5, AckFlag, MaxAck, LastestTs};
                            ?KCP_CMD_WASK ->
                                NewKcp3 = NewKcp2#kcp{probe = Probe bor ?KCP_ASK_TELL},
                                {NewKcp3, AckFlag, MaxAck, LastestTs};
                            ?KCP_CMD_WINS ->
                                {NewKcp2, AckFlag, MaxAck, LastestTs}
                        end,
                    input_unpack(NewKcp, RestBin, PrevUna, NewAckFlag, NewMaxAck, NewLastestTs)
            end;
        {ok, #kcpseg{conv = SegConv}, _} ->
            {error, {kcp_conv_err, SegConv}}; %% 报文段的conv和kcp的conv不一致
        {error, Reason} ->
            {error, Reason}
    end.

%% 去掉snd_buf中小于Una的协议报
parse_una(Kcp = #kcp{snd_buf = SndBuf, nsnd_buf = NSndBuf}, Una) ->
    case queue:out(SndBuf) of
        {{value, #kcpseg{sn = Sn}}, NewSndBuf} ->
            case time_diff(Una, Sn) > 0 of
                true ->
                    parse_una(Kcp#kcp{snd_buf = NewSndBuf, nsnd_buf = NSndBuf - 1}, Una);
                _ ->
                    Kcp
            end;
        _ ->
            Kcp
    end.

%% 更新snd_una
shrink_buf(Kcp = #kcp{snd_buf = SndBuf, snd_nxt = SndNxt}) ->
    case queue:out(SndBuf) of
        {{value, #kcpseg{sn = Sn}}, _} -> %% 把第一个未ack的协议报编号作为snd_una
            Kcp#kcp{snd_una = Sn};
        {empty, _} ->
            Kcp#kcp{snd_una = SndNxt}
    end.

%% 去掉snd_buf中命中的协议报
parse_ack(Kcp = #kcp{snd_una = SndUna, snd_nxt = SndNxt, snd_buf = SndBuf}, Sn) ->
    case time_diff(Sn, SndUna) < 0 orelse time_diff(Sn, SndNxt) >= 0 of
        true ->
            Kcp;
        _ ->
            do_parse_ack(Kcp, SndBuf, Sn, [])
    end.

do_parse_ack(Kcp = #kcp{nsnd_buf = NSndBuf}, SndBuf, Sn, RestSegs) ->
    case queue:out(SndBuf) of
        {{value, #kcpseg{sn = Sn}}, {NewSndBufIn, NewSndBufOut}} ->
            NewSndBuf = {NewSndBufIn, lists:reverse(RestSegs, NewSndBufOut)},
            Kcp#kcp{snd_buf = NewSndBuf, nsnd_buf = NSndBuf - 1};
        {{value, KcpSeg = #kcpseg{sn = SegSn}}, NewSndBuf} ->
            case time_diff(Sn, SegSn) < 0 of
                true ->
                    Kcp;
                _ ->
                    do_parse_ack(Kcp, NewSndBuf, Sn, [KcpSeg | RestSegs])
            end;
        {empty, _} ->
            Kcp
    end.

input_ack(Kcp = #kcp{current = Current}, #kcpseg{ts = Ts, sn = Sn}, AckFlag, MaxAck, LastestTs) ->
    NewKcp0 = ?_IF_TRUE(time_diff(Current, Ts) >= 0, update_ack(Kcp, time_diff(Current, Ts)), Kcp),
    NewKcp1 = parse_ack(NewKcp0, Sn),
    NewKcp = shrink_buf(NewKcp1),
    {NewAckFlag, NewMaxAck, NewLastestTs} =
        case AckFlag =:= 0 of
            true ->
                {1, Sn, Ts};
            _ ->
                case time_diff(Sn, MaxAck) > 0 andalso time_diff(Ts, LastestTs) > 0 of
                    true ->
                        {AckFlag, Sn, Ts};
                    _ ->
                        {AckFlag, MaxAck, LastestTs}
                end
        end,
    {NewKcp, NewAckFlag, NewMaxAck, NewLastestTs}.

%% 更新ack相关信息
update_ack(Kcp = #kcp{rx_srtt = RxSrtt, rx_rttval = RxRttval, rx_minrto = RxMinrto, interval = Interval}, Rtt) -> %% rto计算
    {NewRxSrtt, NewRxRttval} =
        case RxSrtt =:= 0 of
            true ->
                NewRxSrtt0 = Rtt,
                NewRxRttval0 = Rtt div 2,
                {NewRxSrtt0, NewRxRttval0};
            _ ->
                Delta = abs(Rtt - RxSrtt),
                NewRxRttval0 = (3 * RxRttval + Delta) div 4,
                NewRxSrtt0 = max(1, (7 * RxSrtt + Rtt) div 8),
                {NewRxSrtt0, NewRxRttval0}
        end,
    Rto = NewRxSrtt + max(Interval, 4 * NewRxRttval),
    NewRxRto = min(max(RxMinrto, Rto), ?KCP_RTO_MAX),
    Kcp#kcp{rx_srtt = NewRxSrtt, rx_rttval = NewRxRttval, rx_rto = NewRxRto}.

%% 更新ack列表
ack_push(Kcp = #kcp{acklist = AckList}, Sn, Ts) ->
    Kcp#kcp{acklist = queue:in({Sn, Ts}, AckList)}.

%% 数据协议报处理
parse_data(Kcp = #kcp{rcv_nxt = RcvNxt, rcv_wnd = RcvWnd, rcv_buf = RcvBuf, nrcv_buf = NRcvBuf}, NewKcpSeg = #kcpseg{sn = Sn}) ->
    case time_diff(Sn, RcvNxt + RcvWnd) >= 0 orelse time_diff(Sn, RcvNxt) < 0 of
        true ->
            Kcp;
        _ ->
            NewKcp0 = do_parse_data(Kcp, NewKcpSeg, RcvBuf, NRcvBuf, []),
            NewKcp = move_to_rcv_queue(NewKcp0),
            NewKcp
    end.

do_parse_data(Kcp, NewKcpSeg = #kcpseg{sn = NewSn}, RcvBuf = {RcvBufIn, RcvBufOut}, NRcvBuf, RestSegs) ->
    case queue:out_r(RcvBuf) of %% 从后往前出队列
        {{value, #kcpseg{sn = NewSn}}, _} -> %% 协议报重复
            Kcp;
        {{value, KcpSeg = #kcpseg{sn = Sn}}, NewRcvBuf} ->
            case time_diff(NewSn, Sn) > 0 of
                true ->
                    NewRcvBuf = {lists:reverse([NewKcpSeg | RestSegs], RcvBufIn), RcvBufOut},
                    Kcp#kcp{rcv_buf = NewRcvBuf, nrcv_buf = NRcvBuf + 1};
                _ ->
                    do_parse_data(Kcp, NewKcpSeg, NewRcvBuf, NRcvBuf, [KcpSeg | RestSegs])
            end;
        {empty, _} ->
            NewRcvBuf = {lists:reverse([NewKcpSeg | RestSegs], RcvBufIn), RcvBufOut},
            Kcp#kcp{rcv_buf = NewRcvBuf, nrcv_buf = NRcvBuf + 1}
    end.

%% 将有效的数据移到到rcv_queue
move_to_rcv_queue(Kcp = #kcp{rcv_buf = RcvBuf, nrcv_buf = NRcvBuf, rcv_queue = RcvQueue, nrcv_que = NRcvQue, rcv_nxt = RcvNxt, rcv_wnd = RcvWnd}) ->
    case queue:out(RcvBuf) of
        {{value, KcpSeg = #kcpseg{sn = Sn}}, NewRcvBuf} when Sn =:= RcvNxt andalso NRcvQue < RcvWnd ->
            NewKcp = Kcp#kcp{rcv_buf = NewRcvBuf, nrcv_buf = NRcvBuf - 1, rcv_queue = queue:in(KcpSeg, RcvQueue), nrcv_que = NRcvQue + 1, rcv_nxt = RcvNxt + 1},
            move_to_rcv_queue(NewKcp);
        _ ->
            Kcp
    end.

%% 更新ack失序次数
parse_fastack(Kcp = #kcp{snd_una = SndUna, snd_nxt = SndNxt}, Sn, Ts) ->
    case time_diff(Sn, SndUna) < 0 orelse time_diff(Sn, SndNxt) >= 0 of
        true ->
            Kcp;
        _ ->
            do_parse_fastack(Kcp, Sn, Ts, [])
    end.

do_parse_fastack(Kcp = #kcp{snd_buf = SndBuf = {SndBufIn, SndBufOut}}, Sn, Ts, RestSegs) ->
    case queue:out(SndBuf) of
        {{value, KcpSeg = #kcpseg{sn = SegSn, ts = SegTs, fastack = FastAck}}, NewSndBuf} ->
            case time_diff(Sn, SegSn) < 0 of
                true ->
                    NewSndBuf = {SndBufIn, lists:reverse(RestSegs, SndBufOut)},
                    Kcp#kcp{snd_buf = NewSndBuf};
                _ ->
                    NewKcpSeg =
                        case time_diff(Sn, SegSn) =/= 0 of
                            true ->
                                case time_diff(Ts, SegTs) >= 0 of
                                    true ->
                                        KcpSeg#kcpseg{fastack = FastAck + 1};
                                    _ ->
                                        KcpSeg
                                end;
                            _ ->
                                KcpSeg
                        end,
                    do_parse_fastack(Kcp#kcp{snd_buf = NewSndBuf}, Sn, Ts, [NewKcpSeg | RestSegs])
            end;
        {empty, _} ->
            NewSndBuf = {SndBufIn, lists:reverse(RestSegs, SndBufOut)},
            Kcp#kcp{snd_buf = NewSndBuf}
    end.

%% 更新发送窗口大小
update_cwnd(Kcp = #kcp{snd_una = SndUna, cwnd = CWnd, rmt_wnd = RmtWnd, mss = Mss, ssthresh = SSThresh, incr = Incr}, PrevUna) ->
    case time_diff(SndUna, PrevUna) > 0 of
        true ->
            case CWnd < RmtWnd of
                true ->
                    {NewCWnd0, NewIncr0} =
                        case CWnd < SSThresh of
                            true ->
                                {CWnd + 1, Incr + Mss};
                            _ ->
                                Incr0 = max(Incr, Mss),
                                Incr1 = Incr0 + ((Mss * Mss) div Incr0 + (Mss div 16)),
                                CWnd0 =
                                    case (CWnd + 1) * Mss =< Incr1 of
                                        true ->
                                            (Incr1 + Mss - 1) div max(Mss, 1);
                                        _ ->
                                            CWnd
                                    end,
                                {CWnd0, Incr1}
                        end,
                    {NewCWnd, NewIncr} =
                        case NewCWnd0 > RmtWnd of
                            true ->
                                {RmtWnd, RmtWnd * Mss};
                            _ ->
                                {NewCWnd0, NewIncr0}
                        end,
                    Kcp#kcp{cwnd = NewCWnd, incr = NewIncr};
                _ ->
                    Kcp
            end;
        _ ->
            Kcp
    end.

%% @doc kcp定时更新
-spec update(#kcp{}, pos_integer()) -> #kcp{}.
update(Kcp = #kcp{updated = Updated, ts_flush = TsFlush, interval = Interval}, Current0) ->
    Current = uint32(Current0),
    {NewUpdated, NewTsFlush0} =
        case Updated =:= 0 of
            true ->
                {1, Current};
            _ ->
                {Updated, TsFlush}
        end,

    Slap = time_diff(Current, NewTsFlush0),
    {NewSlap, NewTsFlush1} =
        case Slap >= 10000 orelse Slap < -10000 of
            true ->
                {0, Current};
            _ ->
                {Slap, NewTsFlush0}
        end,

    case NewSlap >= 0 of
        true ->
            NewTsFlush2 = NewTsFlush1 + Interval,
            NewTsFlush =
                case time_diff(Current, NewTsFlush2) >= 0 of
                    true ->
                        Current + Interval;
                    _ ->
                        NewTsFlush2
                end,
            NewKcp = Kcp#kcp{current = Current, updated = NewUpdated, ts_flush = NewTsFlush},
            flush(NewKcp);
        _ ->
            NewKcp = Kcp#kcp{current = Current, updated = NewUpdated, ts_flush = NewTsFlush1},
            NewKcp
    end.

%% @doc 计算下一次更新的时间
-spec check(#kcp{}, pos_integer()) -> pos_integer().
check(#kcp{updated = 0}, _Current0) ->
    0;
check(#kcp{ts_flush = TsFlush, snd_buf = SndBuf, interval = Interval}, Current0) ->
    Current = uint32(Current0),
    NewTsFlush =
        case time_diff(Current, TsFlush) >= 10000 orelse time_diff(Current, TsFlush) < -10000 of
            true ->
                Current;
            _ ->
                TsFlush
        end,
    case time_diff(Current, NewTsFlush) >= 0 of
        true ->
            0;
        _ ->
            TmFlush = time_diff(NewTsFlush, Current),
            case do_check(SndBuf, Current, 16#7fffffff) of
                false ->
                    0;
                TmPacket ->
                    Minimal = min(min(TmPacket, TmFlush), Interval),
                    Minimal
            end
    end.

do_check(SndBuf, Current, TmPacket) ->
    case queue:out(SndBuf) of
        {{value, #kcpseg{resendts = ResendTs}}, NewSndBuf} ->
            Diff = time_diff(ResendTs, Current),
            case Diff =< 0 of
                true ->
                    false;
                _ ->
                    NewTmPacket = min(TmPacket, Diff),
                    do_check(NewSndBuf, Current, NewTmPacket)
            end;
        {empty, _} ->
            TmPacket
    end.

%% @doc kcp刷新数据
-spec flush(#kcp{}) -> #kcp{}.
flush(Kcp = #kcp{updated = 1, conv = Conv, rcv_nxt = RcvNxt}) ->
    Buffer = <<>>,
    Wnd = wnd_unused(Kcp),
    KcpSeg = #kcpseg{conv = Conv, frg = 0, wnd = Wnd, una = RcvNxt, len = 0, sn = 0, ts = 0, data = <<>>},
    %% 发送ACK数据报
    {NewKcp0, NewBuffer0} = flush_ack_seg(Kcp, KcpSeg, Buffer),
    %% 探测远端接收窗口大小
    NewKcp1 = probe_win_size(NewKcp0),
    %% 发送探测窗口指令
    {NewKcp2 = #kcp{snd_wnd = SndWnd, rmt_wnd = RmtWnd, nocwnd = NoCWnd, cwnd = CWnd}, NewBuffer1} = flush_probe_win(NewKcp1, KcpSeg, NewBuffer0),
    %% 计算窗口大小
    NewCWnd0 = min(SndWnd, RmtWnd),
    NewCWnd = ?_IF_TRUE(NoCWnd =:= 0, min(NewCWnd0, CWnd), NewCWnd0),
    %% 将snd_queue数据移到snd_buf
    NewKcp3 = #kcp{fastresend = FastResend, nodelay = NoDelay, rx_rto = RxRto, snd_buf = SndBuf} = move_to_snd_buf(NewKcp2, NewCWnd),
    %% 计算重传
    Resent = ?_IF_TRUE(FastResend > 0, uint32(FastResend), 16#ffffffff),
    RtoMin = ?_IF_TRUE(NoDelay =:= 0, RxRto bsr 3, 0),
    %% 刷新并发送数据报文段
    {NewKcp4, Change, Lost} = flush_data_seg(NewKcp3, SndBuf, Resent, RtoMin, Wnd, 0, 0, [], NewBuffer1),
    %% 更新ssthresh
    NewKcp5 = flush_change_ssthresh(NewKcp4, Change, Resent),
    NewKcp6 = flush_lost_ssthresh(NewKcp5, Lost, NewCWnd),
    NewKcp = flush_ssthresh(NewKcp6),
    NewKcp;
flush(Kcp = #kcp{updated = 0}) -> %% 没有调用update方法不给执行
    Kcp.

%% 刷新并发送ack协议报
flush_ack_seg(Kcp = #kcp{acklist = AckList}, KcpSeg, Buffer) ->
    do_flush_ack_seg(Kcp, KcpSeg, AckList, Buffer).
do_flush_ack_seg(Kcp, KcpSeg, AckList, Buffer) ->
    NewBuffer0 = flush_output(Kcp, Buffer),
    case queue:out(AckList) of
        {{value, {Sn, Ts}}, NewAckList} ->
            NewKcpSeg = KcpSeg#kcpseg{cmd = ?KCP_CMD_ACK, sn = Sn, ts = Ts},
            NewBuffer = add_buffer(NewKcpSeg, NewBuffer0),
            do_flush_ack_seg(Kcp, KcpSeg, NewAckList, NewBuffer);
        {empty, AckList} ->
            NewKcp = Kcp#kcp{acklist = AckList},
            {NewKcp, NewBuffer0}
    end.

%% 探测远端接收窗口大小
probe_win_size(Kcp = #kcp{rmt_wnd = 0, probe_wait = 0, current = Current}) ->
    Kcp#kcp{probe_wait = ?KCP_PROBE_INIT, ts_probe = Current + ?KCP_PROBE_INIT};
probe_win_size(Kcp = #kcp{rmt_wnd = 0, probe_wait = ProbeWait, ts_probe = TsProbe, probe = Probe, current = Current}) ->
    case time_diff(Current, TsProbe) >= 0 of
        true ->
            NewProbeWait0 = max(ProbeWait, ?KCP_PROBE_INIT),
            NewProbeWait1 = NewProbeWait0 + NewProbeWait0 div 2,
            NewProbeWait = min(NewProbeWait1, ?KCP_PROBE_LIMIT),
            NewTsProbe = Current + NewProbeWait,
            NewProbe = Probe bor ?KCP_ASK_SEND,
            Kcp#kcp{probe_wait = NewProbeWait, ts_probe = NewTsProbe, probe = NewProbe};
        _ ->
            Kcp
    end;
probe_win_size(Kcp) ->
    Kcp#kcp{ts_probe = 0, probe_wait = 0}.

%% 刷新并发送探测窗口指令
flush_probe_win(Kcp = #kcp{probe = Probe}, KcpSeg, Buffer) ->
    NewBuffer1 =
        case (Probe band ?KCP_ASK_SEND) =/= 0 of
            true ->
                NewBuffer0 = flush_output(Kcp, Buffer),
                add_buffer(KcpSeg#kcpseg{cmd = ?KCP_CMD_WASK}, NewBuffer0);
            _ ->
                Buffer
        end,
    NewBuffer =
        case (Probe band ?KCP_ASK_TELL) =/= 0 of
            true ->
                NewBuffer2 = flush_output(Kcp, NewBuffer1),
                add_buffer(KcpSeg#kcpseg{cmd = ?KCP_CMD_WINS}, NewBuffer2);
            _ ->
                NewBuffer1
        end,
    NewKcp = Kcp#kcp{probe = 0},
    {NewKcp, NewBuffer}.

%% 将snd_queue数据移到snd_buf
move_to_snd_buf(Kcp = #kcp{snd_queue = SndQueue, snd_buf = SndBuf, nsnd_que = NSndQue, nsnd_buf = NSndBuf, snd_nxt = SndNxt, snd_una = SndUna, current = Current, rcv_nxt = RcvNxt, rx_rto = RxRto}, CWnd) ->
    case time_diff(SndNxt, SndUna + CWnd) < 0 of
        true ->
            case queue:out(SndQueue) of
                {{value, KcpSeg}, NewSndQueue} ->
                    NewKcpSeg = KcpSeg#kcpseg{cmd = ?KCP_CMD_PUSH, ts = Current, sn = SndNxt, una = RcvNxt, resendts = Current, rto = RxRto, fastack = 0, xmit = 0},
                    NewSndBuf = queue:in(NewKcpSeg, SndBuf),
                    NewKcp = Kcp#kcp{snd_queue = NewSndQueue, snd_buf = NewSndBuf, nsnd_que = NSndQue - 1, nsnd_buf = NSndBuf + 1, snd_nxt = SndNxt + 1},
                    move_to_snd_buf(NewKcp, CWnd);
                {empty, SndQueue} ->
                    Kcp
            end;
        _ ->
            Kcp
    end.

%% 刷新并发送数据报文段
flush_data_seg(Kcp = #kcp{rx_rto = RxRto, current = Current, nodelay = NoDelay, xmit = KcpXMit, fastlimit = FastLimit, rcv_nxt = RcvNxt, dead_link = DeadLink, state = State}, SndBuf, Resent, RtoMin, Wnd, Change, Lost, RestSegs, Buffer) ->
    case queue:out(SndBuf) of
        {{value, KcpSeg = #kcpseg{xmit = XMit, resendts = ResendTs, rto = Rto, fastack = FastAck}}, NewSndBuf} ->
            {NeedSend, NewKcpSeg, NewKcp, NewChange, NewLost} =
                case XMit =:= 0 of
                    true -> %% 第一次发送
                        NewKcpSeg0 = KcpSeg#kcpseg{xmit = 1, rto = RxRto, resendts = Current + RxRto + RtoMin},
                        {1, NewKcpSeg0, Kcp, Change, Lost};
                    _ ->
                        case time_diff(Current, ResendTs) >= 0 of
                            true -> %% 重传时间到
                                NewRto =
                                    case NoDelay =:= 0 of
                                        true ->
                                            Rto + max(Rto, RxRto);
                                        _ ->
                                            Step = ?_IF_TRUE(NoDelay < 2, Rto, RxRto),
                                            Rto + Step div 2
                                    end,
                                NewKcpSeg0 = KcpSeg#kcpseg{xmit = XMit + 1, rto = NewRto, resendts = Current + NewRto},
                                NewKcp0 = Kcp#kcp{xmit = KcpXMit + 1},
                                {1, NewKcpSeg0, NewKcp0, Change, 1};
                            _ when FastAck >= Resent andalso (XMit =< FastLimit orelse FastLimit =< 0) -> %% 失序次数达到需要重传的次数，并且已重传次数没有达到上限
                                NewKcpSeg0 = KcpSeg#kcpseg{xmit = XMit + 1, fastack = 0, resendts = Current + RxRto},
                                {1, NewKcpSeg0, Kcp, Change + 1, Lost};
                            _ ->
                                {0, KcpSeg, Kcp, Change, Lost}
                        end
                end,
            case NeedSend =:= 1 of
                true ->
                    SendKcpSeg = #kcpseg{xmit = SendXMit} = NewKcpSeg#kcpseg{ts = Current, wnd = Wnd, una = RcvNxt},
                    NewBuffer0 = flush_data_output(NewKcp, seg_size(SendKcpSeg), Buffer),
                    NewBuffer = add_buffer(SendKcpSeg, NewBuffer0),
                    NewState = ?_IF_TRUE(SendXMit >= DeadLink, 16#ffffffff, State),
                    flush_data_seg(NewKcp#kcp{state = NewState}, NewSndBuf, Resent, RtoMin, Wnd, NewChange, NewLost, [SendKcpSeg | RestSegs], NewBuffer);
                _ ->
                    flush_data_seg(NewKcp, NewSndBuf, Resent, RtoMin, Wnd, NewChange, NewLost, [NewKcpSeg | RestSegs], Buffer)
            end;
        {empty, _} ->
            NewKcp = Kcp#kcp{snd_buf = {RestSegs, []}},
            output(NewKcp, Buffer),
            {NewKcp, Change, Lost}
    end.

flush_change_ssthresh(Kcp = #kcp{snd_nxt = SndNxt, snd_una = SndUna, mss = Mss}, Change, Resent) when Change > 0 -> %% 快速恢复
    NewSsthresh0 = (SndNxt - SndUna) div 2,
    NewSsthresh = max(NewSsthresh0, ?KCP_THRESH_MIN),
    NewCWnd = NewSsthresh + Resent,
    NewIncr = NewCWnd * Mss,
    Kcp#kcp{ssthresh = NewSsthresh, cwnd = NewCWnd, incr = NewIncr};
flush_change_ssthresh(Kcp, _Change, _Resent) ->
    Kcp.

flush_lost_ssthresh(Kcp = #kcp{mss = Mss}, 1, CWnd) -> %% 慢启动
    NewSsthresh0 = CWnd div 2,
    NewSsthresh = max(NewSsthresh0, ?KCP_THRESH_MIN),
    Kcp#kcp{ssthresh = NewSsthresh, cwnd = 1, incr = Mss};
flush_lost_ssthresh(Kcp, _Lost, _CWnd) ->
    Kcp.

flush_ssthresh(Kcp = #kcp{cwnd = CWnd, mss = Mss}) when CWnd < 1 ->
    Kcp#kcp{cwnd = 1, incr = Mss};
flush_ssthresh(Kcp) ->
    Kcp.

%% 刷新发送数据
flush_output(Kcp = #kcp{mtu = Mtu}, Buffer) when byte_size(Buffer) + ?KCP_OVERHEAD > Mtu ->
    output(Kcp, Buffer),
    <<>>;
flush_output(_Kcp, Buffer) ->
    Buffer.

%% 刷新发送数据
flush_data_output(Kcp = #kcp{mtu = Mtu}, SegSize, Buffer) when byte_size(Buffer) + SegSize > Mtu ->
    output(Kcp, Buffer),
    <<>>;
flush_data_output(_Kcp, _SegSize, Buffer) ->
    Buffer.

%% 剩余接收窗口大小
wnd_unused(#kcp{nrcv_que = NRcvQue, rcv_wnd = RcvWnd}) when RcvWnd > NRcvQue ->
    RcvWnd - NRcvQue;
wnd_unused(#kcp{}) ->
    0.

%% kcp报文段转二进制 使用小端
seg_to_bin(#kcpseg{conv = Conv, cmd = Cmd, frg = Frg, wnd = Wnd, ts = Ts, sn = Sn, una = Una, len = Len, data = Data}) ->
    <<Conv:32/little, Cmd:8/little, Frg:8/little, Wnd:16/little, Ts:32/little, Sn:32/little, Una:32/little, Len:32/little, Data/binary>>.

%% 二进制转kcp报文段 使用小端
bin_to_seg(<<Conv:32/little, Cmd:8/little, Frg:8/little, Wnd:16/little, Ts:32/little, Sn:32/little, Una:32/little, Len:32/little, Data:Len/binary, RestBin/binary>>) when Len >= 0 ->
    KcpSeg = #kcpseg{conv = Conv, cmd = Cmd, frg = Frg, wnd = Wnd, ts = Ts, sn = Sn, una = Una, len = Len, data = Data},
    {ok, KcpSeg, RestBin};
bin_to_seg(_Bin) ->
    {error, kcp_unpack_err}.

%% kcp报文段大小
seg_size(#kcpseg{len = Len}) ->
    ?KCP_OVERHEAD + Len.

%% kcp报文段添加到buffer
add_buffer(KcpSeg, Buffer) ->
    <<Buffer/binary, (seg_to_bin(KcpSeg))/binary>>.

uint32(Int) ->
    Int band 16#ffffffff.

int32(Int) ->
    UInt32 = uint32(Int),
    UInt32 - (if UInt32 > 16#7fffffff -> 16#100000000; true -> 0 end).

time_diff(Later, Earlier) ->
    int32(uint32(Later) - uint32(Earlier)).