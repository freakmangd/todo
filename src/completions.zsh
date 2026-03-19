#compdef tak

_tak() {
    local -a completions
    completions=("${(@f)$(tak completions zsh)}")
    _describe 'commands' completions
}

_tak
