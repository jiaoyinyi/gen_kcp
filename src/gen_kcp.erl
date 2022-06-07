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

-define(IF_TRUE(If, True, False), case If of true -> True; _ -> False end).
-define(TIME_DIFF(Later, Earlier), Later - Earlier).

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
    , acklist, ackcount, ackblock              %% acklist, ackcount, ackblock: ACK 列表, ACK 列表的长度和容量. 待发送的 ACK 的相关信息会先存在 ACK 列表中, flush 时一并发送
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
        , ackblock = 0
        , ackcount = 0
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
    Count = ?IF_TRUE(Size =< Mss, 1, erlang:ceil(Size / Mss)),
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
recv(Kcp) ->
    todo.

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
    {error, packet_empty};
input(_Kcp, Bin) when byte_size(Bin) < ?KCP_OVERHEAD ->
    {error, bad_kcp_packet};
input(Kcp, Bin) ->
    input_unpack(Kcp, Bin).

input_unpack(Kcp, Bin) when byte_size(Bin) < ?KCP_OVERHEAD ->
    todo;
input_unpack(Kcp = #kcp{conv = Conv}, Bin) ->
    case bin_to_seq(Bin) of
        {ok, KcpSeq = #kcpseq{conv = Conv, cmd = Cmd}, RestBin} ->
            case Cmd of
                ?KCP_CMD_ACK ->
                    input_ack(Kcp);
                ?KCP_CMD_PUSH ->
                    todo;
                ?KCP_CMD_WASK ->
                    todo;
                ?KCP_CMD_WINS ->
                    {error, {bad_kcp_cmd, Cmd}}
            end;
        _ ->
            input_unpack(Kcp, <<>>)
    end.

input_ack(Kcp = #kcp{current = Current}, KcpSeq = #kcpseq{ts = Ts, sn = Sn}, AckFlag) ->
    NewKcp0 =
        case Current >= Ts of
            true ->
                update_ack(Kcp, Current - Ts);
            _ ->
                Kcp
        end,
    NewKcp1 = parse_ack(NewKcp0, Sn).

%% 更新ack相关信息
update_ack(Kcp = #kcp{rx_srtt = RxSrtt, rx_rttval = RxRttval, rx_minrto = RxMinrto, interval = Interval}, Rtt) ->
    {NewRxSrtt, NewRxRttval} =
        case RxSrtt == 0 of
            true ->
                NewRxSrtt0 = Rtt,
                NewRxRttval0 = Rtt / 2,
                {NewRxSrtt0, NewRxRttval0};
            _ ->
                Delta = abs(Rtt - RxSrtt),
                NewRxRttval0 = (3 * RxRttval + Delta) / 4,
                NewRxSrtt0 = max(1, (7 * RxSrtt + Rtt) / 8),
                {NewRxSrtt0, NewRxRttval0}
        end,
    Rto = NewRxSrtt + max(Interval, 4 * NewRxRttval),
    NewRxRto = min(max(RxMinrto, Rto), ?KCP_RTO_MAX),
    Kcp#kcp{rx_srtt = NewRxSrtt, rx_rttval = NewRxRttval, rx_rto = NewRxRto}.

%% 去掉snd_buf中命中的协议报
parse_ack(Kcp = #kcp{snd_una = SndUna, snd_nxt = SndNxt, snd_buf = SndBuf}, Sn) when Sn >= SndUna andalso Sn < SndNxt ->
    parse_ack2(Kcp, SndBuf, Sn, []);
parse_ack(Kcp, _Sn) ->
    Kcp.
parse_ack2(Kcp = #kcp{nsnd_buf = NSndBuf}, SndBuf, Sn, RestSeqs) ->
    case queue:out(SndBuf) of
        {{value, KcpSeq = #kcpseq{sn = Sn}}, {NewSndBufIn, NewSndBufOut}} ->
            NewSndBuf = {NewSndBufIn, lists:reverse(RestSeqs) ++ NewSndBufOut},
            Kcp#kcp{snd_buf = NewSndBuf, nsnd_buf = NSndBuf - 1};
        {{value, #kcpseq{sn = SeqSn}}, _} when SeqSn > Sn ->
            Kcp;
        {{value, KcpSeq}, NewSndBuf} ->
            parse_ack2(Kcp, NewSndBuf, Sn, [KcpSeq | RestSeqs]);
        {empty, _} ->
            Kcp
    end.

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

    Slap = ?TIME_DIFF(Current, TsFlush),
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
                case ?TIME_DIFF(Current, NewTsFlush2) >= 0 of
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

-spec check(#kcp{}, pos_integer()) -> {ok, #kcp{}} | {error, term()}.
check(Kcp, Current) ->
    todo.

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
    NewCWnd = ?IF_TRUE(NoCWnd =:= 0, min(NewCWnd0, CWnd), NewCWnd0),
    %% 将snd_queue数据移到snd_buf
    NewKcp3 = #kcp{fastresend = FastResend, nodelay = NoDelay, rx_rto = RxRto} = flush_to_snd_buf(NewKcp2, NewCWnd),
    %% 计算重传
    Resent = ?IF_TRUE(FastResend > 0, FastResend, -1),
    RtoMin = ?IF_TRUE(NoDelay =:= 0, RxRto bsr 3, 0),
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
            NewKcp = Kcp#kcp{ackcount = 0, acklist = AckList},
            {NewKcp, NewBuffer0}
    end.

%% 探测远端接收窗口大小
probe_win_size(Kcp = #kcp{rmt_wnd = 0, probe_wait = 0, current = Current}) ->
    Kcp#kcp{probe_wait = ?KCP_PROBE_INIT, ts_probe = Current + ?KCP_PROBE_INIT};
probe_win_size(Kcp = #kcp{rmt_wnd = 0, probe_wait = ProbeWait, ts_probe = TsProbe, probe = Probe, current = Current}) ->
    case Current >= TsProbe of
        true ->
            NewProbeWait0 = max(ProbeWait, ?KCP_PROBE_INIT),
            NewProbeWait1 = NewProbeWait0 + NewProbeWait0 / 2,
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
flush_to_snd_buf(Kcp = #kcp{snd_queue = SndQueue, snd_buf = SndBuf, nsnd_que = NSndQue, nsnd_buf = NSndBuf, snd_nxt = SndNxt, snd_una = SndUna, current = Current, rcv_nxt = RcvNxt, rx_rto = RxRto}, CWnd) when SndNxt - SndUna < CWnd ->
    case queue:out(SndQueue) of
        {{value, KcpSeq}, NewSndQueue} ->
            NewKcpSeq = KcpSeq#kcpseq{cmd = ?KCP_CMD_PUSH, ts = Current, sn = SndNxt, una = RcvNxt, resendts = Current, rto = RxRto, fastack = 0, xmit = 0},
            NewSndBuf = queue:in(NewKcpSeq, SndBuf),
            NewKcp = Kcp#kcp{snd_queue = NewSndQueue, snd_buf = NewSndBuf, nsnd_que = NSndQue - 1, nsnd_buf = NSndBuf + 1, snd_nxt = SndNxt + 1},
            flush_to_snd_buf(NewKcp, CWnd);
        {empty, SndQueue} ->
            Kcp
    end;
flush_to_snd_buf(Kcp, _CWnd) ->
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
                    Current >= ResendTs -> %% 重传时间到
                        NewRto =
                            case NoDelay =:= 0 of
                                true ->
                                    Rto + max(Rto, RxRto);
                                _ ->
                                    Step = ?IF_TRUE(NoDelay < 2, Rto, RxRto),
                                    Rto + Step / 2
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
                    NewState = ?IF_TRUE(SendXMit >= DeadLink, -1, State),
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
    NewSsthresh0 = (SndNxt - SndUna) / 2,
    NewSsthresh = max(NewSsthresh0, ?KCP_THRESH_MIN),
    NewCWnd = NewSsthresh + Resent,
    NewIncr = NewCWnd * Mss,
    Kcp#kcp{ssthresh = NewSsthresh, cwnd = NewCWnd, incr = NewIncr};
flush_change_ssthresh(Kcp, _Change, _Resent) ->
    Kcp.

flush_lost_ssthresh(Kcp = #kcp{mss = Mss}, 1, CWnd) -> %% 慢启动
    NewSsthresh0 = CWnd / 2,
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