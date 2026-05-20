PROJECT = "TinyNav"
VERSION = "1.0.0"

-- LuatOS 任务框架，最后必须 sys.run()
sys = require("sys")


-- 业务入口：配网窗口 -> 定位 -> 上报 -> 休眠
require("app").start()

sys.run()
