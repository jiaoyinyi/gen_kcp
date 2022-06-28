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
TODO
```

### 测试
```
TODO
```