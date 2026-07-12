# !! Contents within this block are managed by 'forge fish setup' !!
# !! Do not edit manually - changes will be overwritten !!

# fish >= 4 emits its own OSC-133 prompt marks; disable them so the forge
# plugin is the sole OSC-133 emitter. Additive + non-destructive: only append
# the feature flag when it is not already present.
if not contains -- no-mark-prompt $fish_features
    set -Ux fish_features $fish_features no-mark-prompt
end

# Load forge shell plugin (commands, completions, keybindings) if not already loaded
if not set -q _FORGE_PLUGIN_LOADED
    forge fish plugin | source
end
