On Linux, setting up Secure Boot has always been a pain. With Vibranium, it doesn’t have to be.

Before proceeding, you only need to do one thing: put your UEFI firmware into Setup Mode. This will remove any previously enrolled keys from other bootloaders. The exact steps vary between motherboard manufacturers, so you’ll need to look up instructions for your specific model. If you don’t know your motherboard name, the `hostnamectl` command can help.

Once your UEFI is in Setup Mode, go to *Vibranium Menu* -> *Setup* -> *Secure Boot*. When prompted by the setup script, type `y` or press Enter, then wait a few seconds. That’s it.

After completion, the script will check your motherboard for known security vulnerabilities. If any are found, you’ll be notified with links and further instructions.

Finally, the setup script will ask you to reboot. After rebooting, Vibranium will verify that everything was configured correctly and notify you of the result.

![](sboot_complete.jpeg)