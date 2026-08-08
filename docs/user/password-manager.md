# Password Manager

Vibranium provides a menu-based interface for users of [`pass`](https://passwordstore.org), the standard Unix password manager.
`pass` is not installed by default and must be installed separately.
The password manager can be opened with ++control+alt+p++.

## Password store location

At session startup, Vibranium sets `PASSWORD_STORE_DIR` according to the XDG Base Directory Specification.

By default, it points to `$XDG_DATA_HOME/password-store/`.  
The location can be changed from **Vibranium Menu -> Settings -> Misc -> Edit env**  
by overriding the `PASSWORD_STORE_DIR` [environment variable](environment-variables.md).

## Initialization

If no password store exists, Vibranium detects this and offers to initialize one.
If the password store is a Git repository, additional Git-related actions become available in the menu.
Git-backed stores also support automatic synchronization during session startup, keeping the local password store updated with its remote repository.
When new passwords created / edited (see below), the tool will automatically sync with the remote repo.

## Features

The menu interface supports common password store operations:

- create passwords
- delete passwords
- create folders
- copy passwords
- rename entries
- view entries
- edit entries

## Clipboard handling

Copied passwords are handled specially.  
After copying a password, it will not appear in normal clipboard history (++control+v++).  
However, it remains available for the intended paste operation.
