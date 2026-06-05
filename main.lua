PROJECT = "TinyNav"
VERSION = "1.0.0"

-- Load LuatOS scheduler.
sys = require("sys")

require "drv_psm"

log.info("main", "script start", PROJECT, VERSION)

-- Start the application state machine.
require("app").start()
-- Hand control to LuatOS.
sys.run()
