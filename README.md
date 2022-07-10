KCP erlang实现
======================================

### 模块

1. prim_kcp.erl
   > kcp原语模块
2. gen_kcp.erl
   > 使用进程封装kcp模块
3. kcp.erl
   > kcp接口模块

### 使用

```
%% 创建
{ok, SockPid} = kcp:open(Port, Conv).
{ok, SockPid} = kcp:open(Port, Conv, UdpOpts, KcpOpts).

%% 连接，与对端ip、端口绑定
ok = kcp:connect(SockPid, Ip, Port).

%% 阻塞式发送数据
ok = kcp:send(SockPid, Packet).

%% 非阻塞式发送数据 异步消息 {kcp_reply, pid(), ref(), ok | {error, reason()}}
{ok, Ref} = kcp:async_send(SockPid, Packet).

%% 阻塞式接收数据
{ok, Packet} = kcp:recv(SockPid).
{ok, Packet} = kcp:recv(SockPid, Timeout).

%% 非阻塞式接收数据 异步消息 {kcp, pid(), ref(), {ok, binary()} | {error, reason()}}
{ok, Ref} = kcp:async_recv(SockPid).
{ok, Ref} = kcp:async_recv(SockPid, Timeout).

%% 关闭kcp进程
ok = kcp:close(SockPid).

%% 获取kcp参数
{ok, OptKeyVals} = kcp:getopts(SockPid, Opts).

%% 设置kcp参数
ok = kcp:setopts(SockPid, OptKeyVals).

%% 获取udp socket
{ok, Socket} = kcp:get_socket(SockPid).
```

### kcp参数

```
nodelay
是否启动nodelay模式，默认0不启用，1表示启用。

interval
内部工作的轮询时间，单位毫秒。

fastresend
快速重传模式，默认0关闭，设置n，则n次ACK跨越将会直接重传。

nocwnd
是否关闭流控，默认是0不关闭，1代表关闭。

snd_wnd
最大发送窗口，默认为32，单位是包。

rcv_wnd
最大接收窗口，默认为128，单位是包。

mtu
默认为1400字节，该值将会影响数据包归并及分片时候的最大传输单元

minrto
最小RTO的限制。

waitsnd
待发送数据长度，snd_buf + snd_queue 的长度。
```

### 测试
每20毫秒发送20个108个字节数据  
kcp测试参数：{snd_wnd, 1024}, {rcv_wnd, 1024}, {nodelay, 1}, {fastresend, 2}, {nocwnd, 1}, {minrto, 10}, {interval, 5}  
tcp测试参数：{nodelay,true}, {delay_send,false}

协议 | 丢包/延迟 | 10ms | 50ms | 100ms | 200ms
---|---|------|---|-------|---
kcp | 0% | 22ms | 102ms | 202ms   | 488ms
tcp | 0% | 21ms   | 101ms | 201ms   | 401ms
kcp | 5% | 51ms   | 302ms | 697ms   | 1377ms
tcp | 5% | 242ms  | 363ms | 1149ms  | 2275ms
kcp | 10% | 71ms   | 399ms | 815ms   | 1919ms
tcp | 10% | 504ms  | 514ms | 1332ms  | 3513ms
kcp | 20% | 106ms  | 525ms | 1154ms  | 5173ms
tcp | 20% | 1017ms | 7114ms | 3436ms | 33210ms