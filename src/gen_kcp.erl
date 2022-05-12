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
    , len                      %% 数据段长度
    , data                     %% 数据段
    , resendts                 %% 重传时间戳。超过这个时间表示该报文超时, 需要重传
    , rto                      %% 重传超时时间。数据发送时刻算起，超过这个时间便执行重传
    , fastack                  %% ACK 失序次数
    , xmit                     %% 该报文传输的次数
}).

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
        , snd_buf = []
        , rcv_buf = []
        , nrcv_que = 0
        , nsnd_que = 0
        , nrcv_buf = 0
        , nsnd_buf = 0
        , state = 0
        , acklist = []
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

-spec send(#kcp{}, binary()) -> {ok, #kcp{}} | {error, term()}.
send(#kcp{conv = Conv, mss = Mss}, Data) when is_binary(Data) ->
    %% 计算分片数量
    Len = byte_size(Data),
    Count =
        case Len =< Mss of
            true ->
                1;
            _ ->
                erlang:ceil(Len / Mss)
        end.

-spec recv(#kcp{}) -> {ok, #kcp{}, binary()} | {error, term()}.
recv(Kcp) ->
    todo.

-spec getopts(#kcp{}, list()) -> {ok, [{atom(), term()}]} | {error, term()}.
getopts(Kcp, Opts) ->
    todo.

-spec setopts(#kcp{}, [{atom(), term()}]) -> ok | {error, term()}.
setopts(Kcp, Opts) ->
    todo.

-spec output(#kcp{}) -> {ok, #kcp{}} | {error, term()}.
output(Kcp) ->
    todo.

-spec input(#kcp{}) -> {ok, #kcp{}} | {error, term()}.
input(Kcp) ->
    todo.

-spec update(#kcp{}, pos_integer()) -> {ok, #kcp{}} | {error, term()}.
update(Kcp, Current) ->
    todo.

-spec check(#kcp{}, pos_integer()) -> {ok, #kcp{}} | {error, term()}.
check(Kcp, Current) ->
    todo.

-spec flush(#kcp{}) -> {ok, #kcp{}} | {error, term()}.
flush(Kcp) ->
    todo.