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
- POSIX Shell，默认 `/bin/sh`
- `curl`
- 常见系统工具：`awk`、`cat`、`cut`、`date`、`dirname`、`mkdir`、`printenv`、`rm`、`sleep`、`tr`

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
export MOVEIT_PASSWORD='your-password'

java -jar moveit-task-runner-shell.jar \
  https://10.10.10.20 \
  api-user \
  env:MOVEIT_PASSWORD \
  12345 \
  /var/log/moveit/task-12345.log

rc=$?
if [ "$rc" -eq 0 ]; then
  echo "MOVEit transfer succeeded"
else
  echo "MOVEit transfer failed, rc=$rc"
fi
```

也可以直接传密码，但密码可能出现在 Shell 历史或进程列表中：

```sh
java -jar moveit-task-runner-shell.jar \
  https://10.10.10.20 api-user 'your-password' 12345 ./moveit.log
```

## 可选参数

```text
--timeout-seconds=3600         等待任务最终结果的总时间
--poll-seconds=5               查询任务结果的间隔
--connect-timeout-seconds=30   curl 建立连接的超时时间
--read-timeout-seconds=60      单次 curl 请求的最长时间
--server-host=automation-host  Web Admin 管理多个后端时指定 Automation Server
--insecure                     关闭 TLS 证书及主机名验证，仅用于受控测试环境
```

可选参数放在五个必填参数之后：

```sh
java -jar moveit-task-runner-shell.jar \
  https://10.10.10.20 api-user env:MOVEIT_PASSWORD 12345 ./moveit.log \
  --timeout-seconds=1800 \
  --poll-seconds=10
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
