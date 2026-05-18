As mentioned multiple times, Vibranium aims to be as lightweight as possible out of the box. However, you can set up certain components faster than the duration of the song *Rockstar* by *Post Malone*.

If you need to install and configure Docker, go to *Vibranium Menu* -> *Setup* -> *Docker*. The setup script doesn’t just install the `docker` package via `pacman`, it can also install additional utilities such as `docker-compose` and `lazydocker` (with your permission), properly configure networking for containers, and adjust firewall rules if [UFW](Docker%20Setup.md) is enabled.

If you try to run the setup again, the script will detect that Docker is already configured and provide further instructions instead.