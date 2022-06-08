%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 10. 5月 2022 12:22 上午
%%%-------------------------------------------------------------------
-module(gen_kcp).
-author("huangzaoyi").

%% API
-export([
    create/2
    , send/2
    , recv/1
    , update/2
]).

%% 报文段结构
%%0               4   5   6       8 (BYTE)
%%+---------------+---+---+-------+
%%|     conv      |cmd|frg|  wnd  |
%%+---------------+---+---+-------+   8
%%|     ts        |     sn        |
%%+---------------+---------------+  16
%%|     una       |     len       |
%%+---------------+---------------+  24
%%|                               |
%%|        DATA (optional)        |
%%|                               |
%%+-------------------------------+

-define(KCP_RTO_NDL, 30).
-define(KCP_RTO_MIN, 100).
-define(KCP_RTO_DEF, 200).
-define(KCP_RTO_MAX, 60000).

-define(KCP_CMD_PUSH, 81).
-define(KCP_CMD_ACK, 82).
-define(KCP_CMD_WASK, 83).
-define(KCP_CMD_WINS, 84).

-define(KCP_ASK_SEND, 1).
-define(KCP_ASK_TELL, 2).

-define(KCP_WND_SND, 32).
-define(KCP_WND_RCV, 128).

-define(KCP_MTU_DEF, 1400).
-define(KCP_ACK_FAST, 3).
-define(KCP_INTERVAL, 100).
-define(KCP_OVERHEAD, 24).
-define(KCP_DEADLINK, 20).
-define(KCP_THRESH_INIT, 2).
-define(KCP_THRESH_MIN, 2).
-define(KCP_PROBE_INIT, 7000).
-define(KCP_PROBE_LIMIT, 120000).
-define(KCP_FASTACK_LIMIT, 5).

-define(_IF_TRUE(If, True, False), case If of true -> True; _ -> False end).
-define(_UINT32(Int), (Int band 16#ffffffff)).
-define(_TIME_DIFF(Later, Earlier), ?_UINT32(Later) - ?_UINT32(Earlier)).



%% kcp结构
-record(kcp, {
    conv, mtu, mss, state                      %% conv: 连接标识；mtu, mss: 最大传输单元 (Maximum Transmission Unit) 和最大报文段大小. mss = mtu - 包头长度(24)；state: 连接状态, 0 表示连接建立, -1 表示连接断开
    , snd_una, snd_nxt, rcv_nxt                %% snd_una: 发送缓冲区中最小还未确认送达的报文段的编号；snd_nxt: 下一个等待发送的报文段的编号；rcv_nxt: 下一个等待接收的报文段的编号
    , ts_recent, ts_lastack, ssthresh          %% ssthresh: 慢启动阈值
    , rx_rto, rx_rttval, rx_srtt, rx_minrto    %% rx_rto: 超时重传时间；rx_rttval, rx_srtt, rx_minrto: 计算 rx_rto 的中间变量
    , snd_wnd, rcv_wnd, rmt_wnd, cwnd, probe   %% snd_wnd, rcv_wnd: 发送窗口和接收窗口的大小；rmt_wnd: 对端剩余接收窗口的大小；cwnd: 拥塞窗口. 用于拥塞控制；probe: 是否要发送控制报文的标志
    , current, interval, ts_flush, xmit        %% current: 当前时间；interval: flush 的时间粒度；ts_flush: 下次需要 flush 的时间；xmit: 该链接超时重传的总次数
    , nrcv_buf, nsnd_buf, nrcv_que, nsnd_que   %% nrcv_buf, nsnd_buf, nrcv_que, nsnd_que: 接收缓冲区, 发送缓冲区, 接收队列, 发送队列的长度
    , nodelay, updated                         %% nodelay: 是否启动快速模式. 用于控制 RTO 增长速度；updated: 是否调用过 ikcp_update
    , ts_probe, probe_wait                     %% ts_probe, probe_wait: 确定何时需要发送窗口询问报文
    , dead_link, incr                          %% dead_link: 当一个报文发送超时次数达到 dead_link 次时认为连接断开；incr: 用于计算 cwnd
    , snd_queue, rcv_queue                     %% snd_queue, rcv_queue: 发送队列和接收队列
    , snd_buf, rcv_buf                         %% snd_buf, rcv_buf: 发送缓冲区和接收缓冲区
    , acklist                                  %% acklist: ACK 列表. 待发送的 ACK 的相关信息会先存在 ACK 列表中, flush 时一并发送
    , buffer                                   %% buffer: flush 时用到的临时缓冲区
    , fastresend                               %% fastresend: ACK 失序 fastresend 次时触发快速重传
    , fastlimit                                %% fastlimit: 传输次数小于 fastlimit 的报文才会执行快速重传
    , nocwnd, stream                           %% nocwnd: 是否不考虑拥塞窗口；stream: 是否开启流模式, 开启后可能会合并包
    , logmask                                  %% logmask: 用于控制日志
    , output                                   %% output: 下层协议输出函数
    , writelog                                 %% writelog: 日志函数
    , socket
}).

%% kcp报文段
-record(kcpseq, {
    conv                       %% 连接标识
    , cmd                      %% 指令
    , frg                      %% 分片数量。表示随后还有多少个报文属于同一个包
    , wnd                      %% 发送方剩余接收窗口的大小
    , ts                       %% 时间戳ms
    , sn                       %% 报文编号
    , una                      %% 发送方的接收缓冲区中最小还未收到的报文段的编号。编号比它小的报文段都已全部接收
    , len = 0                  %% 数据段长度
    , data = <<>>              %% 数据段
    , resendts = 0             %% 重传时间戳。超过这个时间表示该报文超时, 需要重传
    , rto = 0                  %% 重传超时时间。数据发送时刻算起，超过这个时间便执行重传
    , fastack = 0              %% ACK 失序次数
    , xmit = 0                 %% 该报文传输的次数
}).

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
        , stream = 0

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
        , rx_rto = 0
        , rx_rto = ?KCP_RTO_DEF
        , rx_minrto = ?KCP_RTO_MIN
        , current = 0
        , interval = ?KCP_INTERVAL
        , ts_flush = ?KCP_INTERVAL
        , nodelay = 0
        , updated = 0
        , logmask = 0
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
        true -> %% 数据包太大了
            {error, data_oversize};
        _ ->
            NewKcp = send_add_seq(Kcp, 1, Count, Data),
            {ok, NewKcp}
    end.

%% 发送数据时添加分片
send_add_seq(Kcp = #kcp{conv = Conv, mss = Mss, snd_queue = SndQueue, nsnd_que = NSndQue}, Idx, Count, <<Data:Mss/binary, Bin>>) when Idx < Count ->
    KcpSeq = #kcpseq{conv = Conv, frg = Count - Idx, len = Mss, data = Data},
    NewKcp = Kcp#kcp{snd_queue = queue:in(KcpSeq, SndQueue), nsnd_que = NSndQue + 1},
    send_add_seq(NewKcp, Idx + 1, Count, Bin);
send_add_seq(Kcp = #kcp{conv = Conv, snd_queue = SndQueue, nsnd_que = NSndQue}, Idx, Count, Data) when Idx =:= Count ->
    KcpSeq = #kcpseq{conv = Conv, frg = Count - Idx, len = byte_size(Data), data = Data},
    NewKcp = Kcp#kcp{snd_queue = queue:in(KcpSeq, SndQueue), nsnd_que = NSndQue + 1},
    NewKcp.

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
                    NewKcp1 = #kcp{nrcv_que = NRcvQue, rcv_wnd = RcvWnd, probe = Probe} = move_to_rcv_queue(NewKcp0),
                    NewProbe = ?_IF_TRUE(NRcvQue < RcvWnd andalso Recover =:= 1, Probe bor ?KCP_ASK_TELL, Probe),
                    NewKcp = NewKcp1#kcp{probe = NewProbe},
                    {ok, NewKcp, Bin}
            end
    end.

%% 计算完整数据包数据大小
peeksize(#kcp{rcv_queue = RcvQueue, nrcv_que = NRcvQue}) ->
    case queue:out(RcvQueue) of
        {empty, _} ->
            -1;
        {{value, #kcpseq{frg = 0, len = Len}}, _} ->
            Len;
        {{value, #kcpseq{frg = Frg}}, _} ->
            case NRcvQue < Frg + 1 of
                true ->
                    -1;
                _ ->
                    do_peeksize(RcvQueue, 0)
            end
    end.

do_peeksize(RcvQueue, Size) ->
    case queue:out(RcvQueue) of
        {{value, #kcpseq{frg = 0, len = Len}}, NewRcvQueue} ->
            Size + Len;
        {{value, #kcpseq{frg = Frg, len = Len}}, NewRcvQueue} ->
            do_peeksize(NewRcvQueue, Size + Len);
        {empty, _} -> %% 正常不会走到这里
            -1
    end.

%% 整合分段
merge_fragment(Kcp = #kcp{rcv_queue = RcvQueue, nrcv_que = NRcvQue}, Buffer) ->
    case queue:out(RcvQueue) of
        {{value, #kcpseq{frg = 0, data = Data}}, NewRcvQueue} ->
            NewKcp = Kcp#kcp{rcv_queue = NewRcvQueue, nrcv_que = NRcvQue - 1},
            NewBuffer = <<Buffer/binary, Data/binary>>,
            {NewKcp, NewBuffer};
        {{value, #kcpseq{len = Len, data = Data}}, NewRcvQueue} ->
            NewKcp = Kcp#kcp{rcv_queue = NewRcvQueue, nrcv_que = NRcvQue - 1},
            NewBuffer = <<Buffer/binary, Data/binary>>,
            merge_fragment(NewKcp, NewBuffer);
        {empty, _} ->
            {Kcp, Buffer}
    end.

-spec getopts(#kcp{}, list()) -> {ok, [{atom(), term()}]} | {error, term()}.
getopts(Kcp, Opts) ->
    todo.

-spec setopts(#kcp{}, [{atom(), term()}]) -> ok | {error, term()}.
setopts(Kcp, Opts) ->
    todo.

-spec output(#kcp{}, binary()) -> {ok, #kcp{}} | {error, term()}.
output(_Kcp, <<>>) ->
    ok;
output(Kcp, Data) ->
    todo.

-spec input(#kcp{}, binary()) -> {ok, #kcp{}} | {error, term()}.
input(_Kcp, <<>>) ->
    {error, kcp_data_empty}; %% 下层协议输入的数据是空的
input(_Kcp, Bin) when byte_size(Bin) < ?KCP_OVERHEAD ->
    {error, kcp_data_err}; %% 下层协议输入的数据小于kcp协议报头大小
input(Kcp = #kcp{una = PrevUna}, Bin) ->
    input_unpack(Kcp, Bin, PrevUna, 0, 0, 0).

input_unpack(Kcp, Bin, PrevUna, AckFlag, MaxAck, LastestTs) when byte_size(Bin) < ?KCP_OVERHEAD ->
    NewKcp0 = ?_IF_TRUE(AckFlag =:= 1, parse_fastack(Kcp, MaxAck, LastestTs), Kcp),
    NewKcp = update_cwnd(NewKcp0, PrevUna),
    NewKcp;
input_unpack(Kcp = #kcp{conv = Conv, probe = Probe, rcv_nxt = RcvNxt, rcv_wnd = RcvWnd}, Bin, PrevUna, AckFlag, MaxAck, LastestTs) ->
    case bin_to_seq(Bin) of
        {ok, KcpSeq = #kcpseq{conv = Conv, cmd = Cmd, wnd = Wnd, sn = Sn, ts = Ts}, RestBin} ->
            case Cmd =/= ?KCP_CMD_ACK andalso Cmd =/= ?KCP_CMD_PUSH andalso Cmd =/= ?KCP_CMD_WASK andalso Cmd =/= ?KCP_CMD_WINS of
                true ->
                    {error, {kcp_cmd_err, Cmd}};
                _ ->
                    NewKcp0 = Kcp#kcp{rmt_wnd = Wnd},
                    NewKcp1 = parse_una(NewKcp0),
                    NewKcp2 = shrink_buf(NewKcp1),
                    case Cmd of
                        ?KCP_CMD_ACK ->
                            {NewKcp3, NewAckFlag0, NewMaxAck0, NewLastestTs0} = input_ack(NewKcp2, AckFlag, MaxAck, LastestTs);
                        ?KCP_CMD_PUSH ->
                            NewKcp5 =
                                case ?_TIME_DIFF(Sn, RcvNxt + RcvWnd) < 0 of
                                    true ->
                                        NewKcp3 = ack_push(NewKcp2, Sn, Ts),
                                        NewKcp4 = parse_data(NewKcp3),
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
                    end
            end;
        _ ->
            input_unpack(Kcp, <<>>, PrevUna, AckFlag, MaxAck, LastestTs)
    end.

%% 去掉snd_buf中小于Una的协议报
parse_una(Kcp = #kcp{snd_buf = SndBuf, nsnd_buf = NSndBuf}, Una) ->
    case queue:out(SndBuf) of
        {{value, #kcpseq{sn = Sn}}, NewSndBuf} when ?_TIME_DIFF(Una, Sn) > 0 ->
            parse_una(Kcp#kcp{snd_buf = NewSndBuf, nsnd_buf = NSndBuf - 1}, Una);
        _ ->
            Kcp
    end.

%% 更新snd_una
shrink_buf(Kcp = #kcp{snd_buf = SndBuf, snd_nxt = SndNxt}) ->
    case queue:out(SndBuf) of
        {{value, #kcpseq{sn = Sn}}, _} -> %% 把第一个未ack的协议报编制作为snd_una
            Kcp#kcp{snd_una = Sn};
        {empty, _} ->
            Kcp#kcp{snd_una = SndNxt}
    end.

%% 去掉snd_buf中命中的协议报
parse_ack(Kcp = #kcp{snd_una = SndUna, snd_nxt = SndNxt, snd_buf = SndBuf}, Sn) when ?_TIME_DIFF(Sn, SndUna) < 0 andalso ?_TIME_DIFF(Sn, SndNxt) >= 0 ->
    Kcp;
parse_ack(Kcp, Sn) ->
    parse_ack2(Kcp, SndBuf, Sn, []).

parse_ack2(Kcp = #kcp{nsnd_buf = NSndBuf}, SndBuf, Sn, RestSeqs) ->
    case queue:out(SndBuf) of
        {{value, KcpSeq = #kcpseq{sn = Sn}}, {NewSndBufIn, NewSndBufOut}} ->
            NewSndBuf = {NewSndBufIn, lists:reverse(RestSeqs, NewSndBufOut)},
            Kcp#kcp{snd_buf = NewSndBuf, nsnd_buf = NSndBuf - 1};
        {{value, #kcpseq{sn = SeqSn}}, _} when ?_TIME_DIFF(Sn, SeqSn) < 0 ->
            Kcp;
        {{value, KcpSeq}, NewSndBuf} ->
            parse_ack2(Kcp, NewSndBuf, Sn, [KcpSeq | RestSeqs]);
        {empty, _} ->
            Kcp
    end.

input_ack(Kcp = #kcp{current = Current}, KcpSeq = #kcpseq{ts = Ts, sn = Sn}, AckFlag, MaxAck, LastestTs) ->
    NewKcp0 = ?_IF_TRUE(?_TIME_DIFF(Current, Ts) >= 0, update_ack(Kcp, ?_TIME_DIFF(Current, Ts)), Kcp),
    NewKcp1 = parse_ack(NewKcp0, Sn),
    NewKcp = shrink_buf(NewKcp1),
    {NewAckFlag, NewMaxAck, NewLastestTs} =
        case AckFlag =:= 0 of
            true ->
                {1, Sn, Ts};
            _ when ?_TIME_DIFF(Sn, MaxAck) > 0 ->
                -ifdef (KCP_FASTACK_CONSERVE).
                    {AckFlag, Sn, Ts}
                -else.
                    case ?_TIME_DIFF(Ts, LastestTs) > 0 of
                        true ->
                            {AckFlag, Sn, Ts}
                        _ ->
                            {AckFlag, MaxAck, LastestTs}
                    end
                -endif.
            _ ->
                {AckFlag, Sn, Ts}
        end,
    {NewKcp, NewAckFlag, NewMaxAck, NewLastestTs}.

%% 更新ack相关信息
update_ack(Kcp = #kcp{rx_srtt = RxSrtt, rx_rttval = RxRttval, rx_minrto = RxMinrto, interval = Interval}, Rtt) ->
    {NewRxSrtt, NewRxRttval} =
        case RxSrtt == 0 of
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
parse_data(Kcp = #kcp{rcv_nxt = RcvNxt, rcv_wnd = RcvWnd}, #kcpseq{sn = Sn}) when ?_TIME_DIFF(Sn, RcvNxt + RcvWnd) >= 0 orelse ?_TIME_DIFF(Sn, RcvNxt) < 0 ->
    Kcp;
parse_data(Kcp = #kcp{rcv_nxt = RcvNxt, rcv_wnd = RcvWnd, rcv_buf = RcvBuf, nrcv_buf = NRcvBuf}, NewKcpSeq = #kcpseq{sn = Sn}) ->
    NewKcp0 = do_parse_data(Kcp, NewKcpSeq, RcvBuf, NRcvBuf, []),
    NewKcp = move_to_rcv_queue(NewKcp0),
    NewKcp.

do_parse_data(Kcp, NewKcpSeq = #kcpseq{sn = NewSn}, RcvBuf = {RcvBufIn, RcvBufOut}, NRcvBuf, RestSeqs) ->
    case queue:out_r(RcvBuf) of %% 从后往前出队列
        {{value, #kcpseq{sn = NewSn}}, NewRcvBuf} -> %% 协议报重复
            Kcp;
        {{value, #kcpseq{sn = Sn}}, _} when ?_TIME_DIFF(NewSn, Sn) > 0 ->
            NewRcvBuf = {lists:reverse([NewKcpSeq | RestSeqs], RcvBufIn), RcvBufOut},
            Kcp#kcp{rcv_buf = NewRcvBuf, nrcv_buf = NRcvBuf + 1};
        {{value, KcpSeq}, NewRcvBuf} ->
            do_parse_data(Kcp, NewKcpSeq, NewRcvBuf, NRcvBuf, [KcpSeq | RestSeqs]);
        {empty, _} ->
            NewRcvBuf = {lists:reverse([NewKcpSeq | RestSeqs], RcvBufIn), RcvBufOut},
            Kcp#kcp{rcv_buf = NewRcvBuf, nrcv_buf = NRcvBuf + 1};
    end.

%% 将有效的数据移到到rcv_queue
move_to_rcv_queue(Kcp = #kcp{rcv_buf = RcvBuf, nrcv_buf = NRcvBuf, rcv_queue = RcvQueue, nrcv_que = NRcvQue, nrcv_nxt = RcvNxt, rcv_wnd = RcvWnd}) ->
    case queue:out(RcvBuf) of
        {{value, KcpSeq = #kcpseq{sn = Sn}}, NewRcvBuf} when Sn =:= RcvNxt andalso NRcvQue < RcvWnd ->
            NewKcp = Kcp#kcp{rcv_buf = NewRcvBuf, nrcv_buf = NRcvBuf - 1, rcv_queue = queue:in(KcpSeq, RcvQueue), nrcv_que = NRcvQue + 1, nrcv_nxt = RcvNxt + 1},
            move_to_rcv_queue(Kcp);
        _ ->
            Kcp
    end.

%% 更新ack失序次数
parse_fastack(Kcp = #kcp{snd_una = SndUna, snd_nxt = SndNxt}, Sn, Ts) when ?_TIME_DIFF(Sn, SndUna) < 0 orelse ?_TIME_DIFF(Sn, SndNxt) >= 0 ->
    Kcp.
parse_fastack(Kcp, Sn, Ts) ->
    do_parse_fastack(Kcp, Sn, Ts, []).

do_parse_fastack(Kcp = #kcp{snd_buf = SndBuf = {SndBufIn, SndBufOut}, snd_una = SndUna, snd_nxt = SndNxt}, Sn, Ts, RestSeqs) ->
    case queue:out(SndBuf) of
        {{value, KcpSeq = #kcpseq{sn = SeqSn}}, _} when ?_TIME_DIFF(Sn, SeqSn) < 0 ->
            NewSndBuf = {SndBufIn, lists:reverse(RestSeqs, SndBufOut)},
            Kcp#kcp{snd_buf = NewSndBuf};
        {{value, KcpSeq = #kcpseq{fastack = FastAck, ts = SeqTs}}, NewSndBuf} ->
            NewKcpSeq =
                -ifdef (KCP_FASTACK_CONSERVE).
                    KcpSeq#kcpseq{fastack = FastAck + 1}
                -else.
                    case ?_TIME_DIFF(Ts, SeqTs) >= 0 of
                        true ->
                            KcpSeq#kcpseq{fastack = FastAck + 1};
                        _ ->
                            KcpSeq
                    end
                -endif.
            do_parse_fastack(Kcp#kcp{snd_buf = NewSndBuf}, Sn, Ts, [NewKcpSeq | RestSeqs]);
        {empty, _} ->
            NewSndBuf = {SndBufIn, lists:reverse(RestSeqs, SndBufOut)},
            Kcp#kcp{snd_buf = NewSndBuf}
    end.

%% 更新发送窗口大小
update_cwnd(Kcp = #kcp{snd_una = SndUna, cwnd = CWnd, rmt_wnd = RmtWnd, mss = Mss, ssthresh = SSThresh, incr = Incr}, PrevUna) when ?_TIME_DIFF(SndUna, PrevUna) > 0 ->
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
                                    (Incr1 + Mss - 1) div ?_IF_TRUE(Mss > 0, Mss, 1);
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
update_cwnd(Kcp, _PrevUna) ->
    Kcp.

%% kcp定时更新
-spec update(#kcp{}, pos_integer()) -> {ok, #kcp{}} | {error, term()}.
update(Kcp = #kcp{updated = Updated, ts_flush = TsFlush, interval = Interval}, Current) ->
    {NewUpdated, NewTsFlush0} =
        case Updated =:= 0 of
            true ->
                {1, Current};
            _ ->
                {Updated, TsFlush}
        end,

    Slap = ?_TIME_DIFF(Current, TsFlush),
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
                case ?_TIME_DIFF(Current, NewTsFlush2) >= 0 of
                    true ->
                        Current + Interval;
                    _ ->
                        NewTsFlush2
                end,
            NewKcp = Kcp#kcp{current = Current, updated = NewUpdated, ts_flush = NewTsFlush},
            flush(NewKcp);
        _ ->
            NewKcp = Kcp#kcp{current = Current, updated = NewUpdated, ts_flush = NewTsFlush1},
            {ok, NewKcp}
    end.

-spec check(#kcp{}, pos_integer()) -> pos_integer().
check(Kcp = #kcp{updated = 0}, Current) ->
    Current.
check(Kcp = #kcp{ts_flush = TsFlush, snd_buf = SndBuf, interval = Interval}, Current) ->
    NewTsFlush = ?_IF_TRUE(Current - TsFlush >= 10000 orelse Current - TsFlush < -10000, Current, TsFlush),
    case Current >= NewTsFlush of
        true ->
            Current;
        _ ->
            TmFlush = NewTsFlush - Current,
            case do_check(SndBuf, Current, 16#7fffffff) of
                false ->
                    Current;
                TmPacket ->
                    Minimal = min(min(TmPacket, TmFlush), Interval),
                    Current + Minimal
            end
    end.

do_check(SndBuf, Current, TmPacket) ->
    case queue:out(SndBuf) of
        {{value, #kcpseq{resendts = ResendTs}}, NewSndBuf} ->
            Diff = ResendTs - Current,
            case Diff =< 0 of
                true ->
                    false;
                _ ->
                    NewTmPacket = min(TmPacket, Diff),
                    do_check(NewSndBuf, NewTmPacket)
            end;
        {emtpy, _} ->
            TmPacket
    end.

%% @doc kcp刷新数据
-spec flush(#kcp{}) -> {ok, #kcp{}} | {error, term()}.
flush(Kcp = #kcp{updated = 1, conv = Conv, rcv_nxt = RcvNxt}) ->
    Buffer = <<>>,
    Wnd = wnd_unused(Kcp),
    KcpSeq = #kcpseq{conv = Conv, frg = 0, wnd = Wnd, una = RcvNxt, len = 0, sn = 0, ts = 0, data = <<>>},
    %% 发送ACK数据报
    {NewKcp0, NewBuffer0} = flush_ack_seq(Kcp, KcpSeq, Buffer),
    %% 探测远端接收窗口大小
    NewKcp1 = probe_win_size(NewKcp0),
    %% 发送探测窗口指令
    {NewKcp2 = #kcp{snd_wnd = SndWnd, rmt_wnd = RmtWnd, nocwnd = NoCWnd, cwnd = CWnd}, NewBuffer1} = flush_probe_win(NewKcp1, KcpSeq, NewBuffer0),
    %% 计算窗口大小
    NewCWnd0 = min(SndWnd, RmtWnd),
    NewCWnd = ?_IF_TRUE(NoCWnd =:= 0, min(NewCWnd0, CWnd), NewCWnd0),
    %% 将snd_queue数据移到snd_buf
    NewKcp3 = #kcp{fastresend = FastResend, nodelay = NoDelay, rx_rto = RxRto} = move_to_snd_buf(NewKcp2, NewCWnd),
    %% 计算重传
    Resent = ?_IF_TRUE(FastResend > 0, FastResend, -1),
    RtoMin = ?_IF_TRUE(NoDelay =:= 0, RxRto bsr 3, 0),
    %% 刷新并发送数据报文段
    {NewKcp4, Change, Lost} = flush_data_seq(NewKcp3, Resent, RtoMin, Wnd, 0, 0, [], NewBuffer1),
    %% 更新ssthresh
    NewKcp5 = flush_change_ssthresh(NewKcp4, Change, Resent),
    NewKcp6 = flush_lost_ssthresh(NewKcp5, Lost, NewCWnd),
    NewKcp = flush_ssthresh(NewKcp6),
    {ok, NewKcp};
flush(Kcp = #kcp{updated = 0}) -> %% 没有调用update方法不给执行
    {ok, Kcp}.

%% 刷新并发送ACK数据报
-spec flush_ack_seq(#kcp{}, #kcpseq{}, binary()) -> {#kcp{}, binary()}.
flush_ack_seq(Kcp = #kcp{acklist = AckList}, KcpSeq, Buffer) ->
    do_flush_ack_seq(Kcp, KcpSeq, AckList, Buffer).
do_flush_ack_seq(Kcp, KcpSeq, AckList, Buffer) ->
    NewBuffer0 = flush_output(Kcp, Buffer),
    case queue:out(AckList) of
        {{value, {Sn, Ts}}, NewAckList} ->
            NewKcpSeq = KcpSeq#kcpseq{cmd = ?KCP_CMD_ACK, sn = Sn, ts = Ts},
            NewBuffer = add_buffer(NewKcpSeq, NewBuffer0),
            do_flush_ack_seq(Kcp, KcpSeq, NewAckList, NewBuffer);
        {empty, AckList} ->
            NewKcp = Kcp#kcp{acklist = AckList},
            {NewKcp, NewBuffer0}
    end.

%% 探测远端接收窗口大小
probe_win_size(Kcp = #kcp{rmt_wnd = 0, probe_wait = 0, current = Current}) ->
    Kcp#kcp{probe_wait = ?KCP_PROBE_INIT, ts_probe = Current + ?KCP_PROBE_INIT};
probe_win_size(Kcp = #kcp{rmt_wnd = 0, probe_wait = ProbeWait, ts_probe = TsProbe, probe = Probe, current = Current}) ->
    case ?_TIME_DIFF(Current, TsProbe) >= 0 of
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
flush_probe_win(Kcp = #kcp{probe = Probe}, KcpSeq, Buffer) ->
    NewBuffer0 =
        case Probe band ?KCP_ASK_SEND =:= 1 of
            true ->
                NewBuffer0 = flush_output(Kcp, Buffer),
                NewKcpSeq = KcpSeq#kcpseq{cmd = ?KCP_CMD_WASK},
                add_buffer(NewKcpSeq, NewBuffer0);
            _ ->
                Buffer
        end,
    NewBuffer =
        case Probe band ?KCP_ASK_TELL =:= 1 of
            true ->
                NewBuffer1 = flush_output(Kcp, NewBuffer0),
                NewKcpSeq = KcpSeq#kcpseq{cmd = ?KCP_CMD_WINS},
                add_buffer(NewKcpSeq, NewBuffer1);
            _ ->
                NewBuffer0
        end,
    NewKcp = Kcp#kcp{probe = 0},
    {NewKcp, NewBuffer}.

%% 将snd_queue数据移到snd_buf
move_to_snd_buf(Kcp = #kcp{snd_queue = SndQueue, snd_buf = SndBuf, nsnd_que = NSndQue, nsnd_buf = NSndBuf, snd_nxt = SndNxt, snd_una = SndUna, current = Current, rcv_nxt = RcvNxt, rx_rto = RxRto}, CWnd) when ?_TIME_DIFF(SndNxt, SndUna + CWnd) < 0 ->
    case queue:out(SndQueue) of
        {{value, KcpSeq}, NewSndQueue} ->
            NewKcpSeq = KcpSeq#kcpseq{cmd = ?KCP_CMD_PUSH, ts = Current, sn = SndNxt, una = RcvNxt, resendts = Current, rto = RxRto, fastack = 0, xmit = 0},
            NewSndBuf = queue:in(NewKcpSeq, SndBuf),
            NewKcp = Kcp#kcp{snd_queue = NewSndQueue, snd_buf = NewSndBuf, nsnd_que = NSndQue - 1, nsnd_buf = NSndBuf + 1, snd_nxt = SndNxt + 1},
            move_to_snd_buf(NewKcp, CWnd);
        {empty, SndQueue} ->
            Kcp
    end;
move_to_snd_buf(Kcp, _CWnd) ->
    Kcp.

%% 刷新并发送数据报文段
flush_data_seq(Kcp = #kcp{snd_buf = SndBuf, rx_rto = RxRto, current = Current, nodelay = NoDelay, xmit = KcpXMit, fastlimit = FastLimit, rcv_nxt = RcvNxt, mtu = Mtu, dead_link = DeadLink, state = State}, Resent, RtoMin, Wnd, Change, Lost, RestSeqs, Buffer) ->
    case queue:out(SndBuf) of
        {{value, KcpSeq = #kcpseq{xmit = XMit, resendts = ResendTs, rto = Rto, fastack = FastAck}}, NewSndBuf} ->
            {NeedSend, NewKcpSeq, NewKcp, NewChange, NewLost} =
                if
                    XMit =:= 0 -> %% 第一次发送
                        NewKcpSeq0 = KcpSeq#kcpseq{xmit = 1, rto = RxRto, resendts = Current + RxRto + RtoMin},
                        {true, NewKcpSeq0, Kcp, Change, Lost};
                    ?_TIME_DIFF(Current, ResendTs) >= 0 -> %% 重传时间到
                        NewRto =
                            case NoDelay =:= 0 of
                                true ->
                                    Rto + max(Rto, ?_UINT32(RxRto));
                                _ ->
                                    Step = ?_IF_TRUE(NoDelay < 2, Rto, RxRto),
                                    Rto + Step div 2
                            end,
                        NewKcpSeq0 = KcpSeq#kcpseq{xmit = XMit + 1, rto = NewRto, resendts = Current + NewRto},
                        NewKcp0 = Kcp#kcp{xmit = KcpXMit + 1},
                        {true, NewKcpSeq0, NewKcp0, Change, 1};
                    FastAck >= Resent andalso (XMit =< FastLimit orelse FastLimit =< 0) -> %% 失序次数达到需要重传的次数，并且已重传次数没有达到上限
                        NewKcpSeq0 = KcpSeq#kcpseq{xmit = XMit + 1, fastack = 0, resendts = Current + RxRto},
                        {true, NewKcpSeq0, Kcp, Change + 1, Lost};
                    true ->
                        {false, KcpSeq, Kcp, Change, Lost}
                end,
            case NeedSend of
                true ->
                    SendKcpSeq = #kcpseq{xmit = SendXMit} = NewKcpSeq#kcpseq{ts = Current, wnd = Wnd, una = RcvNxt},
                    NewBuffer0 = flush_data_output(NewKcp, seq_size(SendKcpSeq), Buffer),
                    NewBuffer = add_buffer(SendKcpSeq, NewBuffer0),
                    NewState = ?_IF_TRUE(SendXMit >= DeadLink, -1, State),
                    flush_data_seq(NewKcp#kcp{snd_buf = NewSndBuf, state = NewState}, Resent, RtoMin, Wnd, NewChange, NewLost, RestSeqs, NewBuffer);
                _ ->
                    flush_data_seq(NewKcp#kcp{snd_buf = NewSndBuf}, Resent, RtoMin, Wnd, NewChange, NewLost, [NewKcpSeq | RestSeqs], Buffer)
            end;
        {empty, SndBuf} ->
            NewKcp = Kcp#kcp{snd_buf = {RestSeqs, []}},
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
flush_data_output(Kcp = #kcp{mtu = Mtu}, SeqSize, Buffer) when byte_size(Buffer) + SeqSize > Mtu ->
    output(Kcp, Buffer),
    <<>>;
flush_data_output(_Kcp, _SeqSize, Buffer) ->
    Buffer.

%% 剩余接收窗口大小
wnd_unused(#kcp{nrcv_que = NRcvQue, rcv_wnd = RcvWnd}) when RcvWnd > NRcvQue ->
    RcvWnd - NRcvQue;
wnd_unused(#kcp{}) ->
    0.

%% kcp报文段转二进制
seq_to_bin(#kcpseq{conv = Conv, cmd = Cmd, frg = Frg, wnd = Wnd, ts = Ts, sn = Sn, una = Una, len = Len, data = Data}) ->
    <<Conv:32, Cmd:8, Frg:8, Wnd:16, Ts:32, Sn:32, Una:32, Len:32, Data/binary>>.

%% 二进制转kcp报文段
bin_to_seq(<<Conv:32, Cmd:8, Frg:8, Wnd:16, Ts:32, Sn:32, Una:32, Len:32, Data:Len/binary, RestBin/binary>>) ->
    KcpSeq = #kcpseq{conv = Conv, cmd = Cmd, frg = Frg, wnd = Wnd, ts = Ts, sn = Sn, una = Una, len = Len, data = Data},
    {ok, KcpSeq, RestBin};
bin_to_seq(_Bin) ->
    {error, bad_kcp_packet}.

%% kcp报文段大小
seq_size(#kcpseq{len = Len}) ->
    ?KCP_OVERHEAD + Len.

%% kcp报文段添加到buffer
add_buffer(KcpSeq, Buffer) ->
    <<Buffer/binary, (seq_to_bin(KcpSeq))/binary>>.

%% 队列根据键查找一项，并返回新队列
qkeytake(_Key, _Pos, {[], []}) ->
    false;
qkeytake(Key, Pos, {In, Out}) ->
    case lists:keytake(Key, Pos, In) of
        false ->
            case lists:keytake(Key, Pos, Out) of
                false ->
                    false;
                {value, Tuple, NewOut} ->
                    {value, Tuple, {In, NewOut}}
            end;
        {value, Tuple, NewIn} ->
            {value, Tuple, {NewIn, Out}}
    end.
