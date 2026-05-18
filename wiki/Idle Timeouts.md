Hypridle is a lightweight background service that automatically locks your session and puts your PC to sleep after a period of inactivity.

The default timeout values differ depending on the machine type. Laptops use shorter timeouts, while desktops and virtual machines use longer ones. This decision is based on privacy and security considerations: with a laptop, you may be in public or away from your device, where leaving it unattended even briefly could have consequences.

With this in mind, the default values are:

- **Laptops**
  - Session lock: 2 minutes
  - Sleep: 5 minutes

- **Desktop PCs / VMs**
  - Session lock: 10 minutes
  - Sleep: 15 minutes

You can change these timeouts at any time via *Vibranium Menu* (`CTRL ALT V`) -> *Settings* -> *Idle*.

In the same menu, you’ll also find an option called *Inhibit type*, which has two possible values: `sleep` and `idle`. These are used by the sleep inhibitor, which can be toggled from the utilities menu (`CTRL ALT U`).

The selected type determines what gets inhibited:

- `sleep` - Your session will still lock normally, but the PC will never enter sleep mode automatically.

- `idle` - Your session will never be locked automatically.

Of course, these only apply while the inhibitor itself is active.