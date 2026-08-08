
#####################################################
#                      Typos                        #
#####################################################

# ls
abbr --add sl ls

# cd
abbr --add dc cd
abbr --add cd.. "cd .."
abbr --add cd... cd ../..
abbr --add cd.... cd ../../..

# clear
abbr --add clearr clear
abbr --add cleart clear
abbr --add clera clear
abbr --add clea clear

# exit
abbr --add exti exit

# sudo
abbr --add sudp sudo
abbr --add suod sudo
abbr --add sduo sudo

# mkdir
abbr --add mkidr mkdir

# grep
abbr --add grpe grep
abbr --add gerp grep

# pacman
abbr --add pacamn pacman
abbr --add apcman pacman

# git
abbr --add gti git
abbr --add gi git
abbr --add gt git
abbr --add gtiu git
abbr --add gut git

# docker
abbr --add dokcer docker
abbr --add dockr docker
abbr --add dockre docker

# podman
abbr --add podamn podman
abbr --add pdoman podman

# kubernetes
abbr --add kubecrl kubectl
abbr --add kubelt kubectl

# systemctl
abbr --add systemclt systemctl
abbr --add systmectl systemctl
abbr --add sc        systemctl
abbr --add scu       systemclt --user

# curl
abbr --add crul curl
abbr --add clur curl

# nginx
abbr --add ngix nginx
abbr --add nginix nginx

# ffmpeg
abbr --add ffmepg ffmpeg
abbr --add fmpeg ffmpeg

#####################################################
#                  Conventionals                    #
#####################################################

# bash-compat: "!!" repeats the last command, also works
# after prefixes like sudo (see `help abbr` for the pattern)
function __fish_abbr_last_history_item
    echo $history[1]
end

abbr --add "!!" --position anywhere --function __fish_abbr_last_history_item

# clear / exit / history
abbr --add cl  clear
abbr --add q   exit
abbr --add h   history

# disk usage
abbr --add du1 "du -h --max-depth=1"

#####################################################
# git (https://github.com/ohmyzsh/ohmyzsh/wiki/Cheatsheet)
# NOTE: gt/gc conflicts are covered by the typos above.
#####################################################

abbr --add g    git
abbr --add ga   git add
abbr --add gaa  "git add --all"
abbr --add gap  "git add --patch"
abbr --add gc   "git commit -v"
abbr --add gca  "git commit -v -a"
abbr --add "gc!" "git commit --amend"
abbr --add gcm  "git commit -m"
abbr --add gco  git checkout
abbr --add gcb  "git checkout -b"
abbr --add gd   "git diff"
abbr --add gds  "git diff --staged"
abbr --add gf   "git fetch --all --prune"
abbr --add gl   git pull
abbr --add glg  "git log --oneline --graph --decorate --all"
abbr --add glo  "git log --oneline --decorate"
abbr --add gm   git merge
abbr --add gp   git push
abbr --add gpf  "git push --force-with-lease"
abbr --add gpl  git pull
abbr --add gpr  "git pull --rebase"
abbr --add gr   "git remote -v"
abbr --add grb  git rebase
abbr --add gs   "git status --short --branch"
abbr --add gst  "git status"
abbr --add gss  "git status --short"
abbr --add gsh  git show
abbr --add gsta "git stash"
abbr --add gstl "git stash list"
abbr --add gb   git branch
abbr --add gcl  git clone
abbr --add gwip "git add -A; git commit -m 'WIP'"

#####################################################
# docker (dc is taken by the cd typo above)
#####################################################

if command -v docker > /dev/null
    abbr --add d    docker
    abbr --add dco  "docker compose"
    abbr --add dps  "docker ps"
    abbr --add dpsa "docker ps -a"
    abbr --add di   "docker images"
    abbr --add dl   "docker logs -f"
    abbr --add dex  "docker exec -it"
    abbr --add db   "docker build"
    abbr --add drun "docker run -it --rm"
    abbr --add drmi "docker rmi"
end

#####################################################
# npm
#####################################################

if command -v npm > /dev/null
    abbr --add ni  "npm install"
    abbr --add nid "npm install --save-dev"
    abbr --add nrd "npm run dev"
    abbr --add nrb "npm run build"
    abbr --add ns  "npm start"
    abbr --add nt  "npm test"
end

#####################################################
# python & friends
#####################################################

if command -v python3 > /dev/null
    abbr --add py    python3
    abbr --add serve "python3 -m http.server"
end

#####################################################
# tmux
#####################################################

if command -v tmux > /dev/null
    abbr --add tm "tmux new-session -A -s main"
end

#####################################################
# network
#####################################################

if command -v ip > /dev/null
    abbr --add ipa "ip -br addr"
    abbr --add ipl "ip -br link"
end
