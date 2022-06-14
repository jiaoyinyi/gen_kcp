%%%-------------------------------------------------------------------
%%% @author jiaoyinyi
%%% @copyright (C) 2022, <COMPANY>
%%% @doc kcp interface
%%% @end
%%%-------------------------------------------------------------------
-module(kcp).

%% API
-export([
    open/2, open/4
    , close/1
    , connect/3
    , send/2, send/3
    , async_send/2, async_send/3
    , recv/1, recv/2
    , async_recv/1, async_recv/2
    , getopts/2
    , setopts/2
    , get_socket/1
]).

%% @doc 创建kcp socket
-spec open(pos_integer(), pos_integer()) -> {ok, pid()} | {error, term()}.
open(Port, Conv) ->
    gen_kcp:open(Port, Conv).

%% @doc 创建kcp socket
-spec open(pos_integer(), pos_integer(), list(), list()) -> {ok, pid()} | {error, term()}.
open(Port, Conv, UdpOpts, KcpOpts) ->
    gen_kcp:open(Port, Conv, UdpOpts, KcpOpts).

%% @doc 关闭kcp socket
-spec close(pid()) -> ok | {error, term()}.
close(Pid) ->
    gen_kcp:close(Pid).

%% @doc 连接，与对端ip、端口绑定
-spec connect(pid(), inet:ip_address(), inet:port_number()) -> ok | {error, term()}.
connect(Pid, Ip, Port) ->
    gen_kcp:connect(Pid, Ip, Port).

%% @doc 阻塞式发送数据
-spec send(pid(), binary()) -> ok | {error, term()}.
send(Pid, Packet) ->
    gen_kcp:send(Pid, Packet).

-spec send(pid(), binary(), timeout()) -> ok | {error, term()}.
send(Pid, Packet, Timeout) ->
    gen_kcp:send(Pid, Packet, Timeout).

%% @doc 非阻塞式发送数据 异步消息 {kcp_reply, pid(), reference(), ok | {error, reason()}}
-spec async_send(pid(), binary()) -> {ok, reference()} | {error, term()}.
async_send(Pid, Packet) ->
    gen_kcp:async_send(Pid, Packet).

-spec async_send(pid(), binary(), timeout()) -> {ok, reference()} | {error, term()}.
async_send(Pid, Packet, Timeout) ->
    gen_kcp:async_send(Pid, Packet, Timeout).

%% @doc 阻塞式接收数据
-spec recv(pid()) -> {ok, binary()} | {error, term()}.
recv(Pid) ->
    gen_kcp:recv(Pid).

-spec recv(pid(), timeout()) -> {ok, binary()} | {error, term()}.
recv(Pid, Timeout) ->
    gen_kcp:recv(Pid, Timeout).

%% @doc 非阻塞式接收数据 异步消息 {kcp, pid(), reference(), {ok, binary()} | {error, reason()}}
-spec async_recv(pid()) -> {ok, reference()} | {error, term()}.
async_recv(Pid) ->
    gen_kcp:async_recv(Pid).

-spec async_recv(pid(), timeout()) -> {ok, reference()} | {error, term()}.
async_recv(Pid, Timeout) ->
    gen_kcp:async_recv(Pid, Timeout).

%% @doc 获取kcp参数
-spec getopts(pid(), [Opt]) -> {ok, [{Opt, Val}]} | {error, term()} when
    Opt :: gen_kcp:option(),
    Val :: term().
getopts(Pid, Opts) ->
    gen_kcp:getopts(Pid, Opts).

%% @doc 设置kcp参数
-spec setopts(pid(), [{Opt, Val}]) -> ok | {error, term()} when
    Opt :: gen_kcp:option(),
    Val :: term().
setopts(Pid, Opts) ->
    gen_kcp:setopts(Pid, Opts).

%% @doc 获取socket
-spec get_socket(pid()) -> {ok, port()} | {error, term()}.
get_socket(Pid) ->
    gen_kcp:get_socket(Pid).