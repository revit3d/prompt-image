# SentencePiece's iOS executable targets call a helper supplied by external iOS
# toolchains. We build only the static processor, but configuration still visits
# those calls. Provide the equivalent target property without an extra toolchain.
function(set_xcode_property target property value variant)
    set_property(TARGET ${target} PROPERTY XCODE_ATTRIBUTE_${property} "${value}")
endfunction()
