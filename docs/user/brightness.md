# Brightness

Vibranium supports hardware brightness control out of the box.  
On laptops, it controls the internal display directly through the kernel. External monitors are supported through the [DDC](https://en.wikipedia.org/wiki/Display_Data_Channel) protocol.

Brightness can be adjusted using:

- the laptop's dedicated brightness keys
- ++super+shift+f10++ and ++super+shift+f11++

## External monitors

Vibranium controls external monitors using the [ddcutil](https://github.com/rockowitz/ddcutil) utility.  
Your monitor must support the DDC/CI protocol. Most monitors manufactured within the last two decades do.

DDC communication can be slow, especially on some GPU and monitor combinations. 
To reduce latency, Vibranium caches monitor information and performs a one-time calibration that determines the shortest stable DDC timings supported by the monitor.  
After calibration, brightness adjustments should feel comparable to those of an internal display.

## Laptop screen

Vibranium controls the internal laptop display through the kernel's sysfs backlight interface. Utilities such as `brightnessctl` are not used.  
Brightness values are written directly to the appropriate sysfs device exposed by the kernel.

## Negative brightness

Vibranium supports brightness values below 0% by reducing display gamma after the hardware backlight reaches its minimum level.

When hardware brightness reaches 0%, further decreases adjust gamma instead.  
The on-screen brightness indicator resets and displays the current gamma level rather than the hardware brightness level.

The minimum supported gamma level is **-90%**. Lower values would make the display effectively unusable.

!!! warning

    Some laptop firmware or display drivers completely disable the internal panel at very low hardware brightness levels (typically 0–1%).  
    This is hardware-specific behavior and cannot be prevented by Vibranium.
