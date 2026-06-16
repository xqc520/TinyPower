-- TinyPower 固件入口：只负责加载调度器、低功耗驱动和业务状态机。
PROJECT = "TinyNav"
VERSION = "1.0.0"

-- 加载 LuatOS 调度器，全项目的 sys.taskInit/sys.wait 都依赖它。
sys = require("sys")

-- 低功耗驱动启动时会注册 PSM+ 相关能力。
require "drv_psm"

log.info("main", "script start", PROJECT, VERSION)

-- 启动业务状态机：配网、定位、双路上报、低功耗都从 app.lua 进入。
require("app").start()

-- 交给 LuatOS 调度器运行，后续代码都在任务和事件里执行。
sys.run()
