Vibranium does not come with a preconfigured firewall, but it provides a simple way to set one up. To begin, go to *Vibranium Menu* -> *Setup* -> *Firewall*.

The setup process is fully automated and takes only a few seconds. The script installs [UFW](https://en.wikipedia.org/wiki/Uncomplicated_Firewall) as the firewall backend and configures it based on your system.

As a baseline, it applies a straightforward default policy: allow outgoing traffic, deny incoming traffic, and allow all connections from the local network (LAN). After that, the script detects what is installed on your system and adjusts the rules accordingly. This includes existing Docker and QEMU setups.

This step is important because even the default UFW configuration can block network access for virtual machines and Docker containers, which is usually not what you want.

Once the setup is complete, you’ll see a summary of the changes along with guidance on what to do next.

![](ufw_complete.jpeg)