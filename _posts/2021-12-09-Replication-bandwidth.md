---
typora-root-url: F:\markdown\image_videos
---


# 网络模块基础概念
### UNetDriver
- 两个实例子类
 + UIpNetDriver 负责标准网络连接
 + UDemoNetDriver 负责录制回放

- UNetDriver管理UNetConnections, DS拥有ClientConnections，客户端拥有ServerConnection
- RPC相关在这里处理：
	+ UNetDriver::ProcessRemoteFunction() 
	+ UNetDriver::ProcessRemoteFunctionForChannel()
- UNetDriver::TickDispatch负责接收网络数据，通过UNetConnection::ReceivedRawPacket将数据包传递到对应的连接中

### UNetConnection
#### 标准连接：UIpConnection

### UChannel
- UControlChannel
用于发送有关连接状态的信息
- UVoiceChannel
用于在客户端和服务器之间发送语音数据
- UActorChannel
交换角色及其子对象的属性和RPC的通道，UActorChannel管理复制的actor的创建和生存期。

# Replication收发包过程
## 收包
```mermaid
graph TD
	  Start((收包)) --> A(UIpNetDriver::TickDispatch)
    A -->| 读取原始packet数据 | B(UNetConnection.ReceivedRawPacket)
    B -->| 对齐标记位, 解析packet数据 | C(UNetConnection::ReceivedPacket)
    C -->| 去掉PacketHeader, 分发Bunch到Channel | D(UChannel.ReceivedRawBunch)
    D --> E{在reliable信道且不是顺序包}
	   E -->| 是 | F(缓存起来, 等待正确的包)
	   E -->| 否 | G(UChannel::ReceivedNextBunch)
	   G -->| 组装出完整Bunch | H(UChannel::ReceivedSequencedBunch)
	   H -->| rpc和属性复制 | I(UActorChannel::ReceivedBunch)
	   H -->| 连接控制状态信息 | J(UControlChannel::ReceivedBunch)
	   H -->| 语音通讯 | K(UVoiceChannel::ReceivedBunch)
	   subgraph 分发到不同的Channel
		   I(UActorChannel::ReceivedBunch)
		   J(UControlChannel::ReceivedBunch)
		   K(UVoiceChannel::ReceivedBunch)
	   end
```

-------
## 发包
```mermaid
graph TD
	Start((发包)) --> A(UIpNetDriver::TickFlush)
    A --> B(UNetDriver::ServerReplicateActors)
	B --> C{是否启用了ReplicationGraph}
	C --> | 是 | C_Begin(UReplicationGraph::ServerReplicateActors)
	       subgraph 以BaseReplicationGraph为例
				C_Begin(UBasicReplicationGraph::ServerReplicateActors)
				C_Begin --> C1(UReplicationGraph::ServerReplicateActors)
				C1 --> C2(UReplicationGraph::ReplicateActorListsForConnections_Default<br><br>: 通过IsConnectionReady检查带宽预算)
				C2 --> C_End(UReplicationGraph::ReplicateSingleActor)
		   end
	   C_End --> D(UActorChannel::ReplicateActor)
	   C --> | 否 | C_F(ServerReplicateActors_ProcessPrioritizedActors)
	     subgraph 按优先级排序后逐个Rep
		 C_F(ServerReplicateActors_ProcessPrioritizedActors<br><br>: 通过IsNetReady检查带宽预算)
		 end
	   C_F --> D(UActorChannel::ReplicateActor)
	   D --> E(UChannel::SendBunch)
       E --> | Bunch分片 | F(UChannel::SendRawBunch)
       F --> | | G(UNetConnection::SendRawBunch)
       G --> | 添加BunchHeader | H(UNetConnection::WriteBitsToSendBufferInternal)
	   H -.-> | 写入发送缓存 | I>UNetConnection.SendBuffer]
	   TA(UNetConnection::Tick) -.-> | 读取发送缓存 | I
	   TA --> J(UNetConnection::FlushNet)
       J --> | 发送packet数据 | K(UIpConnection::LowLevelSend)
```



# Network Profile
## UNetConnection的统计
|   UNetConnection    | 上行              | 下行             | 备注             |
| ------------------ | ------------------- | ------------------ | ---- |
| 每秒内流量(Bytes) | OutBytesPerSecond | InBytesPerSecond | 实际压缩后的数据，且包括包头 |
| 每秒内包个数(Pack) | OutPacketsPerSecond | InPacketsPerSecond | 单个packet大小受MTU限制 |

## Network Insight的统计
![preview](/../../../image_videos/net_insight.jpg) 



# Replication的限流

## 发送速率

- 发送数据，每个UNetConnection有一个数据发送速率`CurrentNetSpeed`，表示每秒钟可以发送多少字节数据

### UE4的发送速率配置
DefaultEngine.ini

- 最大速率
  - [/Script/OnlineSubsystemUtils.IpNetDriver]
    MaxClientRate=100000
    MaxInternetClientRate=100000  // 非局域网条件下的MaxClientRate配置

- 实际速率`CurrentNetSpeed`
  - [/Script/Engine.Player]
    ConfiguredInternetSpeed=100000
    ConfiguredLanSpeed=100000

- 实际速率受最大速率限制，最小为1800

- 客户端、ds端的发送速率都由这些配置决定

## 带宽预算

- 发送数据，每个UNetConnection有带宽预算`UNetConnection.QueuedBits`，小于0，表示这一帧还可以发送多少bit数据 
- **带宽预算**受到**发送速率**的影响

### 带宽预算的分配和消耗
UNetConnection::Tick里根据CurrentNetSpeed计算分配当前的带宽预算，由于预算可以累积，为了避免过多的预算可能导致下一帧发送太多数据，预算钳制在两倍范围内
```c++
void UNetConnection::Tick(float DeltaSeconds)
{
	...
	float DeltaBits = CurrentNetSpeed * BandwidthDeltaTime * 8.f;
	QueuedBits -= FMath::TruncToInt(DeltaBits);
	float AllowedLag = 2.f * DeltaBits;
	if (QueuedBits < -AllowedLag)
	{
		QueuedBits = FMath::TruncToInt(-AllowedLag);
	}
}
```

UNetConnection::FlushNet里面，发送了多少数据，会消耗掉预算
```c++
void UNetConnection::FlushNet(bool bIgnoreSimulation)
{
	...
	QueuedBits += (PacketBytes * 8);
}
```
### 带宽预算检查
- 有ReplicationGraph时，通过UReplicationGraph::IsConnectionReady检查带宽预算
  + 可以通过命令`Net.RepGraph.DisableBandwithLimit 1`动态关闭预算检查，任性地使用网络流量带宽
- 没有ReplicationGraph时，通过UNetConnection::IsNetReady检查带宽预算
  + 可以通过命令`net.DisableBandwithThrottling 1`动态关闭预算检查，任性地使用网络流量带宽（非shipping版本有效）

带宽预算不足时，发送会延后。



# 带宽优化

## ReplicationGraph

- 启用插件ReplicationGraph

- 两种方式开启ReplicationGraph

1. 配置

   [/Script/OnlineSubsystemUtils.IpNetDriver]

   ReplicationDriverClassName="/Script/ReplicationGraph.BasicReplicationGraph"

2. 代码里注册

   在UNetDriver::InitBase前注册一下ReplicationGraph
```c++
UReplicationDriver::CreateReplicationDriverDelegate().BindLambda([](UNetDriver* ForNetDriver, const FURL& URL, UWorld* World) -> UReplicationDriver*
{
	return NewObject<UReplicationDriver>(GetTransientPackage(), UYouDerivedReplicationGraph::StaticClass());
});
```

- Adaptive Network Update Frequency

  By default, this feature is deactivated. Setting the console variable `net.UseAdaptiveNetUpdateFrequency` to `1` will activate it.



## Oodle Network

https://docs.unrealengine.com/4.27/en-US/TestingAndOptimization/Oodle/Network/

tips：
1. 需要离线训练，生成字典文件，游戏涉及较大更新时，可能需要重新训练并生成新的字典文件，再发布打包；
2. 字典文件在server端 / client端都分别需要。
3. 占用内存

## PropertyHandle合并

![img](/../../../image_videos/propery_handle.png)

​		每个PropertyHandle都会占用8bit，将多个property字段合并为一个struct，整体做NetSerialize，可以减少PropertyHandle占用，但需要注意的是，这可能也导致发生同步属性变化的几率会增加（struct里面有任何变化，整体就被认为需要传输），需要综合权衡，把一起变化的字段放到一起合并为struct。

http://www.aclockworkberry.com/custom-struct-serialization-for-networking-in-unreal-engine/