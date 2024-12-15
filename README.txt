== pages-src: generates refs/heads/pages ==

we are using carmel (cpanfile) to manage perl deps!
run `carmel install' before you start, then prefix
all perl commands with `carmel exec'
(`carmel export' and `carmel env' seem to help too,
although they are not documented)

for vimers: copying this out of vimrc in case it is
useful: alias vim="vim -u $(realpath vim/vimrc)"
