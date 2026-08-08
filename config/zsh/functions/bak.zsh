
# bak: fast backup helper. Builtins only (plus cp). No subshells, no nested
# functions, nothing to clean up on exit or SIGINT.

function bak() {
  local usage='Usage: bak [OPTION]... FILE...

Create backups of FILEs and directories.

Options:
  -p, --prefix=PREFIX     prepend PREFIX to backup names
  -s, --suffix=SUFFIX     append SUFFIX to backup names
  -t, --timestamp         use a Unix timestamp as the suffix
  -H, --hidden            make backup names hidden
  -h, --help              display this help and exit

With no --suffix or --timestamp, ".bak" is appended to the name.
-s and -t are mutually exclusive; the last one given wins.

Examples:
  bak file.txt
  bak -p old- file.txt
  bak --suffix=.orig file.txt dir/
  bak --timestamp file.txt
  bak --hidden file.txt

Note: bak is a custom shell function, not a command.'

  local prefix= suffix=.bak timestamp= hidden=
  local opt arg c

  while (($#)); do
    case $1 in
      --)
        shift
        break
        ;;

      --help)
        printf '%s\n' "$usage"
        return 0
        ;;

      --prefix=* | --suffix=*)
        opt=${1%%=*}
        arg=${1#*=}
        if [[ $opt == --prefix ]]; then
          prefix=$arg
        else
          suffix=$arg
          timestamp=
        fi
        shift
        ;;

      --prefix | --suffix)
        (($# > 1)) || {
          printf '%s\n' "bak: option requires an argument -- '$1'" "$usage" >&2
          return 2
        }
        if [[ $1 == --prefix ]]; then
          prefix=$2
        else
          suffix=$2
          timestamp=
        fi
        shift 2
        ;;

      --timestamp)
        timestamp=1
        suffix=
        shift
        ;;

      --hidden)
        hidden=1
        shift
        ;;

      --*)
        printf '%s\n' "bak: unrecognized option '$1'" "$usage" >&2
        return 2
        ;;

      -?*)
        arg=${1#-}
        while [[ -n $arg ]]; do
          c=${arg:0:1}
          arg=${arg:1}
          case $c in
            h)
              printf '%s\n' "$usage"
              return 0
              ;;

            t)
              timestamp=1
              suffix=
              ;;

            H)
              hidden=1
              ;;

            p | s)
              if [[ -n $arg ]]; then
                opt=$arg
                arg=
              elif (($# > 1)); then
                opt=$2
                shift
              else
                printf '%s\n' "bak: option requires an argument -- '$c'" "$usage" >&2
                return 2
              fi
              if [[ $c == p ]]; then
                prefix=$opt
              else
                suffix=$opt
                timestamp=
              fi
              ;;

            *)
              printf '%s\n' "bak: invalid option -- '$c'" "$usage" >&2
              return 2
              ;;
          esac
        done
        shift
        ;;

      *)
        break
        ;;
    esac
  done

  if (($# == 0)); then
    printf '%s\n\n' 'bak: missing file operand' "$usage" >&2
    return 2
  fi

  if [[ $timestamp ]]; then
    zmodload zsh/datetime 2>/dev/null
    suffix=".$EPOCHSECONDS"
  fi

  local src dest name ret=0

  for src; do
    if [[ ! -e $src && ! -L $src ]]; then
      printf '%s\n' "bak: '$src': No such file or directory" >&2
      ret=1
      continue
    fi

    name=${src##*/}
    [[ $hidden ]] && name=".$name"
    dest="${prefix}${name}${suffix}"

    cp -a -- "$src" "$dest" || ret=1
  done

  return $ret
}
