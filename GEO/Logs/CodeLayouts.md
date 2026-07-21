## Old Board

OldBoard/
├── drone_control.ioc          # CubeMX config
├── STM32H743VGTX_FLASH.ld / _RAM.ld
├── Core/
│   ├── Inc/
│   ├── Src/
│   │   ├── main.c, freertos.c, gpio.c, dma.c, tim.c, usart.c, i2c.c, spi.c, adc.c, rng.c, rtc.c, fdcan.c
│   │   ├── stm32h7xx_hal_msp.c / _it.c / system_stm32h7xx.c   (standard HAL boilerplate)
│   │   ├── VolvoPenta.c            ← app: engine protocol
│   │   ├── nmea2000.c               ← app: NMEA2000 over FDCAN
│   │   ├── modbus_map.c             ← app: Modbus register mapping
│   │   ├── modbus_tcp_client.c      ← app: Modbus TCP client
│   │   ├── ops-modbus.c             ← app: glue between Modbus and the rest
│   │   ├── ops-ethernet.c           ← app: LWIP/ethernet setup
│   │   ├── ops-application-task.c   ← app: top-level FreeRTOS task
│   │   └── ops-tools.c              ← app: misc helpers
│   └── Startup/
├── Dekimo_HAL/        # custom/vendor HAL extensions
├── Drivers/           # CMSIS + STM32H7xx_HAL_Driver
├── FreeModbus/         # Modbus protocol stack (separate from modbus_tcp_client.c — likely the underlying library)
├── LWIP/               # TCP/IP stack
├── Middlewares/         # FreeRTOS, etc.
├── USB_DEVICE/
└── images/, README.md

Everyting app-side in Core/Src/
No web UI
Single-purpose firmware (drone bridge/Volvo Penta Engine + NMEA2000 + Modbus TCP)





## New Board

NewBoard/MFCB_BASE/
├── CM7/                          # Cortex-M7 project (likely network/web/UI/app-heavy core)
│   ├── Core/Inc, Core/Src, Core/Startup, Core/ThreadSafe
│   ├── Customer/
│   │   ├── Customer.c / .h          ← YOUR app code goes here
│   │   └── customer_examples.c/.h   ← vendor usage examples
│   ├── OPS_Lib/
│   │   ├── libops.a                 ← precompiled vendor firmware library
│   │   └── include/                 ← public API headers (see below)
│   ├── Drivers/STM32H7xx_HAL_Driver
│   ├── FATFS/, USB_DEVICE/, USB_HOST/, LIBJPEG/, MBEDTLS/, Middlewares/
│   └── Debug/  (build output, incl. TempOPS/ — synced copy of OPS source for build)
├── CM4/                          # Cortex-M4 project, same shape minus USB_HOST/LIBJPEG/MBEDTLS
│   ├── Core/, Customer/, OPS_Lib/, Drivers/, FATFS/, Middlewares/, Debug/
├── .cursor/rules/                 # dev rules: edit only OPS/, core-transparent API pattern, no Python
├── .vscode/, .metadata/, .project, .cproject
