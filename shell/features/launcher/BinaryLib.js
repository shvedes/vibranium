.pragma library
// Pure rules behind the binary-launch fallback: what a query may name, how the
// executable set on PATH is indexed, and the two lines the row paints. No Qt
// import, no api, no PATH - every function here is a total function of its
// arguments, which is what makes the claim drivable from a suite with no
// engine, no policy view and no filesystem.
//
// The plugin that uses this carries a byte-identical copy of the block below,
// because its main.js is EVALUATED AS TEXT (see PluginInstance.qml) and cannot
// import a library the way a QML module can. This file and that one are one
// source with two homes; the launcher suite compares the two copies line for
// line, so an edit to either is a visible diff in the other.

// The one character that forces a binary claim past a desktop entry already
// matching the same name. It is stripped before the lookup, so "thunar" and
// "!thunar" resolve through the same index and the escape changes only
// whether the launcher asks, never what it finds.
var FORCE_PREFIX = "!"

// What one executable on PATH can be named. The claim is a whole-token
// equality test against the executable set rather than a search, so this is
// the whole of what can ever match: no path separator, no whitespace, and no
// shell metacharacter that would need quoting to survive a launch. A query
// carrying one is not a binary name and is refused here rather than looked up
// and missed.
var NAME_RE = /^[A-Za-z0-9._+-]+$/

// The executable name the live query asks for, or "" when it asks for none.
// A leading FORCE_PREFIX is one escape rather than a mode: the plugin answers
// the same row either way, and only the launcher's gate reads the difference.
// Lowercased name -> the on-disk spelling, so the query is matched the way the
// launcher searches (case-insensitively) while the launched argv keeps the
// real name. Object.create(null) because PATH can hold a binary called
// "constructor" or "toString", and an inherited property would answer for it
// as though the name were installed.
//
// First spelling wins on a duplicate: the scan prints in PATH order, and that
// is the directory a launch would resolve the name to. Case variants are NOT
// duplicates here - LS and ls are two different files on a case-sensitive
// filesystem, and the first one PATH reaches is the one a launch would run.
// The installed spelling of `name`, or "" when PATH holds no such binary.
// The two lines the row paints. The label names the command and the sub says
// what accepting it does, which is the one thing a bare binary name cannot say
// for itself: that this runs a program rather than opening a desktop entry.
// Binary-launch plugin for AppLauncher: offers a program on PATH when the
// query IS that program's name.
//
// Silent by construction. A plugin with a keyword can be entered as a mode;
// this one declares an empty one, so there is no prefix to type and no way to
// summon it directly. It is reached only by claiming - and what it claims is
// the fallback slot, the single synthetic row the launcher shows when nothing
// local matched. So the shape of the feature is: "qt6c" offers the web search,
// and the moment the query becomes "qt6ct" that same row reads "Launch qt6ct"
// instead. Nothing is added to the list; one row changes.
//
// A desktop entry always wins that slot, because a matching entry keeps the
// app pool non-empty and the fallback is only consulted when the pool is empty
// - "thunar" stays "File Manager", "spotify" stays "Spotify". The "!" prefix
// is the way past it: "!thunar" forces the claim the entry would otherwise take
// away, and the row goes to the top of the list so Enter reaches it directly.
//
// The executable set comes from the launcher, never from this file: PATH
// changes with every package install, and a shipped list would be wrong the day
// after it was written. The pair of capabilities that carries it is
// requestBinaries/cachedBinaries (see PluginPolicy.js) - ask for a rescan, read
// what landed - and a plugin denied the request half simply reads the cache
// the launcher already filled, which is why cachedBinaries is a default grant
// and only the request is a privilege.

