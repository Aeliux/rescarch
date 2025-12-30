#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

# quality of life tweaks
shopt -s cdspell checkwinsize
HISTCONTROL=ignoredups:erasedups
HISTSIZE=10000
HISTFILESIZE=20000
HISTTIMEFORMAT='%F %T '

alias ll='ls -alF'
alias la='ls -A'

# colors
BOLD_GREEN=$'\e[1;32m'
BOLD_BLUE=$'\e[1;34m'
CYAN=$'\e[0;36m'
YELLOW=$'\e[1;33m'
RESET=$'\e[0m'

# capture the last command's exit status for the prompt
__prompt_command() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    PROMPT_EXIT="${YELLOW}[${status}]${RESET} "
  else
    PROMPT_EXIT=""
  fi
}
PROMPT_COMMAND=__prompt_command

# Only set the fancy prompt for interactive shells with colors
if [[ $- == *i* ]] && tput colors >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
  PS1=""
  # first line: user@host time [exitcode] cwd
  PS1+="\[$BOLD_GREEN\]\u@\h\[$RESET\] "         # user@host (bold green)
  PS1+="\[$BOLD_BLUE\]\A\[$RESET\] "            # HH:MM (bold blue)
  PS1+='$PROMPT_EXIT'                             # non-zero exit (colored)
  PS1+="\[$CYAN\]\w\[$RESET\]"                 # cwd (cyan)
  PS1+=$'\n'                                  # newline
  # second line: small glyph '»' in yellow
  PS1+="\[$YELLOW\]» \[$RESET\]"
fi
