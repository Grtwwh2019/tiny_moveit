# MOVEit Automation Shell Runner

这是一个无第三方运行时 JAR 依赖的 MOVEit Automation 命令行程序。

Java 代码只负责：

1. 从 JAR 中释放内嵌 Shell 模块到临时目录。
2. 使用 `/bin/sh` 调用主 Shell 脚本并原样传递参数。
3. 将 Shell 的标准输出、标准错误和退出码原样返回给调用方。
4. 删除运行期间释放的临时脚本。

MOVEit 认证、任务检查、任务启动、结果轮询、日志和 JSON 输出全部由 Shell 实现。

## 运行要求

- Java 8 或以上版本
- POSIX Shell，默认 `/bin/sh`；兼容 Solaris 11.4
- `curl`
- 常见系统工具：`awk`、`cat`、`cut`、`date`、`dirname`、`egrep`、`mkdir`、`printenv`、`rm`、`sleep`、`tr`

程序不需要 Jackson、JUnit、`jq` 或任何其他第三方 JAR；构建和测试也不需要第三方 Java 库。

## 构建

```sh
mvn clean package
```

生成的单文件程序：

```text
target/moveit-task-runner-shell.jar
```

这个 JAR 已经包含所有 Shell 模块，不需要附带 `lib/` 或脚本目录。

运行无依赖集成测试：

```sh
mvn test-compile
java -cp target/test-classes:target/classes \
  com.example.moveit.MoveItTaskRunnerHarness
```

## 调用

```sh
export JAVA=/path/to/java
export JAVA_TOOLS=/path/to/java/tools
export MI_JAR=/path/to/moveit-task-runner-shell.jar
export HOST=10.10.10.20
export ID=api-user
export PW='your-password'
export TASKID=12345
export WAITTIME=3600
export TASK_LOGFILE=/var/log/moveit/task.xml
export STEPS_LOGFILE=/var/log/moveit/steps.xml
export DAT_REP_LOGFILE=/var/log/moveit/response.txt

"${JAVA}/bin/java" \
  -classpath "${JAVA_TOOLS}" \
  -jar "${MI_JAR}" \
  "-host:${HOST}" \
  "-user:${ID}" \
  "-password:${PW}" \
  "-startid:${TASKID}" \
  "-waitsecs:${WAITTIME}" \
  "-tf:${TASK_LOGFILE}" \
  "-sf:${STEPS_LOGFILE}" \
  "-rf:${DAT_REP_LOGFILE}" \
  -df:none \
  -D:60

java_rc=$?
success=`egrep -e 'ErrorCode: 0' "${DAT_REP_LOGFILE}"`

if [ -n "$success" ]; then
  echo "MOVEit transfer succeeded"
else
  echo "MOVEit transfer failed, rc=$java_rc"
fi
```

程序内部也执行同样的反引号检查：先写入 `-rf` 响应文件，再查找 `ErrorCode: 0`。只有找到该标记，Java 进程才返回退出码 `0`。

Shell 赋值语句的 `=` 两边不能有空格，双引号必须成对出现。通常不应在 `${DAT_REP_LOGFILE}` 后添加 `*`，否则可能同时匹配旧响应文件并造成误判。

Solaris 11.4 兼容处理：脚本不使用非 POSIX 的 `date +%s`，也不向 `dirname` 或 `cd` 传入 GNU 风格的 `--` 参数。等待超时通过 POSIX Shell 整数计数实现。

`-classpath` 是 Java 启动器参数；使用 `-jar` 时，本程序不依赖该 classpath，但可以保留以兼容现有调度脚本。

为了避免密码出现在 Shell 历史或进程列表中，推荐使用环境变量引用：

```sh
export MOVEIT_PASSWORD='your-password'

java -jar moveit-task-runner-shell.jar \
  -host:10.10.10.20 \
  -user:api-user \
  -password:env:MOVEIT_PASSWORD \
  -startid:12345 \
  -waitsecs:3600 \
  -tf:./task.xml \
  -sf:./steps.xml \
  -rf:./response.txt \
  -df:./debug.log \
  -D:60
```

## 参数

```text
-host:<server>                 MOVEit Automation Web Admin 地址或 IP
-user:<username>               API 用户名
-password:<value|env:VAR>      密码或密码环境变量引用
-startid:<taskId>              要启动的任务 ID
-waitsecs:<seconds>            等待任务完成的总秒数
-tf:<task.xml>                 任务总体结果 XML 文件
-sf:<steps.xml>                任务步骤/文件活动明细 XML 文件
-rf:<response.txt>             调用响应文件
-df:<debug.log|none>           调试日志文件；none 表示不生成
-D:<level>                     调试级别；0 仅错误，40 基本过程，60 较详细
--poll-seconds=5               查询任务结果的间隔
--connect-timeout-seconds=30   curl 建立连接的超时时间
--read-timeout-seconds=60      单次 curl 请求的最长时间
--server-host=automation-host  Web Admin 管理多个后端时指定 Automation Server
--secure                       恢复 TLS 证书及主机名验证
--insecure                     关闭 TLS 验证；2.1.3 中已是默认行为
```

前八个参数（从 `-host` 到 `-rf`）必填，顺序不限。其余参数可选。

## TLS 证书处理

从 2.1.3 开始，程序默认向 curl 传入 `--insecure`，因此现有调度命令不需要增加参数即可连接使用内部自签名证书的 MOVEit 服务器。此模式会关闭证书链和主机名验证，只应在受控网络中使用。

如果服务器证书链修复完成，可在原命令末尾增加 `--secure` 重新启用验证。

## Token 自动更新

程序读取认证响应中的 `expires_in`，并在 Token 到期前 5 秒自动重新认证。如果 MOVEit 提前拒绝 Token 并返回 HTTP 401，程序会立即申请新 Token，然后把原请求重试一次。Token 更新完全在内嵌 Shell 中完成，现有调度参数不需要改变。

`-rf` 使用兼容 MOVEit 命令行客户端的文本格式：

```text
ErrorCode: 0
ErrorDescription:
TaskID: 12345
TaskName: Daily Transfer
NominalStart: 2026-08-04 10:11:12.34
TimeEnded: 2026-08-04 10:11:14
```

如需指定其他 Shell，可设置：

```sh
export MOVEIT_SHELL=/usr/bin/bash
```

## Shell 模块

```text
shell/moveit-runner.sh  参数解析和流程编排
shell/lib/common.sh     HTTP、JSON、日志、输出和通用函数
shell/lib/auth.sh       MOVEit Token 认证
shell/lib/task.sh       任务检查和任务启动
shell/lib/report.sh     Task Runs 查询、轮询和结果判断
```

这些文件以资源形式内嵌在 JAR 中，运行时自动释放。

## 标准输出

成功：

```json
{"result":"SUCCESS","exitCode":0,"taskId":"12345","runId":"9876","nominalStart":"2026-08-04 10:11:12.34","status":"Success","statusCode":0,"filesSent":3,"totalBytesSent":1234,"message":"File transfer succeeded"}
```

失败：

```json
{"result":"FAILURE","exitCode":6,"message":"MOVEit task failed: Destination unavailable"}
```

## 退出码

| 退出码 | 含义 |
|---:|---|
| 0 | 文件传输成功 |
| 2 | 参数错误 |
| 3 | 认证失败 |
| 4 | 任务不存在或无权限 |
| 5 | 任务启动失败 |
| 6 | MOVEit 报告任务失败 |
| 7 | 等待任务完成超时 |
| 8 | 网络、HTTP 或响应格式错误 |
| 9 | Shell、日志或启动器内部错误 |

## MOVEit 端要求

- 地址应指向 MOVEit Automation Web Admin，而不是 Transfer WebUI。
- Web Admin 必须启用 REST API。
- API 用户需要读取及启动目标任务、读取 Task Runs 报告的权限。
