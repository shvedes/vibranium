# Introduction

As mentioned on the [Home Page](Home.md), Vibranium shares many similarities with Omarchy, particularly in project structure. While that is true, it is still very different, not only in implementation but, more importantly, in philosophy.

For comparison, Omarchy tries to adjust and fine-tune everything for you, hence the *Oma* part in the name. Everything is preselected. Vibranium, on the other hand, aims to include only the necessary components and remain as minimal as possible out of the box, leaving further customization and additional setup to the end user (see [Additional Setups](Additional%20Setups.md)). In other words, Vibranium gives you the basics, the foundation for what you can build on top of it.

## Why Vibranium isn't an OS

Because, by definition, it cannot be. You cannot call a collection of configs (at its core, it really is a set of configuration files tied together with shell scripts) an entire OS, right, DHH? You can call it dotfiles (although not in the traditional sense), or a setup, but not an OS.

I don’t want to decide how to partition **your** disk or whether to encrypt it. What if it's a desktop and not a laptop? The encryption will make your *Desktop PC* slower than it used to be for no reason. I don't get it. I don’t want to install packages for you, and I certainly don’t want to promote anything to you, even if I’m the author of *something*. It just doesn’t feel right.

Vibranium is a configuration built on Arch Linux, an operating system for **advanced users**. I can count dozens, if not hundreds, of issues in the Omarchy repository where users broke something simply because they didn’t fully understand what they were doing. And I don’t blame them. DHH’s influence and his ability to make things sound appealing to a broad audience do the rest.

That being said, you are responsible for your base OS. This includes:
- Disk partitioning
- Disk encryption
- System maintenance (it’s still Arch, remember)
- Any other low-level aspects

Vibranium is simply a self-maintained, easy-to-use runtime. I do not recommend installing it if you are not familiar with Arch, AUR, `mkinitcpio`, managing a bootloader, and related tools. You can try, though.
## Performance

Internally, it’s quite complex, arguably more than it might seem. Even so, Vibranium aims to be as fast as possible, all things considered. This comes down to how the scripts are written.

The core idea is to minimize the use of external commands. It’s not so much about how “heavy” a program is, but what it takes to launch it: a syscall, a process exec. Instead, the focus is on shell built-ins, avoiding command substitution and subshells wherever possible. Each small optimization may seem insignificant on its own, but at scale, it adds up.

Because of this, Vibranium is generally faster than you might expect, while still remaining very capable.